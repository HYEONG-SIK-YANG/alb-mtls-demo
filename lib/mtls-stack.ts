import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as s3deploy from 'aws-cdk-lib/aws-s3-deployment';
import * as acm from 'aws-cdk-lib/aws-certificatemanager';
import * as elbv2 from 'aws-cdk-lib/aws-elasticloadbalancingv2';
import * as targets from 'aws-cdk-lib/aws-elasticloadbalancingv2-targets';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as events from 'aws-cdk-lib/aws-events';
import * as eventTargets from 'aws-cdk-lib/aws-events-targets';
import * as sns from 'aws-cdk-lib/aws-sns';
import * as snsSubs from 'aws-cdk-lib/aws-sns-subscriptions';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as cwActions from 'aws-cdk-lib/aws-cloudwatch-actions';
import * as path from 'path';

export interface MtlsStackProps extends cdk.StackProps {
  /** Pre-imported ACM certificate ARN for the ALB HTTPS listener (self-signed for demo). */
  readonly serverCertArn: string;
  /** Optional email address to subscribe to the rotator SNS topic. */
  readonly notificationEmail?: string;
}

export class MtlsStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: MtlsStackProps) {
    super(scope, id, props);

    // ---------------------------------------------------------------------
    // VPC — 2 AZ public-only, no NAT (cost saving for a demo)
    // ---------------------------------------------------------------------
    const vpc = new ec2.Vpc(this, 'Vpc', {
      maxAzs: 2,
      natGateways: 0,
      subnetConfiguration: [
        { name: 'public', subnetType: ec2.SubnetType.PUBLIC, cidrMask: 24 },
      ],
    });

    // ---------------------------------------------------------------------
    // S3 bucket — versioned, holds CA bundles for the trust store
    // ---------------------------------------------------------------------
    const bundleBucket = new s3.Bucket(this, 'CaBundles', {
      versioned: true,
      encryption: s3.BucketEncryption.S3_MANAGED,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      enforceSSL: true,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
    });

    // Upload everything under ./ca/ at deploy time. The CA simulation script
    // must be run before `cdk deploy` so the bundles exist on disk.
    const caAssetPath = path.join(__dirname, '..', 'ca');
    const caDeployment = new s3deploy.BucketDeployment(this, 'CaBundleDeployment', {
      sources: [s3deploy.Source.asset(caAssetPath)],
      destinationBucket: bundleBucket,
      destinationKeyPrefix: 'ca/',
      retainOnDelete: false,
      prune: false,
    });

    // ---------------------------------------------------------------------
    // ACM certificate (imported externally, referenced by ARN)
    // ---------------------------------------------------------------------
    const serverCert = acm.Certificate.fromCertificateArn(
      this, 'ServerCert', props.serverCertArn,
    );

    // ---------------------------------------------------------------------
    // Trust store — points at bundle-current.pem on the bundle bucket
    // ---------------------------------------------------------------------
    const trustStore = new elbv2.TrustStore(this, 'TrustStore', {
      bucket: bundleBucket,
      key: 'ca/bundle-current.pem',
    });
    // BucketDeployment must finish populating ca/bundle-current.pem before TrustStore reads it.
    trustStore.node.addDependency(caDeployment);

    // ---------------------------------------------------------------------
    // Echo Lambda — backend that prints mTLS headers from the request
    // ---------------------------------------------------------------------
    const echoFn = new lambda.Function(this, 'EchoBackend', {
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'index.handler',
      code: lambda.Code.fromAsset(path.join(__dirname, '..', 'lambda', 'echo')),
      timeout: cdk.Duration.seconds(5),
      memorySize: 128,
    });

    // ---------------------------------------------------------------------
    // ALB + HTTPS listener with mTLS verify mode
    // ---------------------------------------------------------------------
    const alb = new elbv2.ApplicationLoadBalancer(this, 'Alb', {
      vpc,
      internetFacing: true,
      vpcSubnets: { subnetType: ec2.SubnetType.PUBLIC },
    });

    const listener = alb.addListener('HttpsListener', {
      port: 443,
      protocol: elbv2.ApplicationProtocol.HTTPS,
      certificates: [serverCert],
      sslPolicy: elbv2.SslPolicy.TLS13_RES,
      mutualAuthentication: {
        mutualAuthenticationMode: elbv2.MutualAuthenticationMode.VERIFY,
        trustStore,
        ignoreClientCertificateExpiry: false,
        advertiseTrustStoreCaNames: true,
      },
      defaultAction: elbv2.ListenerAction.fixedResponse(503, {
        contentType: 'text/plain',
        messageBody: 'no target',
      }),
    });

    listener.addTargets('Echo', {
      targets: [new targets.LambdaTarget(echoFn)],
    });

    // ---------------------------------------------------------------------
    // SNS topic + (optional) email subscription
    // ---------------------------------------------------------------------
    const topic = new sns.Topic(this, 'OpsTopic', {
      displayName: 'mTLS rotation alerts',
    });
    if (props.notificationEmail) {
      topic.addSubscription(new snsSubs.EmailSubscription(props.notificationEmail));
    }

    // ---------------------------------------------------------------------
    // Rotator Lambda
    // ---------------------------------------------------------------------
    const rotator = new lambda.Function(this, 'Rotator', {
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'index.handler',
      code: lambda.Code.fromAsset(path.join(__dirname, '..', 'lambda', 'rotator')),
      timeout: cdk.Duration.minutes(2),
      memorySize: 256,
      environment: {
        TRUST_STORE_ARN: trustStore.trustStoreArn,
        BUNDLE_BUCKET: bundleBucket.bucketName,
        SNS_TOPIC_ARN: topic.topicArn,
      },
    });

    bundleBucket.grantRead(rotator);
    topic.grantPublish(rotator);

    rotator.addToRolePolicy(new iam.PolicyStatement({
      actions: [
        'elasticloadbalancing:DescribeTrustStores',
        'elasticloadbalancing:ModifyTrustStore',
        'elasticloadbalancing:GetTrustStoreCaCertificatesBundle',
      ],
      resources: ['*'],
    }));
    rotator.addToRolePolicy(new iam.PolicyStatement({
      actions: ['cloudwatch:PutMetricData'],
      resources: ['*'],
    }));

    // Daily check via EventBridge
    new events.Rule(this, 'DailyCheck', {
      schedule: events.Schedule.rate(cdk.Duration.days(1)),
      targets: [
        new eventTargets.LambdaFunction(rotator, {
          event: events.RuleTargetInput.fromObject({ action: 'check' }),
        }),
      ],
    });

    // ---------------------------------------------------------------------
    // CloudWatch alarms
    // ---------------------------------------------------------------------
    const negotiationErrorAlarm = new cloudwatch.Alarm(this, 'NegotiationErrorAlarm', {
      alarmDescription: 'mTLS handshake failures spiked — possible cert mismatch or revoked CA',
      metric: alb.metrics.custom('ClientTLSNegotiationErrorCount', {
        statistic: 'Sum',
        period: cdk.Duration.minutes(5),
      }),
      threshold: 5,
      evaluationPeriods: 1,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });
    negotiationErrorAlarm.addAlarmAction(new cwActions.SnsAction(topic));

    const rotationFailureAlarm = new cloudwatch.Alarm(this, 'RotationFailureAlarm', {
      alarmDescription: 'Trust store rotation Lambda emitted a failure metric',
      metric: new cloudwatch.Metric({
        namespace: 'Demo/mTLS',
        metricName: 'RotationFailure',
        statistic: 'Sum',
        period: cdk.Duration.minutes(5),
      }),
      threshold: 1,
      evaluationPeriods: 1,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });
    rotationFailureAlarm.addAlarmAction(new cwActions.SnsAction(topic));

    // ---------------------------------------------------------------------
    // Outputs
    // ---------------------------------------------------------------------
    new cdk.CfnOutput(this, 'AlbDnsName', { value: alb.loadBalancerDnsName });
    new cdk.CfnOutput(this, 'TrustStoreArn', { value: trustStore.trustStoreArn });
    new cdk.CfnOutput(this, 'BundleBucketName', { value: bundleBucket.bucketName });
    new cdk.CfnOutput(this, 'RotatorFunctionName', { value: rotator.functionName });
    new cdk.CfnOutput(this, 'SnsTopicArn', { value: topic.topicArn });
  }
}

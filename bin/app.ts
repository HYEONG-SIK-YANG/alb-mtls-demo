#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { MtlsStack } from '../lib/mtls-stack';

const app = new cdk.App();

const account = process.env.CDK_DEFAULT_ACCOUNT;
const region = process.env.CDK_DEFAULT_REGION ?? 'ap-northeast-2';
if (!account) {
  throw new Error(
    'CDK_DEFAULT_ACCOUNT not set. Configure AWS credentials first ' +
    '(e.g. `aws sts get-caller-identity`).'
  );
}

const serverCertArn: string | undefined = app.node.tryGetContext('serverCertArn');
if (!serverCertArn) {
  throw new Error(
    'serverCertArn context missing. Run scripts/import-server-cert.sh first, then:\n' +
    '  cdk deploy -c serverCertArn=arn:aws:acm:...:certificate/...'
  );
}

const notificationEmail: string | undefined = app.node.tryGetContext('notificationEmail');

new MtlsStack(app, 'MtlsDemoStack', {
  env: { account, region },
  serverCertArn,
  notificationEmail,
  description: 'ALB mTLS demo — TrustStore + zero-downtime rotation + alarms',
});

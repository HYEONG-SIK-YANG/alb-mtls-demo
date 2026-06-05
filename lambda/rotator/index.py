"""ALB mTLS Trust Store rotator.

Triggered by:
  - EventBridge schedule (daily check)
  - Manual invoke with {"action": "rotate", "bundleKey": "ca/bundle-rollover.pem"}

Behavior:
  - 'check' (default): inspect current trust store status; emit liveness metric.
  - 'rotate': download bundle from S3, basic PEM validation, call ModifyTrustStore,
              poll until ACTIVE, publish SNS notification.
"""
import json
import os
import time
import boto3
from botocore.exceptions import ClientError

elbv2 = boto3.client("elbv2")
s3 = boto3.client("s3")
sns = boto3.client("sns")
cloudwatch = boto3.client("cloudwatch")

TRUST_STORE_ARN = os.environ["TRUST_STORE_ARN"]
BUNDLE_BUCKET = os.environ["BUNDLE_BUCKET"]
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]

METRIC_NAMESPACE = "Demo/mTLS"


def _publish(subject: str, message: str) -> None:
    print(f"[SNS] {subject}: {message}")
    try:
        sns.publish(TopicArn=SNS_TOPIC_ARN, Subject=subject[:99], Message=message)
    except ClientError as e:
        print(f"SNS publish failed: {e}")


def _validate_bundle(body: bytes) -> int:
    """Crude PEM check — counts CERTIFICATE blocks."""
    text = body.decode("utf-8", errors="ignore")
    begins = text.count("-----BEGIN CERTIFICATE-----")
    ends = text.count("-----END CERTIFICATE-----")
    if begins == 0 or begins != ends:
        raise ValueError(f"invalid PEM bundle (begin={begins}, end={ends})")
    return begins


def _check() -> dict:
    resp = elbv2.describe_trust_stores(TrustStoreArns=[TRUST_STORE_ARN])
    ts = resp["TrustStores"][0]
    status = ts["Status"]
    print(f"Trust store status={status} name={ts['Name']}")
    cloudwatch.put_metric_data(
        Namespace=METRIC_NAMESPACE,
        MetricData=[
            {
                "MetricName": "TrustStoreActive",
                "Value": 1.0 if status == "ACTIVE" else 0.0,
                "Unit": "Count",
            }
        ],
    )
    return {"status": status, "name": ts["Name"]}


def _rotate(bundle_key: str) -> dict:
    print(f"Fetching s3://{BUNDLE_BUCKET}/{bundle_key}")
    obj = s3.get_object(Bucket=BUNDLE_BUCKET, Key=bundle_key)
    body = obj["Body"].read()
    version_id = obj.get("VersionId", "null")
    cert_count = _validate_bundle(body)
    print(f"Bundle OK — {cert_count} certs, S3 versionId={version_id}")

    elbv2.modify_trust_store(
        TrustStoreArn=TRUST_STORE_ARN,
        CaCertificatesBundleS3Bucket=BUNDLE_BUCKET,
        CaCertificatesBundleS3Key=bundle_key,
        CaCertificatesBundleS3ObjectVersion=version_id,
    )

    # poll until ACTIVE (max 60s)
    status = "PENDING"
    for _ in range(30):
        resp = elbv2.describe_trust_stores(TrustStoreArns=[TRUST_STORE_ARN])
        status = resp["TrustStores"][0]["Status"]
        if status == "ACTIVE":
            break
        time.sleep(2)
    else:
        raise RuntimeError(f"trust store not ACTIVE after 60s — last status={status}")

    msg = (
        f"Trust store rotated.\n"
        f"  trustStoreArn = {TRUST_STORE_ARN}\n"
        f"  bundleKey     = s3://{BUNDLE_BUCKET}/{bundle_key} (v={version_id})\n"
        f"  certs         = {cert_count}"
    )
    _publish("[mTLS] Trust store rotated", msg)
    cloudwatch.put_metric_data(
        Namespace=METRIC_NAMESPACE,
        MetricData=[{"MetricName": "RotationSuccess", "Value": 1.0, "Unit": "Count"}],
    )
    return {"status": "ACTIVE", "bundleKey": bundle_key, "certs": cert_count}


def handler(event, _ctx):
    print("event=", json.dumps(event, default=str))
    action = (event or {}).get("action", "check")
    try:
        if action == "rotate":
            bundle_key = event.get("bundleKey")
            if not bundle_key:
                raise ValueError("'bundleKey' required for rotate action")
            return _rotate(bundle_key)
        return _check()
    except Exception as e:
        _publish("[mTLS] Rotator FAILED", f"{type(e).__name__}: {e}")
        cloudwatch.put_metric_data(
            Namespace=METRIC_NAMESPACE,
            MetricData=[{"MetricName": "RotationFailure", "Value": 1.0, "Unit": "Count"}],
        )
        raise

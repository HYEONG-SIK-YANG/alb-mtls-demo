"""ALB target Lambda — echoes mTLS headers so we can verify cert pass-through.

Triggered by ALB target group (Lambda integration). When mutual auth = verify,
the ALB delivers client cert metadata via X-Amzn-Mtls-* headers.
"""
import json


def handler(event, _ctx):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    mtls = {k: v for k, v in headers.items() if k.startswith("x-amzn-mtls-")}

    body = {
        "ok": True,
        "path": event.get("path", "/"),
        "method": event.get("httpMethod", "GET"),
        "client_ip": headers.get("x-forwarded-for", ""),
        "mtls_headers": mtls,
        "mtls_seen": bool(mtls),
    }

    return {
        "statusCode": 200,
        "statusDescription": "200 OK",
        "isBase64Encoded": False,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, indent=2, ensure_ascii=False),
    }

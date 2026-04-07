import boto3
import json
import logging
import os
import urllib.request
from datetime import datetime, timezone

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Environment variables (set via Terraform)
PARENT_ZONE_ID     = os.environ["PARENT_ZONE_ID"]
PARENT_DOMAIN      = os.environ["PARENT_DOMAIN"]       # e.g. terraform-r53.example.cloud
SLACK_WEBHOOK_URL  = os.environ.get("SLACK_WEBHOOK_URL", "")
SNS_TOPIC_ARN      = os.environ.get("SNS_TOPIC_ARN", "")
DRY_RUN            = os.environ.get("DRY_RUN", "false").lower() == "true"
AUTO_REMEDIATE     = os.environ.get("AUTO_REMEDIATE", "false").lower() == "true"


# ── helpers ────────────────────────────────────────────────────────────────────

def get_all_ns_delegations(r53, zone_id: str, parent_domain: str) -> list[dict]:
    """Return every NS record in the zone that is NOT the apex NS record."""
    delegations = []
    paginator   = r53.get_paginator("list_resource_record_sets")

    for page in paginator.paginate(HostedZoneId=zone_id):
        for record in page["ResourceRecordSets"]:
            if record["Type"] == "NS" and record["Name"] != parent_domain:
                delegations.append(record)

    return delegations


def get_all_active_zone_names(r53) -> set[str]:
    """Return the Name of every hosted zone visible in this account."""
    active = set()
    paginator = r53.get_paginator("list_hosted_zones")

    for page in paginator.paginate():
        for zone in page["HostedZones"]:
            active.add(zone["Name"])

    return active


def delete_ns_record(r53, zone_id: str, record: dict) -> bool:
    """Delete a single NS record. Returns True on success."""
    try:
        r53.change_resource_record_sets(
            HostedZoneId=zone_id,
            ChangeBatch={
                "Comment": "Auto-remediation: dangling NS delegation removed by Lambda",
                "Changes": [{
                    "Action": "DELETE",
                    "ResourceRecordSet": record,
                }],
            },
        )
        logger.info(f"Deleted dangling NS record: {record['Name']}")
        return True
    except Exception as e:
        logger.error(f"Failed to delete NS record {record['Name']}: {e}")
        return False


# ── alerting ───────────────────────────────────────────────────────────────────

def send_slack(findings: list[dict], remediated: list[str]) -> None:
    if not SLACK_WEBHOOK_URL:
        return

    color   = "#FF0000" if findings else "#36a64f"
    ts      = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    count   = len(findings)

    blocks = [
        {
            "type": "header",
            "text": {"type": "plain_text", "text": f"🚨 Dangling Route53 NS Records Detected ({count})"},
        },
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": (
                    f"*Parent Zone:* `{PARENT_DOMAIN}`\n"
                    f"*Checked at:* {ts}\n"
                    f"*Dangling records found:* {count}\n"
                    f"*Auto-remediated:* {len(remediated)}"
                ),
            },
        },
    ]

    for f in findings:
        ns_values = ", ".join(f["ns_values"])
        status    = "✅ Deleted" if f["name"] in remediated else (
                    "⏭️ DRY RUN — not deleted" if DRY_RUN else "⚠️ Manual action required"
                  )
        blocks.append({
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": (
                    f"*Record:* `{f['name']}`\n"
                    f"*NS servers:* `{ns_values}`\n"
                    f"*Status:* {status}"
                ),
            },
        })

    blocks.append({"type": "divider"})
    blocks.append({
        "type": "context",
        "elements": [{"type": "mrkdwn", "text": "Route53 Dangling NS Checker Lambda | ELC CloudSec"}],
    })

    payload = json.dumps({"attachments": [{"color": color, "blocks": blocks}]}).encode()

    req = urllib.request.Request(
        SLACK_WEBHOOK_URL,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            logger.info(f"Slack response: {resp.status}")
    except Exception as e:
        logger.error(f"Slack notification failed: {e}")


def send_sns(findings: list[dict], remediated: list[str]) -> None:
    if not SNS_TOPIC_ARN:
        return

    sns     = boto3.client("sns")
    subject = f"[CloudSec] {len(findings)} Dangling Route53 NS Record(s) Found"
    lines   = [subject, f"Parent Domain : {PARENT_DOMAIN}", ""]

    for f in findings:
        lines.append(f"Record   : {f['name']}")
        lines.append(f"NS values: {', '.join(f['ns_values'])}")
        lines.append(f"Status   : {'DELETED' if f['name'] in remediated else 'REQUIRES MANUAL ACTION'}")
        lines.append("")

    lines.append("These nameservers are unowned and can be claimed by any AWS account.")
    lines.append("See: https://github.com/EdOverflow/can-i-take-over-xyz")

    try:
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=subject,
            Message="\n".join(lines),
        )
        logger.info("SNS notification sent")
    except Exception as e:
        logger.error(f"SNS notification failed: {e}")


# ── main handler ───────────────────────────────────────────────────────────────

def lambda_handler(event, context):
    r53 = boto3.client("route53")

    # Normalise — Route53 always stores names with a trailing dot
    parent = PARENT_DOMAIN if PARENT_DOMAIN.endswith(".") else PARENT_DOMAIN + "."

    logger.info(f"Checking parent zone {PARENT_ZONE_ID} ({parent}) for dangling NS records")

    ns_delegations  = get_all_ns_delegations(r53, PARENT_ZONE_ID, parent)
    active_zones    = get_all_active_zone_names(r53)

    logger.info(f"Found {len(ns_delegations)} NS delegations, {len(active_zones)} active hosted zones")

    findings    : list[dict] = []
    remediated  : list[str]  = []

    for record in ns_delegations:
        name = record["Name"]
        if name not in active_zones:
            ns_values = [rr["Value"] for rr in record.get("ResourceRecords", [])]
            logger.warning(f"DANGLING NS: {name}  →  {ns_values}")

            findings.append({"name": name, "ns_values": ns_values, "record": record})

            if AUTO_REMEDIATE and not DRY_RUN:
                success = delete_ns_record(r53, PARENT_ZONE_ID, record)
                if success:
                    remediated.append(name)
            elif DRY_RUN:
                logger.info(f"DRY RUN: would delete {name}")

    # Alert only when there is something to report
    if findings:
        send_slack(findings, remediated)
        send_sns(findings, remediated)

    result = {
        "checked_at"        : datetime.now(timezone.utc).isoformat(),
        "parent_zone_id"    : PARENT_ZONE_ID,
        "parent_domain"     : parent,
        "ns_delegations"    : len(ns_delegations),
        "dangling_found"    : len(findings),
        "auto_remediated"   : len(remediated),
        "dry_run"           : DRY_RUN,
        "dangling_records"  : [f["name"] for f in findings],
        "remediated_records": remediated,
    }

    logger.info(json.dumps(result))
    return result

"""API Gateway HTTP API authorizer for source CIDRs only."""

import ipaddress
import json
from pathlib import Path

ALLOWED_NETWORKS = tuple(
    ipaddress.ip_network(cidr, strict=False)
    for cidr in json.loads(Path(__file__).with_name("cidrs.json").read_text())
)


def handler(event, context):
    """Use gateway-controlled sourceIp, independent of forwarded headers or tokens."""
    try:
        address = ipaddress.ip_address(event["requestContext"]["http"]["sourceIp"])
    except (KeyError, TypeError, ValueError):
        return {"isAuthorized": False}

    return {
        "isAuthorized": any(
            address.version == network.version and address in network
            for network in ALLOWED_NETWORKS
        )
    }

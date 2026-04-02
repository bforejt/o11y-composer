#!/usr/bin/env python3
"""
nautobot_sd.py — Nautobot → Prometheus file_sd target generator

Pulls device inventory from Nautobot's REST API and writes Prometheus
file_sd-compatible JSON target files for SNMP and other scrape jobs.

Usage:
    python3 nautobot_sd.py

Environment variables:
    NAUTOBOT_URL    — Nautobot base URL (e.g., https://nautobot.lab:8443)
    NAUTOBOT_TOKEN  — Nautobot API token
    OUTPUT_DIR      — Directory to write target files (default: ../prometheus/targets)

Run via cron every 5–10 minutes, or as a systemd timer:
    */5 * * * * /path/to/nautobot_sd.py

The script writes atomically (write to .tmp, then rename) so Prometheus
never reads a partial file.
"""

import json
import os
import sys
import tempfile
import urllib.request
import urllib.error
import ssl


def get_env(name, default=None, required=False):
    val = os.environ.get(name, default)
    if required and not val:
        print("ERROR: %s environment variable is required." % name, file=sys.stderr)
        sys.exit(1)
    return val


def nautobot_get(base_url, token, endpoint, params=None):
    """Fetch paginated results from Nautobot REST API."""
    url = "%s/api/%s/" % (base_url.rstrip("/"), endpoint.strip("/"))
    if params:
        query = "&".join("%s=%s" % (k, v) for k, v in params.items())
        url = "%s?%s" % (url, query)

    results = []
    # Allow self-signed certs in lab
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    while url:
        req = urllib.request.Request(url)
        req.add_header("Authorization", "Token %s" % token)
        req.add_header("Accept", "application/json")

        try:
            resp = urllib.request.urlopen(req, context=ctx)
        except urllib.error.HTTPError as e:
            print("ERROR: %s %s" % (e.code, url), file=sys.stderr)
            sys.exit(1)

        data = json.loads(resp.read().decode("utf-8"))
        results.extend(data.get("results", []))
        url = data.get("next")

    return results


def build_snmp_targets(devices):
    """Convert Nautobot device list to Prometheus file_sd format."""
    targets = []
    for dev in devices:
        # Skip devices without a primary IP
        primary_ip = dev.get("primary_ip")
        if not primary_ip:
            continue

        # Extract IP without CIDR prefix
        addr = primary_ip.get("address", "").split("/")[0]
        if not addr:
            continue

        hostname = dev.get("name", "unknown")
        labels = {"hostname": hostname}

        # Add optional labels when available
        if dev.get("location"):
            site = dev["location"].get("name")
            if site:
                labels["site"] = site
        if dev.get("role"):
            role = dev["role"].get("name")
            if role:
                labels["role"] = role
        if dev.get("device_type"):
            vendor = dev["device_type"].get("manufacturer", {}).get("name")
            if vendor:
                labels["vendor"] = vendor
        if dev.get("platform"):
            platform = dev["platform"].get("name")
            if platform:
                labels["platform"] = platform
        if dev.get("id"):
            labels["nautobot_id"] = str(dev["id"])

        targets.append({
            "targets": [addr],
            "labels": labels,
        })

    return targets


def write_atomic(path, data):
    """Write JSON data atomically to avoid partial reads."""
    dir_name = os.path.dirname(path)
    fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2)
            f.write("\n")
        os.rename(tmp_path, path)
    except Exception:
        os.unlink(tmp_path)
        raise


def main():
    base_url = get_env("NAUTOBOT_URL", required=True)
    token = get_env("NAUTOBOT_TOKEN", required=True)
    output_dir = get_env("OUTPUT_DIR", os.path.join(os.path.dirname(__file__), "..", "prometheus", "targets"))

    os.makedirs(output_dir, exist_ok=True)

    # Pull active devices from Nautobot
    print("Fetching devices from %s..." % base_url)
    devices = nautobot_get(base_url, token, "dcim/devices", {"status": "active", "limit": 1000})
    print("  Found %d active devices." % len(devices))

    # Build and write SNMP targets
    snmp_targets = build_snmp_targets(devices)
    snmp_path = os.path.join(output_dir, "snmp_targets.json")
    write_atomic(snmp_path, snmp_targets)
    print("  Wrote %d SNMP targets to %s" % (len(snmp_targets), snmp_path))


if __name__ == "__main__":
    main()

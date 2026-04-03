#!/usr/bin/env python3
"""
adapter.py — Nautobot HTTP Service Discovery adapter for Prometheus

Queries Nautobot's REST API for active network devices and serves them
as Prometheus http_sd_configs-compatible JSON. Prometheus polls this
endpoint directly — no file generation needed.

Endpoints:
    GET /targets    Prometheus http_sd_configs target list (always 200)
    GET /health     Health status with cache age and target count

Environment variables:
    NAUTOBOT_URL      — Nautobot base URL (required)
    NAUTOBOT_TOKEN    — Nautobot API token (required)
    SD_ADAPTER_PORT   — Listen port (default: 8000)
    SD_CACHE_TTL      — Cache TTL in seconds (default: 300)
    SD_LOG_LEVEL      — Logging level (default: INFO)
"""

import json
import logging
import os
import ssl
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

NAUTOBOT_URL = os.environ.get("NAUTOBOT_URL", "").rstrip("/")
NAUTOBOT_TOKEN = os.environ.get("NAUTOBOT_TOKEN", "")
LISTEN_PORT = int(os.environ.get("SD_ADAPTER_PORT", "8000"))
CACHE_TTL = int(os.environ.get("SD_CACHE_TTL", "300"))
LOG_LEVEL = os.environ.get("SD_LOG_LEVEL", "INFO").upper()

log = logging.getLogger("nautobot-sd")

# ---------------------------------------------------------------------------
# Cache
# ---------------------------------------------------------------------------

_cache = {
    "targets": [],
    "fetched_at": 0.0,
    "error": None,
}
_cache_lock = threading.Lock()

# ---------------------------------------------------------------------------
# Nautobot API (adapted from scripts/nautobot_sd.py)
# ---------------------------------------------------------------------------


def nautobot_get(base_url, token, endpoint, params=None):
    """Fetch paginated results from Nautobot REST API."""
    url = "%s/api/%s/" % (base_url, endpoint.strip("/"))
    if params:
        query = "&".join("%s=%s" % (k, v) for k, v in params.items())
        url = "%s?%s" % (url, query)

    results = []
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    while url:
        req = urllib.request.Request(url)
        req.add_header("Authorization", "Token %s" % token)
        req.add_header("Accept", "application/json")
        resp = urllib.request.urlopen(req, context=ctx, timeout=30)
        data = json.loads(resp.read().decode("utf-8"))
        results.extend(data.get("results", []))
        url = data.get("next")

    return results


def build_snmp_targets(devices):
    """Convert Nautobot device list to Prometheus http_sd target format."""
    targets = []
    for dev in devices:
        primary_ip = dev.get("primary_ip")
        if not primary_ip:
            continue

        addr = primary_ip.get("address", "").split("/")[0]
        if not addr:
            continue

        hostname = dev.get("name", "unknown")
        labels = {"hostname": hostname}

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

        targets.append({"targets": [addr], "labels": labels})

    return targets


# ---------------------------------------------------------------------------
# Cache refresh
# ---------------------------------------------------------------------------


def refresh_cache():
    """Fetch devices from Nautobot and update the in-memory cache."""
    try:
        log.info("Refreshing targets from %s", NAUTOBOT_URL)
        devices = nautobot_get(
            NAUTOBOT_URL, NAUTOBOT_TOKEN, "dcim/devices",
            {"status": "active", "limit": "1000"},
        )
        targets = build_snmp_targets(devices)
        with _cache_lock:
            _cache["targets"] = targets
            _cache["fetched_at"] = time.time()
            _cache["error"] = None
        log.info("Cache refreshed: %d targets from %d devices", len(targets), len(devices))
    except Exception as exc:
        with _cache_lock:
            _cache["error"] = str(exc)
        log.warning("Failed to refresh cache (serving stale): %s", exc)


def get_targets():
    """Return cached targets, refreshing if TTL expired."""
    with _cache_lock:
        age = time.time() - _cache["fetched_at"]
        stale = age > CACHE_TTL
    if stale:
        refresh_cache()
    with _cache_lock:
        return list(_cache["targets"])


def get_health():
    """Return health status dict."""
    with _cache_lock:
        return {
            "status": "ok" if _cache["error"] is None else "degraded",
            "targets_count": len(_cache["targets"]),
            "cache_age_seconds": round(time.time() - _cache["fetched_at"], 1),
            "cache_ttl": CACHE_TTL,
            "nautobot_url": NAUTOBOT_URL,
            "last_error": _cache["error"],
        }


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------


class SDHandler(BaseHTTPRequestHandler):
    """Minimal HTTP handler for Prometheus http_sd_configs."""

    def do_GET(self):
        if self.path == "/targets":
            body = json.dumps(get_targets()).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        elif self.path == "/health":
            health = get_health()
            code = 200 if health["status"] in ("ok", "degraded") else 503
            body = json.dumps(health, indent=2).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        else:
            self.send_error(404)

    def log_message(self, fmt, *args):
        log.debug("%s %s", self.address_string(), fmt % args)


class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    logging.basicConfig(
        level=getattr(logging, LOG_LEVEL, logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
    )

    if not NAUTOBOT_URL:
        log.error("NAUTOBOT_URL is required")
        sys.exit(1)
    if not NAUTOBOT_TOKEN:
        log.error("NAUTOBOT_TOKEN is required")
        sys.exit(1)

    log.info("Nautobot SD Adapter starting")
    log.info("  NAUTOBOT_URL:  %s", NAUTOBOT_URL)
    log.info("  CACHE_TTL:     %ds", CACHE_TTL)
    log.info("  LISTEN_PORT:   %d", LISTEN_PORT)

    # Warm cache — non-fatal if Nautobot is unreachable.
    refresh_cache()

    server = ThreadedHTTPServer(("0.0.0.0", LISTEN_PORT), SDHandler)
    log.info("Listening on 0.0.0.0:%d", LISTEN_PORT)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Shutting down")
        server.shutdown()


if __name__ == "__main__":
    main()

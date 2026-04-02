# Prometheus Targets Directory

This directory contains `file_sd`-compatible JSON files that Prometheus watches
for scrape target discovery. Files are re-read every 5 minutes (configurable in
`prometheus.yml` via `refresh_interval`).

## Format

Each JSON file contains an array of target groups:

```json
[
  {
    "targets": ["10.0.0.1", "10.0.0.2"],
    "labels": {
      "site": "dc1",
      "role": "switch",
      "vendor": "arista"
    }
  }
]
```

## Label Schema

Use consistent labels across all target files to enable cross-telemetry
correlation in Grafana:

| Label | Description | Example |
|---|---|---|
| `hostname` | Device hostname | `core-rtr01` |
| `site` | Physical site/location | `dc1`, `branch-nyc` |
| `role` | Device role | `router`, `switch`, `firewall` |
| `vendor` | Manufacturer | `cisco`, `arista`, `juniper` |
| `platform` | OS/platform | `ios-xe`, `eos`, `junos` |

## Auto-generation from Nautobot

```bash
export NAUTOBOT_URL=https://nautobot.lab:8443
export NAUTOBOT_TOKEN=your_token
python3 ../scripts/nautobot_sd.py
```

Schedule via cron for continuous synchronization.

# Network Observability Stack

Docker Compose-based observability platform for network infrastructure. Built around **Prometheus** (metrics), **Loki** (logs), and **Grafana** (visualization), with collectors for SNMP, gNMI streaming telemetry, and syslog.

Designed for lab deployment with a clear path to production.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Network Devices                              │
│   SNMP (UDP/161)    gNMI (TCP/6030+)    Syslog (UDP/TCP 1514)     │
└────────┬──────────────────┬──────────────────────┬──────────────────┘
         │                  │                      │
         ▼                  ▼                      ▼
   ┌───────────┐     ┌───────────┐          ┌───────────┐
   │   SNMP    │     │ Telegraf  │          │   Alloy   │
   │ Exporter  │     │  (gNMI)   │          │ (syslog)  │
   └─────┬─────┘     └─────┬─────┘          └─────┬─────┘
         │                  │                      │
         │    ┌─────────────┘                      │
         ▼    ▼                                    ▼
   ┌──────────────┐                         ┌───────────┐
   │  Prometheus   │                         │   Loki    │
   │  (metrics)    │                         │  (logs)   │
   └───────┬───────┘                         └─────┬─────┘
           │              ┌───────────┐            │
           └──────────────│  Grafana  │────────────┘
                          │ (viz/UI)  │
                          └─────┬─────┘
                                │
                          ┌─────┴─────┐
                          │Alertmanager│
                          └───────────┘
```

## Components

| Service | Port | Purpose |
|---|---|---|
| Prometheus | 9090 | Metrics backend, TSDB |
| Grafana | 3000 | Dashboards, visualization |
| Loki | 3100 | Log aggregation |
| Alertmanager | 9093 | Alert routing/notification |
| Alloy | 1514, 12345 | Syslog collection, Alloy UI |
| PostgreSQL | (internal) | Grafana backend DB |
| SNMP Exporter | 9116 | SNMP polling (profile: `snmp`) |
| Telegraf | 9273 | gNMI streaming (profile: `telemetry`) |
| MCP Grafana | 8686 | LLM integration (profile: `mcp`) |

## Quick Start

```bash
git clone https://github.com/YOUR_ORG/o11y-composer.git
cd o11y-composer
chmod +x setup.sh reset.sh
./setup.sh
docker compose up -d
```

Access Grafana at `http://localhost:3000` with the credentials printed by `setup.sh`.

### Start with optional profiles

```bash
# Core + SNMP collection
docker compose --profile snmp up -d

# Core + SNMP + gNMI streaming
docker compose --profile snmp --profile telemetry up -d

# Everything including MCP server
docker compose --profile snmp --profile telemetry --profile mcp up -d
```

## Configuration

### SNMP Targets

Edit `prometheus/targets/snmp_targets.json` with your device IPs:

```json
[
  {
    "targets": ["10.0.0.1"],
    "labels": {
      "hostname": "core-rtr01",
      "site": "dc1",
      "role": "router"
    }
  }
]
```

Or use `scripts/nautobot_sd.py` to auto-generate targets from Nautobot inventory:

```bash
export NAUTOBOT_URL=https://nautobot.lab:8443
export NAUTOBOT_TOKEN=your_token
python3 scripts/nautobot_sd.py
```

### Syslog

Point devices to send syslog to `HOST:1514` (UDP or TCP). Alloy listens on 1514 to avoid requiring root. To accept syslog on the standard port 514, add iptables redirect on the Docker host:

```bash
iptables -t nat -A PREROUTING -p udp --dport 514 -j REDIRECT --to-port 1514
iptables -t nat -A PREROUTING -p tcp --dport 514 -j REDIRECT --to-port 1514
```

### Streaming Telemetry (gNMI)

Edit `telegraf/telegraf.conf` — uncomment the `[[inputs.gnmi]]` block and configure your device addresses, credentials, and subscription paths.

### MCP Server (LLM Integration)

The `mcp-grafana` service exposes an SSE endpoint at `http://HOST:8686/sse`. Configure your MCP client:

```json
{
  "mcpServers": {
    "observability": {
      "url": "http://HOST:8686/sse"
    }
  }
}
```

**Note:** Generate a Grafana service account API key (Administration → Service Accounts → Create token with Viewer or Editor role) and set `MCP_GRAFANA_API_KEY` in `.env` before starting the MCP profile.

#### When to add the deep Prometheus MCP server

The `mcp-prometheus` service (commented out in `docker-compose.yml`) adds deeper Prometheus-specific tooling:

- **Use `mcp-grafana` alone** for: operational queries, dashboard management, cross-stack LogQL/PromQL, alert investigation.
- **Add `mcp-prometheus`** when: doing serious PromQL development, analyzing metric cardinality, generating recording rules for SLOs, or debugging TSDB internals.

Uncomment the service in `docker-compose.yml` and configure `MCP_PROMETHEUS_PORT` in `.env`.

## Nautobot Integration

This stack integrates with a separately deployed Nautobot instance for network inventory (SSoT). The integration point is `scripts/nautobot_sd.py`, which pulls active devices from Nautobot's REST API and writes Prometheus `file_sd` target files. Run it periodically via cron.

**Why separate projects?** Different failure domains, different lifecycles, different DB requirements. Nautobot upgrades involve DB migrations that shouldn't risk your monitoring stack, and vice versa.

## Volumes

All persistent data uses named Docker volumes:

| Volume | Contents |
|---|---|
| `prometheus_data` | Prometheus TSDB |
| `loki_data` | Loki chunks and index |
| `grafana_data` | Grafana state, dashboards |
| `postgres_data` | PostgreSQL data |
| `alertmanager_data` | Alertmanager state |

## Reset / Teardown

```bash
# Stop and remove volumes
./reset.sh

# Full reset including .env and images
./reset.sh --full
```

## Production Considerations

- **Pin image versions** in `.env` instead of using `latest`.
- **Set `PROMETHEUS_RETENTION`** based on disk capacity (~1-2 bytes per sample).
- **Add Loki object storage** (S3/MinIO) for log retention beyond local disk.
- **Configure Alertmanager receivers** — email, Slack, PagerDuty, or webhook.
- **Generate a Grafana API key** for the MCP server with least-privilege RBAC.
- **Move Telegraf/SNMP exporter** closer to target devices in production (separate hosts).
- **Add TLS** — use a reverse proxy (Traefik, nginx) for HTTPS on Grafana and MCP endpoints.
- **Backup volumes** — especially `postgres_data` and `grafana_data`.

## File Structure

```
o11y-composer/
├── setup.sh                      # Initialize .env and secrets
├── reset.sh                      # Teardown containers and volumes
├── docker-compose.yml            # Full stack definition
├── env.example                   # Template for .env
├── .gitignore
├── README.md
├── prometheus/
│   ├── prometheus.yml            # Scrape configs, alerting
│   ├── alerts/
│   │   └── network.yml           # Alert rules
│   └── targets/
│       └── snmp_targets.json     # SNMP device targets (file_sd)
├── grafana/
│   └── provisioning/
│       ├── datasources/
│       │   └── datasources.yml   # Prometheus + Loki datasources
│       └── dashboards/
│           ├── dashboards.yml    # Dashboard provider config
│           └── json/             # Drop dashboard JSON exports here
├── loki/
│   └── loki-config.yml
├── alertmanager/
│   └── alertmanager.yml
├── alloy/
│   └── config.alloy              # Syslog listener → Loki
├── telegraf/
│   └── telegraf.conf             # gNMI streaming telemetry
├── snmp-exporter/
│   └── snmp.yml                  # SNMP exporter modules/auth
└── scripts/
    └── nautobot_sd.py            # Nautobot → Prometheus targets
```

## License

MIT

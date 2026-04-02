#!/usr/bin/env bash
# =============================================================================
# reset.sh — Tear down Network Observability Stack
#
# Stops containers and removes volumes. Optionally removes .env and images.
#
# Usage:
#   ./reset.sh              Stop containers, remove volumes
#   ./reset.sh --full       Also remove .env and locally-built images
#   ./reset.sh --debug      Enable bash trace
# =============================================================================

FULL=false
DEBUG=false

for arg in "$@"; do
    case "$arg" in
        --full)  FULL=true ;;
        --debug) DEBUG=true; set -x ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Network Observability Stack Reset ==="
echo ""

# ---------------------------------------------------------------------------
# Confirm
# ---------------------------------------------------------------------------

echo "This will:"
echo "  - Stop all containers"
echo "  - Remove all named volumes (prometheus_data, loki_data, grafana_data, postgres_data, alertmanager_data)"
if $FULL; then
    echo "  - Remove .env file"
    echo "  - Remove locally-built images"
fi
echo ""
read -rp "Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------

echo ""
echo "[1/3] Stopping containers and removing volumes..."
docker compose --profile snmp --profile telemetry --profile mcp down -v --remove-orphans 2>/dev/null || true

if $FULL; then
    echo "[2/3] Removing locally-built images..."
    docker compose --profile snmp --profile telemetry --profile mcp down --rmi local 2>/dev/null || true

    echo "[3/3] Removing .env..."
    rm -f "$SCRIPT_DIR/.env"
    echo "  .env removed. Run setup.sh to regenerate."
else
    echo "[2/3] Skipping image removal (use --full to include)."
    echo "[3/3] Keeping .env intact."
fi

echo ""
echo "Reset complete. Run setup.sh to reinitialize."

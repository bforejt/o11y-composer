#!/usr/bin/env bash
# =============================================================================
# reset.sh — Fully reset the Network Observability Stack
#
# Stops all containers, removes volumes, deletes .env, and removes images.
#
# THIS IS DESTRUCTIVE — all observability data will be lost.
#
# Usage:
#   ./reset.sh            Interactive — prompts for confirmation
#   ./reset.sh --force    Skip confirmation prompt
#   ./reset.sh --rebuild  Reset and immediately re-run setup.sh
#   ./reset.sh --debug    Enable bash trace
# =============================================================================

set -euo pipefail

trap 'echo "ERROR: Script failed at line $LINENO.  Exit code: $?" >&2' ERR

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# Compose project name — derived from directory name, same as Docker Compose.
PROJECT_DIR="$(basename "$SCRIPT_DIR")"
PROJECT_NAME="$(echo "$PROJECT_DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g')"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------

FORCE=false
REBUILD=false

for arg in "$@"; do
    case "$arg" in
        --force)   FORCE=true ;;
        --rebuild) REBUILD=true ;;
        --debug)   set -x ;;
        --help|-h)
            echo "Usage: $0 [--force] [--rebuild] [--debug]"
            echo ""
            echo "  --force    Skip confirmation prompt"
            echo "  --rebuild  After reset, run setup.sh to reinitialize"
            echo "  --debug    Enable bash trace (set -x)"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            echo "Usage: $0 [--force] [--rebuild] [--debug]" >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

if ! command -v docker &>/dev/null; then
    echo "ERROR: docker is not installed or not in PATH." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------

if [[ "$FORCE" != true ]]; then
    echo "========================================"
    echo "  OBSERVABILITY STACK FULL RESET"
    echo "========================================"
    echo ""
    echo "This will permanently destroy:"
    echo "  - All running containers (core + all profiles)"
    echo "  - All Docker volumes (Prometheus, Loki, Grafana, PostgreSQL, Alertmanager)"
    echo "  - The .env file (secrets, passwords)"
    echo "  - Locally built images"
    echo ""
    echo "ALL OBSERVABILITY DATA WILL BE LOST."
    echo ""
    read -rp "Type 'reset' to confirm: " confirm
    if [[ "$confirm" != "reset" ]]; then
        echo "Aborted."
        exit 0
    fi
    echo ""
fi

# ---------------------------------------------------------------------------
# Stop and remove containers
# ---------------------------------------------------------------------------

echo "[1/4] Stopping containers..."

if docker compose -f "${SCRIPT_DIR}/docker-compose.yml" \
    --profile snmp --profile telemetry --profile mcp ps -q &>/dev/null; then
    docker compose -f "${SCRIPT_DIR}/docker-compose.yml" \
        --profile snmp --profile telemetry --profile mcp \
        down -v --remove-orphans 2>/dev/null || true
    echo "  Containers stopped, volumes removed."
else
    echo "  No running containers found."
fi

# ---------------------------------------------------------------------------
# Remove .env file
# ---------------------------------------------------------------------------

echo ""
echo "[2/4] Removing .env file..."

if [[ -f "$ENV_FILE" ]]; then
    rm "$ENV_FILE"
    echo "  $ENV_FILE — removed"
else
    echo "  .env not found (skipped)"
fi

# ---------------------------------------------------------------------------
# Remove built images
# ---------------------------------------------------------------------------

echo ""
echo "[3/4] Removing built images..."

# Compose-built images follow the pattern: <project>-<service>
IMAGES=$(docker images --filter "reference=${PROJECT_NAME}-*" -q 2>/dev/null || true)
if [[ -n "$IMAGES" ]]; then
    docker rmi $IMAGES 2>/dev/null || true
    echo "  Removed images for project: $PROJECT_NAME"
else
    echo "  No project images found (skipped)"
fi

# ---------------------------------------------------------------------------
# Prune dangling resources
# ---------------------------------------------------------------------------

echo ""
echo "[4/4] Pruning dangling resources..."
docker network prune -f --filter "label=com.docker.compose.project=${PROJECT_NAME}" 2>/dev/null || true
echo "  Done."

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo ""
echo "Reset complete."

if [[ "$REBUILD" == true ]]; then
    echo ""
    echo "Running setup.sh to reinitialize..."
    echo ""
    exec "${SCRIPT_DIR}/setup.sh"
else
    echo ""
    echo "To reinitialize:"
    echo "  ./setup.sh"
    echo "  docker compose up -d"
fi

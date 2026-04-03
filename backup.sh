#!/usr/bin/env bash
# =============================================================================
# backup.sh — Back up observability stack data
#
# Creates timestamped backups in ./backups/ (or a custom directory).
#   Database: pg_dump of Grafana PostgreSQL -> o11y_db_<timestamp>.sql.gz
#   Grafana:  tar of grafana_data volume   -> o11y_grafana_<timestamp>.tar.gz
#
# Usage:
#   ./backup.sh                  Back up everything (db + grafana)
#   ./backup.sh -t db            Database only
#   ./backup.sh -t grafana       Grafana data only
#   ./backup.sh -d /mnt/backups  Custom output directory
# =============================================================================
set -euo pipefail
trap 'echo "ERROR: backup failed at line $LINENO (exit $?)." >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP="$(date +%F_%H%M%S)"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
BACKUP_TYPE="all"
BACKUP_DIR="${SCRIPT_DIR}/backups"

# Compose project name — derived from directory name, same as Docker Compose.
PROJECT_DIR="$(basename "$SCRIPT_DIR")"
PROJECT_NAME="$(echo "$PROJECT_DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g')"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--type)
            BACKUP_TYPE="$2"
            shift 2
            ;;
        -d|--dir)
            BACKUP_DIR="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: ./backup.sh [-t TYPE] [-d DIR]"
            echo ""
            echo "Options:"
            echo "  -t, --type TYPE   What to back up: db, grafana, all (default: all)"
            echo "  -d, --dir  DIR    Output directory (default: ./backups)"
            echo "  -h, --help        Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Run './backup.sh --help' for usage." >&2
            exit 1
            ;;
    esac
done

case "$BACKUP_TYPE" in
    db|grafana|all) ;;
    *)
        echo "ERROR: Invalid type '${BACKUP_TYPE}'. Must be db, grafana, or all." >&2
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
if ! docker info &>/dev/null; then
    echo "ERROR: Cannot connect to the Docker daemon." >&2
    exit 1
fi

# Find the postgres container name (Compose names it <project>-postgres-1).
DB_CONTAINER="${PROJECT_NAME}-postgres-1"

if [[ "$BACKUP_TYPE" == "db" || "$BACKUP_TYPE" == "all" ]]; then
    if ! docker inspect --format '{{.State.Running}}' "$DB_CONTAINER" 2>/dev/null | grep -q true; then
        echo "ERROR: The postgres container (${DB_CONTAINER}) is not running." >&2
        echo "  Start the stack first:  docker compose up -d" >&2
        exit 1
    fi
fi

mkdir -p "$BACKUP_DIR"

echo "Observability Stack Backup"
echo "  Type:      ${BACKUP_TYPE}"
echo "  Directory: ${BACKUP_DIR}"
echo ""

# ---------------------------------------------------------------------------
# Database backup (Grafana PostgreSQL)
# ---------------------------------------------------------------------------
if [[ "$BACKUP_TYPE" == "db" || "$BACKUP_TYPE" == "all" ]]; then
    DB_FILE="${BACKUP_DIR}/o11y_db_${TIMESTAMP}.sql.gz"
    echo "Backing up Grafana database..."
    # Use docker exec (not docker compose exec) to avoid Compose status
    # messages contaminating the pg_dump output stream.
    docker exec "$DB_CONTAINER" \
        pg_dump -U "${GF_DATABASE_USER:-grafana}" "${GF_DATABASE_NAME:-grafana}" | gzip > "$DB_FILE"
    DB_SIZE="$(du -h "$DB_FILE" | cut -f1)"
    echo "  Created: ${DB_FILE} (${DB_SIZE})"
fi

# ---------------------------------------------------------------------------
# Grafana data backup (dashboards, plugins, state)
# ---------------------------------------------------------------------------
if [[ "$BACKUP_TYPE" == "grafana" || "$BACKUP_TYPE" == "all" ]]; then
    GRAFANA_FILE="o11y_grafana_${TIMESTAMP}.tar.gz"
    GRAFANA_VOLUME="${PROJECT_NAME}_grafana_data"
    echo "Backing up Grafana data volume..."
    docker run --rm \
        -v "${GRAFANA_VOLUME}:/data:ro" \
        -v "$(cd "$BACKUP_DIR" && pwd):/backup" \
        alpine tar czf "/backup/${GRAFANA_FILE}" -C /data .
    GRAFANA_SIZE="$(du -h "${BACKUP_DIR}/${GRAFANA_FILE}" | cut -f1)"
    echo "  Created: ${BACKUP_DIR}/${GRAFANA_FILE} (${GRAFANA_SIZE})"
fi

echo ""
echo "Backup complete."

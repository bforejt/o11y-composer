#!/usr/bin/env bash
# =============================================================================
# restore.sh — Restore observability stack data from backup
#
# By default, finds the most recent backup files in ./backups/.
# Use --db-file / --grafana-file to specify exact files.
#
# Usage:
#   ./restore.sh                                     Restore latest db + grafana
#   ./restore.sh -t db                               Database only
#   ./restore.sh --db-file backups/my.sql.gz         Specific DB backup
#   ./restore.sh --grafana-file backups/my.tar.gz    Specific Grafana backup
#   ./restore.sh -d /mnt/backups                     Search a custom directory
# =============================================================================
set -euo pipefail
trap 'echo "ERROR: restore failed at line $LINENO (exit $?)." >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
RESTORE_TYPE="all"
BACKUP_DIR="${SCRIPT_DIR}/backups"
DB_FILE=""
GRAFANA_FILE=""

# Compose project name — derived from directory name, same as Docker Compose.
PROJECT_DIR="$(basename "$SCRIPT_DIR")"
PROJECT_NAME="$(echo "$PROJECT_DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g')"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--type)
            RESTORE_TYPE="$2"
            shift 2
            ;;
        -d|--dir)
            BACKUP_DIR="$2"
            shift 2
            ;;
        --db-file)
            DB_FILE="$2"
            shift 2
            ;;
        --grafana-file)
            GRAFANA_FILE="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: ./restore.sh [-t TYPE] [-d DIR] [--db-file FILE] [--grafana-file FILE]"
            echo ""
            echo "Options:"
            echo "  -t, --type TYPE            What to restore: db, grafana, all (default: all)"
            echo "  -d, --dir  DIR             Directory to search for backups (default: ./backups)"
            echo "      --db-file FILE         Specific database backup file"
            echo "      --grafana-file FILE    Specific Grafana data backup file"
            echo "  -h, --help                 Show this help message"
            echo ""
            echo "Supported formats:"
            echo "  Database: .sql.gz (gzipped) or .sql (plain)"
            echo "  Grafana:  .tar.gz or .tgz"
            echo ""
            echo "When no file is specified, the most recent matching backup in"
            echo "the backup directory is used automatically."
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Run './restore.sh --help' for usage." >&2
            exit 1
            ;;
    esac
done

case "$RESTORE_TYPE" in
    db|grafana|all) ;;
    *)
        echo "ERROR: Invalid type '${RESTORE_TYPE}'. Must be db, grafana, or all." >&2
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

DB_CONTAINER="${PROJECT_NAME}-postgres-1"

if [[ "$RESTORE_TYPE" == "db" || "$RESTORE_TYPE" == "all" ]]; then
    if ! docker inspect --format '{{.State.Running}}' "$DB_CONTAINER" 2>/dev/null | grep -q true; then
        echo "ERROR: The postgres container (${DB_CONTAINER}) is not running." >&2
        echo "  Start the stack first:  docker compose up -d" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Resolve backup files
# ---------------------------------------------------------------------------
# find_latest <dir> <pattern1> [<pattern2> ...]
# Returns the most recently modified file matching any of the given globs.
find_latest() {
    local dir="$1"; shift
    local pattern result
    # The || true prevents SIGPIPE (exit 141) when head closes the pipe
    # early, which would kill the script under set -o pipefail.
    # shellcheck disable=SC2012
    result="$(for pattern in "$@"; do
        ls -t "${dir}"/${pattern} 2>/dev/null || true
    done | head -1)" || true
    echo "$result"
}

if [[ "$RESTORE_TYPE" == "db" || "$RESTORE_TYPE" == "all" ]]; then
    if [[ -z "$DB_FILE" ]]; then
        DB_FILE="$(find_latest "$BACKUP_DIR" \
            "o11y_db_*.sql.gz" "o11y_db_*.sql" \
            "o11y-db-*.sql.gz" "o11y-db-*.sql")"
        if [[ -z "$DB_FILE" ]]; then
            echo "ERROR: No database backup found in ${BACKUP_DIR}." >&2
            echo "  Use --db-file to specify a file, or run ./backup.sh first." >&2
            exit 1
        fi
    fi
    if [[ ! -f "$DB_FILE" ]]; then
        echo "ERROR: Database backup not found: ${DB_FILE}" >&2
        exit 1
    fi
fi

if [[ "$RESTORE_TYPE" == "grafana" || "$RESTORE_TYPE" == "all" ]]; then
    if [[ -z "$GRAFANA_FILE" ]]; then
        GRAFANA_FILE="$(find_latest "$BACKUP_DIR" \
            "o11y_grafana_*.tar.gz" "o11y_grafana_*.tgz" \
            "o11y-grafana-*.tar.gz" "o11y-grafana-*.tgz")"
        if [[ -z "$GRAFANA_FILE" ]]; then
            echo "ERROR: No Grafana backup found in ${BACKUP_DIR}." >&2
            echo "  Use --grafana-file to specify a file, or run ./backup.sh first." >&2
            exit 1
        fi
    fi
    if [[ ! -f "$GRAFANA_FILE" ]]; then
        echo "ERROR: Grafana backup not found: ${GRAFANA_FILE}" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------
echo "Observability Stack Restore"
echo ""
if [[ "$RESTORE_TYPE" == "db" || "$RESTORE_TYPE" == "all" ]]; then
    echo "  Database: ${DB_FILE}"
fi
if [[ "$RESTORE_TYPE" == "grafana" || "$RESTORE_TYPE" == "all" ]]; then
    echo "  Grafana:  ${GRAFANA_FILE}"
fi
echo ""
echo "WARNING: This will overwrite current data. This cannot be undone."
printf "Continue? [y/N] "
read -r CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi
echo ""

# ---------------------------------------------------------------------------
# Database restore
# ---------------------------------------------------------------------------
if [[ "$RESTORE_TYPE" == "db" || "$RESTORE_TYPE" == "all" ]]; then
    DB_NAME="${GF_DATABASE_NAME:-grafana}"
    DB_USER="${GF_DATABASE_USER:-grafana}"
    echo "Restoring database from ${DB_FILE}..."

    # Drop and recreate the database to avoid conflicts.
    echo "  Dropping and recreating ${DB_NAME} database..."
    docker exec "$DB_CONTAINER" \
        psql -U "$DB_USER" -d postgres -c "DROP DATABASE IF EXISTS ${DB_NAME};"
    docker exec "$DB_CONTAINER" \
        psql -U "$DB_USER" -d postgres -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"

    # Handle both gzipped (.sql.gz) and plain (.sql) backups.
    echo "  Loading SQL dump..."
    if [[ "$DB_FILE" == *.gz ]]; then
        gunzip -c "$DB_FILE"
    else
        cat "$DB_FILE"
    fi | docker exec -i "$DB_CONTAINER" psql -U "$DB_USER"
    echo "  Database restored."
fi

# ---------------------------------------------------------------------------
# Grafana data restore
# ---------------------------------------------------------------------------
if [[ "$RESTORE_TYPE" == "grafana" || "$RESTORE_TYPE" == "all" ]]; then
    GRAFANA_VOLUME="${PROJECT_NAME}_grafana_data"
    echo "Restoring Grafana data from ${GRAFANA_FILE}..."
    # Resolve to absolute path for the Docker bind-mount.
    GRAFANA_FILE_ABS="$(cd "$(dirname "$GRAFANA_FILE")" && pwd)/$(basename "$GRAFANA_FILE")"
    GRAFANA_FILE_NAME="$(basename "$GRAFANA_FILE")"
    docker run --rm \
        -v "${GRAFANA_VOLUME}:/data" \
        -v "$(dirname "$GRAFANA_FILE_ABS"):/backup:ro" \
        alpine sh -c "
            rm -rf /data/*
            tar xzf /backup/${GRAFANA_FILE_NAME} -C /data
        "
    echo "  Grafana data restored."
fi

echo ""
echo "Restore complete."
echo "Restart the stack to pick up restored data:  docker compose restart"

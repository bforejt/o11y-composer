#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Running snmp_exporter generator..."
docker run --rm \
  -v "${SCRIPT_DIR}:/opt" \
  -v "${SCRIPT_DIR}/mibs:/opt/mibs" \
  prom/snmp-generator:latest generate

echo ""
echo "Generated snmp.yml in ${SCRIPT_DIR}"
echo ""
echo "Review the output, then deploy:"
echo "  cp ${SCRIPT_DIR}/snmp.yml ${SCRIPT_DIR}/../snmp.yml"
echo "  docker compose restart snmp-exporter"

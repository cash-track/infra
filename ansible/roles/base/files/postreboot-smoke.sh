#!/usr/bin/env bash
# Post-reboot smoke check. Runs once at boot via postreboot-smoke.service.
# Verifies the compose stack came back up and writes a node-exporter textfile
# metric (`cashtrack_postreboot_check_ok`) for Alertmanager to scrape.
#
# Compose-file presence is treated as the gate: on a freshly provisioned droplet
# (Stage 7 first-boot), /opt/cashtrack/compose.core.yml does not exist yet and
# the check writes ok=1 unconditionally so the metric exists for Prometheus.
set -uo pipefail

TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
TEXTFILE="${TEXTFILE_DIR}/cashtrack_postreboot_check.prom"
COMPOSE_CORE="/opt/cashtrack/compose.core.yml"

mkdir -p "${TEXTFILE_DIR}"

ok=1

if [ -f "${COMPOSE_CORE}" ]; then
  # Give Docker + compose a moment to settle after boot.
  sleep 30

  if ! /usr/bin/docker compose -f "${COMPOSE_CORE}" ps --status running >/dev/null 2>&1; then
    logger -s -t cashtrack-postreboot "compose ps failed on ${COMPOSE_CORE}"
    ok=0
  fi
fi

tmp="${TEXTFILE}.$$"
cat > "${tmp}" <<EOF
# HELP cashtrack_postreboot_check_ok 1 if the most recent post-reboot smoke check passed
# TYPE cashtrack_postreboot_check_ok gauge
cashtrack_postreboot_check_ok ${ok}
EOF
mv "${tmp}" "${TEXTFILE}"

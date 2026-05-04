#!/usr/bin/env bash
# Block Volume corruption DR runbook (design §17).
#
# `make replace` does NOT help when the Block Volume itself is corrupt — the
# new droplet inherits the same volume. Symptoms: cloud-init mount fails,
# fsck errors on boot, MySQL refuses to start with `Operating system error
# number 22`, files missing after a DO storage incident.
#
# This script is a guarded runbook. It snapshots the current volume for
# forensics, then walks the operator through the volume swap. The terraform
# work and the actual swap are operator-driven — this script is the
# checklist, not the executor — because the safe path depends on whether
# the live volume is mountable, whether MySQL is up, and which backup to
# restore from. Every destructive step is gated on a typed confirmation.
#
# Usage:
#   ./scripts/restore-to-new-volume.sh
#   ./scripts/restore-to-new-volume.sh --backup-id cashtrack-2026-04-25.sql.gz
#   ./scripts/restore-to-new-volume.sh --backup-id latest
#
# Env in:
#   DIGITALOCEAN_TOKEN                   doctl auth (snapshot, volume create)
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
#                                         operator Spaces creds (read backups)
#   AWS_ENDPOINT_URL_S3                   default https://ams3.digitaloceanspaces.com
#   RESTORE_BACKUP_BUCKET                 default cash-track-backups
#   RESTORE_VOLUME_NAME                   default cashtrack-data
#   RESTORE_REGION                        default ams3
#   DOCTL_BIN                             default doctl
#   AWS_BIN                               default aws
#
# Exit codes:
#   0  runbook completed (or operator chose to abort cleanly)
#   1  validation / precondition failure
#   2  external command failure during a guarded step

set -euo pipefail

VOLUME_NAME="${RESTORE_VOLUME_NAME:-cashtrack-data}"
REGION="${RESTORE_REGION:-ams3}"
BACKUP_BUCKET="${RESTORE_BACKUP_BUCKET:-cash-track-backups}"
ENDPOINT="${AWS_ENDPOINT_URL_S3:-https://ams3.digitaloceanspaces.com}"
DOCTL_BIN="${DOCTL_BIN:-doctl}"
AWS_BIN="${AWS_BIN:-aws}"

BACKUP_ID=""

err()  { printf '%s\n' "$*" >&2; }
note() { printf '[restore-to-new-volume] %s\n' "$*"; }
hr()   { printf '\n────────────────────────────────────────────────────────────\n\n'; }

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --backup-id) BACKUP_ID="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) err "Unknown argument: $1"; usage ;;
  esac
done

confirm() {
  local prompt="$1"
  local expected="$2"
  printf '\n%s\n' "$prompt"
  printf "Type '%s' to continue, anything else to abort: " "$expected"
  local got
  IFS= read -r got
  if [ "$got" != "$expected" ]; then
    err "Aborted by operator."
    exit 0
  fi
}

require_cmd() {
  for c in "$@"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      err "ERROR: '$c' not on PATH."
      exit 1
    fi
  done
}

main() {
  require_cmd "$DOCTL_BIN" "$AWS_BIN" jq terraform ansible-playbook

  : "${DIGITALOCEAN_TOKEN:?DIGITALOCEAN_TOKEN required}"
  : "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID required}"
  : "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY required}"

  hr
  cat <<'EOF'
Block Volume corruption DR runbook — design §17.

Triage check first. This procedure is for cases where the Block Volume itself
is corrupt:
  • cloud-init mount fails after a `make replace`
  • fsck errors on boot
  • MySQL refuses to start with "Operating system error number 22"
  • files missing after a DO storage incident

If the droplet is reachable but the volume mounts cleanly, this is the WRONG
runbook — escalate via design §17 steps 1–3 (`docker compose restart`,
`systemctl restart docker`, `power-cycle`) instead.

This script will:
  1. snapshot the existing (suspected-corrupt) volume for forensics
  2. tell you the doctl + terraform commands to provision a new volume
  3. when you confirm the new volume is mounted, run ops/backup-restore.yml
     to load the latest good backup into MySQL on the new volume.

Every destructive step is gated.
EOF
  hr
  confirm "Proceed with the block-volume-corruption runbook?" "yes"

  # Step 1 — stop scheduled jobs to avoid writing to a volume about to be discarded.
  hr
  cat <<EOF
Step 1: stop scheduled jobs (Ofelia + mysql-backup) on the droplet so nothing
        writes to the suspect volume mid-recovery. Run on the droplet:

  tailscale ssh ops@cashtrack-prod-0 \\
    "cd /opt/cashtrack && docker compose -f compose.core.yml -f compose.app.yml -f compose.obs.yml -f compose.telegram.yml -f compose.potwora.yml stop ofelia mysql-backup"

EOF
  confirm "Done?" "done"

  # Step 2 — find current volume id, take a forensic snapshot
  hr
  note "Looking up '${VOLUME_NAME}' in region '${REGION}'..."
  volume_json="$("$DOCTL_BIN" compute volume list --output json 2>/dev/null || true)"
  if [ -z "$volume_json" ]; then
    err "ERROR: doctl returned no volume listing. Check DIGITALOCEAN_TOKEN."
    exit 2
  fi

  volume_id="$(jq -r --arg n "$VOLUME_NAME" --arg r "$REGION" \
    '.[] | select(.name == $n and .region.slug == $r) | .id' <<<"$volume_json")"
  if [ -z "$volume_id" ] || [ "$volume_id" = "null" ]; then
    err "ERROR: no volume named '${VOLUME_NAME}' in region '${REGION}'."
    exit 2
  fi
  note "found volume id: ${volume_id}"

  snapshot_name="${VOLUME_NAME}-corrupt-$(date -u '+%Y%m%dT%H%M%SZ')"
  cat <<EOF

Snapshot will be named: ${snapshot_name}
This preserves forensic state (and pays the snapshot bill until you delete it).

EOF
  confirm "Take forensic snapshot now?" "yes"

  if ! "$DOCTL_BIN" compute volume snapshot "$volume_id" \
        --snapshot-name "$snapshot_name" \
        --snapshot-desc "forensic snapshot taken by restore-to-new-volume.sh"; then
    err "ERROR: snapshot creation failed."
    exit 2
  fi
  note "snapshot started: ${snapshot_name} (poll completion via 'doctl compute snapshot list')"

  # Step 3 — pick the backup
  hr
  if [ -z "$BACKUP_ID" ]; then
    note "No --backup-id supplied; latest 5 candidates from s3://${BACKUP_BUCKET}/:"
    "$AWS_BIN" --endpoint-url "$ENDPOINT" s3 ls "s3://${BACKUP_BUCKET}/" --recursive \
      | sort | tail -n5
    printf "\nEnter backup key (or 'latest'): "
    IFS= read -r BACKUP_ID
    if [ -z "$BACKUP_ID" ]; then
      err "ERROR: no backup id supplied."
      exit 1
    fi
  fi
  note "selected backup: ${BACKUP_ID}"

  # Step 4 — manual swap path
  hr
  cat <<EOF
Step 4 (operator-driven, terraform):

  Two patterns, pick one:

  (a) Provision a new volume and swap the terraform reference:
        - Edit terraform/terraform.tfvars to pin a new volume_name
          (e.g. cashtrack-data-2). Keep the OLD name on prevent_destroy
          until you have verified the restore — do not delete it yet.
        - terraform -chdir=terraform apply
        - Verify cloud-init mounted the new volume (mkfs blank, label set,
          /mnt/data populated).

  (b) If the volume is recoverable on a different host:
        - Detach via doctl, attach to a forensic droplet, fsck, copy out
          recoverable files. Outside the scope of this runbook.

EOF
  confirm "New volume mounted and droplet healthy?" "mounted"

  # Step 5 — restore via ansible
  hr
  note "Running ansible-playbook ops/backup-restore.yml -e backup_id=${BACKUP_ID}"
  ansible_dir="$(cd "$(dirname "$0")/../ansible" && pwd)"
  if ! (cd "$ansible_dir" && ansible-playbook ops/backup-restore.yml -e "backup_id=${BACKUP_ID}"); then
    err "ERROR: backup-restore playbook failed. Inspect output, fix, and re-run this step manually."
    exit 2
  fi

  hr
  cat <<EOF
Restore complete.

Final checks (do these now, before declaring the incident resolved):
  • docker compose -f compose.core.yml -f compose.app.yml -f compose.obs.yml -f compose.telegram.yml -f compose.potwora.yml ps  — all healthy on the droplet
  • curl https://api.cash-track.app/healthcheck
  • MySQL row counts vs counts_before in playbook output
  • Grafana: Backup freshness, MySQL connection count, api p95
  • cashtrack_postreboot_check_ok == 1
  • Restart Ofelia + mysql-backup:
      tailscale ssh ops@cashtrack-prod-0 \\
        "cd /opt/cashtrack && docker compose -f compose.core.yml -f compose.app.yml -f compose.obs.yml -f compose.telegram.yml -f compose.potwora.yml start ofelia mysql-backup"

Postmortem inputs to capture: snapshot id (${snapshot_name}), backup key
(${BACKUP_ID}), volume swap timeline, any data loss between RPO and incident.
EOF
}

main "$@"

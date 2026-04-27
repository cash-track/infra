#!/usr/bin/env bash
# Backup-freshness preflight for `make replace`.
#
# Refuses to run if the newest object in the backups bucket is older than
# REPLACE_BACKUP_MAX_HOURS (default 24h). The replacement flow can in principle
# corrupt the data volume (cloud-init bug, fat-fingered -replace target); the
# backup is the parachute, not the restore source. Stale backup → no parachute
# → no replace.
#
# Override: set FORCE_REPLACE_REASON='<incident-id>: <rationale>'.
# When the override fires, the script:
#   1. writes an audit record to s3://$TFSTATE_BUCKET/audit/replace-overrides/<ts>.json
#   2. posts an Alertmanager-style message to the ops Telegram channel
# Either failure aborts preflight (design §17 — non-optional).
#
# Env in:
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY  operator Spaces creds (read backups,
#                                              write tfstate audit). Required.
#   AWS_ENDPOINT_URL_S3                       Spaces endpoint. Default
#                                              https://ams3.digitaloceanspaces.com.
#   REPLACE_BACKUP_BUCKET                     default cash-track-backups
#   REPLACE_TFSTATE_BUCKET                    default cash-track-tfstate
#   REPLACE_BACKUP_MAX_HOURS                  default 24
#   FORCE_REPLACE_REASON                      non-empty unlocks override
#   TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID      ops bot creds (override path only)
#   AWS_BIN                                   aws CLI path (default `aws`); override for tests
#   CURL_BIN                                  curl path (default `curl`); override for tests
#
# Exit codes:
#   0  fresh backup, or override applied with audit + telegram both succeeded
#   1  stale backup, no override
#   2  override path failed (audit write or telegram post)
#   3  input/env validation failure

set -euo pipefail

BUCKET="${REPLACE_BACKUP_BUCKET:-cash-track-backups}"
TFSTATE_BUCKET="${REPLACE_TFSTATE_BUCKET:-cash-track-tfstate}"
ENDPOINT="${AWS_ENDPOINT_URL_S3:-https://ams3.digitaloceanspaces.com}"
MAX_HOURS="${REPLACE_BACKUP_MAX_HOURS:-24}"
AWS_BIN="${AWS_BIN:-aws}"
CURL_BIN="${CURL_BIN:-curl}"

err() { printf '%s\n' "$*" >&2; }
note() { printf '[preflight] %s\n' "$*"; }

aws_s3() { "$AWS_BIN" --endpoint-url "$ENDPOINT" s3 "$@"; }

require_env() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    err "ERROR: required env var $name is not set."
    exit 3
  fi
}

# Cross-platform "string in '%Y-%m-%d %H:%M:%S' UTC → epoch".
to_epoch() {
  local ts="$1"
  if date -j -u -f '%Y-%m-%d %H:%M:%S' "$ts" '+%s' >/dev/null 2>&1; then
    date -j -u -f '%Y-%m-%d %H:%M:%S' "$ts" '+%s'
  else
    date -u -d "$ts UTC" '+%s'
  fi
}

require_env AWS_ACCESS_KEY_ID
require_env AWS_SECRET_ACCESS_KEY

# Newest object: `aws s3 ls --recursive` prints `YYYY-MM-DD HH:MM:SS  size  key`,
# sorted lexicographically — same as chronologically given the date format —
# so `tail -n1` is the newest.
listing="$(aws_s3 ls "s3://${BUCKET}/" --recursive | sort | tail -n1 || true)"
if [ -z "$listing" ]; then
  err "ERROR: bucket s3://${BUCKET}/ is empty — no backup to validate against."
  exit 3
fi

last_date="$(awk '{print $1}' <<<"$listing")"
last_time="$(awk '{print $2}' <<<"$listing")"
last_key="$(awk '{for (i=4; i<=NF; i++) printf "%s%s", $i, (i<NF?" ":""); print ""}' <<<"$listing")"

last_epoch="$(to_epoch "${last_date} ${last_time}")"
now_epoch="$(date -u '+%s')"
age_seconds=$((now_epoch - last_epoch))
age_hours=$((age_seconds / 3600))

if [ "$age_hours" -le "$MAX_HOURS" ]; then
  note "OK. Last backup: ${last_key} (${age_hours}h ago, cutoff ${MAX_HOURS}h)."
  exit 0
fi

# Stale path.
if [ -z "${FORCE_REPLACE_REASON:-}" ]; then
  cat >&2 <<EOF
ERROR: last backup is ${age_hours}h old (cutoff ${MAX_HOURS}h).
       Override:
         FORCE_REPLACE_REASON='<incident-id>: <why backup is stale AND why
         replacing now is lower risk than waiting>' make replace
       See design §17 (Backup-freshness override).
EOF
  exit 1
fi

require_env TELEGRAM_BOT_TOKEN
require_env TELEGRAM_CHAT_ID

ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
operator="${USER:-unknown}@$(hostname -s 2>/dev/null || hostname)"
audit_key="audit/replace-overrides/${ts}.json"

audit_tmp="$(mktemp)"
trap 'rm -f "$audit_tmp"' EXIT

cat >"$audit_tmp" <<EOF
{
  "timestamp": "${ts}",
  "operator": "${operator}",
  "force_replace_reason": $(printf '%s' "$FORCE_REPLACE_REASON" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'),
  "last_backup_key": "${last_key}",
  "last_backup_age_hours": ${age_hours},
  "max_age_hours": ${MAX_HOURS}
}
EOF

if ! aws_s3 cp --quiet \
      "$audit_tmp" "s3://${TFSTATE_BUCKET}/${audit_key}" \
      --acl private \
      --content-type application/json; then
  err "ERROR: failed to write audit record to s3://${TFSTATE_BUCKET}/${audit_key} — aborting."
  exit 2
fi
note "audit: s3://${TFSTATE_BUCKET}/${audit_key}"

msg="🚨 replace-preflight bypassed by ${operator}: ${FORCE_REPLACE_REASON} (last backup: ${age_hours}h)"
if ! "$CURL_BIN" -fsS \
      --max-time 10 \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=${msg}" \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      >/dev/null; then
  err "ERROR: failed to post Telegram alert — aborting (audit was written)."
  exit 2
fi
note "telegram alert posted to chat ${TELEGRAM_CHAT_ID}."
note "override accepted. Proceeding with replace."

#!/usr/bin/env bash
# Bootstrap the three DigitalOcean Spaces buckets used by the cashtrack
# stack. Idempotent: existing buckets are left alone, missing ones are
# created. Mints one access keypair per bucket on demand.
#
# This is the canonical record of what was set up by hand in design Stage 0.
# Operators normally never re-run it; documented here so a fresh environment
# (staging clone, DR rebuild) can be reproduced in one command.
#
# Run once per environment, with operator-level `doctl` auth.
#
# Usage:
#   doctl auth init           # if not already
#   ./scripts/bootstrap-buckets.sh
#
# Env overrides:
#   REGION                    DO Spaces region slug (default: ams3)
#   STORAGE_BUCKET            public bucket for user assets
#                             (default: cash-track-storage)
#   BACKUPS_BUCKET            private bucket for MySQL dumps
#                             (default: cash-track-backups)
#   TFSTATE_BUCKET            private bucket for terraform state + audit
#                             (default: cash-track-tfstate)
#
# After successful run:
#   - Three Spaces buckets exist (idempotent if already there).
#   - Three access keypairs printed to stdout. Operator MUST move each pair
#     into 1Password (`cash-track-prod` vault) and then run
#     `unset HISTFILE` / clear scrollback.

set -euo pipefail

REGION="${REGION:-ams3}"
STORAGE_BUCKET="${STORAGE_BUCKET:-cash-track-storage}"
BACKUPS_BUCKET="${BACKUPS_BUCKET:-cash-track-backups}"
TFSTATE_BUCKET="${TFSTATE_BUCKET:-cash-track-tfstate}"

DOCTL_BIN="${DOCTL_BIN:-doctl}"

err() { printf '%s\n' "$*" >&2; }
note() { printf '[bootstrap] %s\n' "$*"; }

require_doctl() {
  if ! command -v "$DOCTL_BIN" >/dev/null 2>&1; then
    err "ERROR: '$DOCTL_BIN' not on PATH. Install via 'brew install doctl' and 'doctl auth init'."
    exit 3
  fi
}

bucket_exists() {
  local name="$1"
  "$DOCTL_BIN" spaces bucket list --format Name --no-header 2>/dev/null \
    | awk '{print $1}' \
    | grep -Fxq "$name"
}

create_bucket_if_missing() {
  local name="$1"
  local acl="$2"

  if bucket_exists "$name"; then
    note "bucket exists: $name"
    return 0
  fi

  note "creating bucket: $name (acl=$acl, region=$REGION)"
  "$DOCTL_BIN" spaces bucket create "$name" \
    --region "$REGION" \
    --acl "$acl"
}

mint_keypair() {
  local label="$1"
  note "minting access key: $label (record output in 1Password and discard scrollback)"
  "$DOCTL_BIN" spaces keys create "$label" --format Name,AccessKey,SecretKey
}

main() {
  require_doctl

  create_bucket_if_missing "$STORAGE_BUCKET" "public-read"
  create_bucket_if_missing "$BACKUPS_BUCKET" "private"
  create_bucket_if_missing "$TFSTATE_BUCKET" "private"

  note "Reminder: enable 'Block all public access' on $TFSTATE_BUCKET in the DO console;"
  note "          enable bucket versioning with 90-day noncurrent retention on $TFSTATE_BUCKET."

  cat <<'EOF'

Next:
  - Mint one access keypair per bucket below. Each keypair is account-wide on
    DO Spaces (no per-bucket scoping); the separation is policy: one keypair
    per role for blast-radius containment.
  - Move every keypair into the 'cash-track-prod' 1Password vault as the
    matching items: cash-track-storage, cash-track-backups, cash-track-tfstate.
  - Clear scrollback (`clear; printf '\033c'`) and `unset HISTFILE` after.

EOF

  mint_keypair "cash-track-storage"
  mint_keypair "cash-track-backups"
  mint_keypair "cash-track-tfstate"
}

main "$@"

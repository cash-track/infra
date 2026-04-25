#!/usr/bin/env bash
# Dynamic inventory: reads `terraform output -json` and emits Ansible inventory JSON.
# Override TF_OUTPUT in the environment to drive from a fixture (used by tests).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/../../../terraform"

TF_OUTPUT="${TF_OUTPUT:-$(terraform -chdir="${TF_DIR}" output -json)}"

RIP=$(jq -r '.reserved_ip.value' <<<"$TF_OUTPUT")
HOSTNAME=$(jq -r '.tailscale_hostname.value' <<<"$TF_OUTPUT")

cat <<JSON
{
  "prod": { "hosts": ["$HOSTNAME"], "vars": { "reserved_ip": "$RIP" } },
  "_meta": { "hostvars": { "$HOSTNAME": { "ansible_host": "$HOSTNAME", "ansible_user": "ops" } } }
}
JSON

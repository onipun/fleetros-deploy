#!/usr/bin/env bash
# Render Ansible prod inventory from `tofu output -json`.
set -euo pipefail

TOFU_JSON="${1:-/tmp/tofu-out.json}"
OUT="${2:-infra/ansible/inventory/prod.yml}"

VPS_IP=$(jq -r '.vps_ip.value' "$TOFU_JSON")
VPS_USER=$(jq -r '.vps_user.value // "deploy"' "$TOFU_JSON")

cat > "$OUT" <<EOF
---
all:
  vars:
    ansible_user: ${VPS_USER}
    ansible_ssh_private_key_file: "~/.ssh/id_ed25519"
    fleetros_env: prod
  hosts:
    fleetros-prod:
      ansible_host: ${VPS_IP}
EOF

echo "Wrote $OUT (host: ${VPS_IP})"

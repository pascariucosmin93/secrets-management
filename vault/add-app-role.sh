#!/usr/bin/env bash
# Registers a new application in Vault:
#   - creates a KV policy scoped to the app path
#   - creates a Kubernetes auth role bound to the app's service account
#
# Usage: ./add-app-role.sh <app-name> <namespace>
# Example: ./add-app-role.sh cv-website cv
set -euo pipefail

APP="${1:?Usage: $0 <app-name> <namespace>}"
NAMESPACE="${2:?Usage: $0 <app-name> <namespace>}"

echo "==> Writing policy for ${APP}..."
vault policy write "${APP}" - <<EOF
path "secret/data/${NAMESPACE}/${APP}/*" {
  capabilities = ["read", "list"]
}
EOF

echo "==> Creating Kubernetes auth role for ${APP}..."
vault write "auth/kubernetes/role/${APP}" \
  bound_service_account_names="${APP}" \
  bound_service_account_namespaces="${NAMESPACE}" \
  policies="${APP}" \
  ttl=1h

echo "==> Done. Service account '${APP}' in namespace '${NAMESPACE}' can now read secrets at secret/data/${NAMESPACE}/${APP}/*"

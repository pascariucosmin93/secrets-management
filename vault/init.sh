#!/usr/bin/env bash
# Initializes Vault, enables Kubernetes auth, KV-v2, and PKI engines.
# Run once after first deploy. Requires kubectl and vault CLI.
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
NAMESPACE="${NAMESPACE:-vault}"

echo "==> Initializing Vault..."
INIT_OUTPUT=$(kubectl exec -n "$NAMESPACE" vault-0 -- vault operator init \
  -key-shares=5 \
  -key-threshold=3 \
  -format=json)

echo "$INIT_OUTPUT" > vault-init.json
echo "    Init output saved to vault-init.json — store this securely and DELETE the file."

UNSEAL_KEY_1=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[0]')
UNSEAL_KEY_2=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[1]')
UNSEAL_KEY_3=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[2]')
ROOT_TOKEN=$(echo "$INIT_OUTPUT" | jq -r '.root_token')

echo "==> Unsealing vault-0..."
kubectl exec -n "$NAMESPACE" vault-0 -- vault operator unseal "$UNSEAL_KEY_1"
kubectl exec -n "$NAMESPACE" vault-0 -- vault operator unseal "$UNSEAL_KEY_2"
kubectl exec -n "$NAMESPACE" vault-0 -- vault operator unseal "$UNSEAL_KEY_3"

echo "==> Joining and unsealing vault-1, vault-2..."
for pod in vault-1 vault-2; do
  kubectl exec -n "$NAMESPACE" "$pod" -- vault operator raft join http://vault-0.vault-internal:8200
  kubectl exec -n "$NAMESPACE" "$pod" -- vault operator unseal "$UNSEAL_KEY_1"
  kubectl exec -n "$NAMESPACE" "$pod" -- vault operator unseal "$UNSEAL_KEY_2"
  kubectl exec -n "$NAMESPACE" "$pod" -- vault operator unseal "$UNSEAL_KEY_3"
done

export VAULT_TOKEN="$ROOT_TOKEN"

echo "==> Enabling KV-v2 secrets engine..."
vault secrets enable -path=secret kv-v2

echo "==> Enabling Kubernetes auth method..."
vault auth enable kubernetes

K8S_HOST=$(kubectl exec -n "$NAMESPACE" vault-0 -- \
  sh -c 'echo $KUBERNETES_SERVICE_HOST')
K8S_CA=$(kubectl config view --raw --minify --flatten \
  -o jsonpath='{.clusters[].cluster.certificate-authority-data}' | base64 -d)
SA_JWT=$(kubectl create token -n "$NAMESPACE" vault --duration=8760h)

vault write auth/kubernetes/config \
  kubernetes_host="https://${K8S_HOST}:443" \
  kubernetes_ca_cert="$K8S_CA" \
  token_reviewer_jwt="$SA_JWT" \
  disable_iss_validation=true

echo "==> Enabling PKI secrets engine..."
vault secrets enable pki
vault secrets tune -max-lease-ttl=87600h pki

vault write pki/root/generate/internal \
  common_name="homelab-root-ca" \
  ttl=87600h

vault write pki/config/urls \
  issuing_certificates="${VAULT_ADDR}/v1/pki/ca" \
  crl_distribution_points="${VAULT_ADDR}/v1/pki/crl"

vault secrets enable -path=pki_int pki
vault secrets tune -max-lease-ttl=43800h pki_int

CSR=$(vault write -format=json pki_int/intermediate/generate/internal \
  common_name="homelab-intermediate-ca" | jq -r '.data.csr')

SIGNED=$(vault write -format=json pki/root/sign-intermediate \
  csr="$CSR" format=pem_bundle ttl=43800h | jq -r '.data.certificate')

vault write pki_int/intermediate/set-signed certificate="$SIGNED"

vault write pki_int/config/urls \
  issuing_certificates="${VAULT_ADDR}/v1/pki_int/ca" \
  crl_distribution_points="${VAULT_ADDR}/v1/pki_int/crl"

vault write pki_int/roles/homelab \
  allowed_domains="cosmin-lab.com,cluster.local" \
  allow_subdomains=true \
  allow_bare_domains=true \
  max_ttl=2160h

echo "==> Writing policies..."
vault policy write eso - <<'EOF'
path "secret/data/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/*" {
  capabilities = ["read", "list"]
}
EOF

vault policy write eso-push - <<'EOF'
path "secret/data/*" {
  capabilities = ["create", "update"]
}
path "secret/metadata/*" {
  capabilities = ["read", "list"]
}
EOF

vault policy write pki-cert-manager - <<'EOF'
path "pki_int/sign/homelab" {
  capabilities = ["create", "update"]
}
path "pki_int/issue/homelab" {
  capabilities = ["create", "update"]
}
EOF

echo "==> Creating Kubernetes auth roles..."
vault write auth/kubernetes/role/eso \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=eso \
  ttl=1h

vault write auth/kubernetes/role/cert-manager \
  bound_service_account_names=cert-manager \
  bound_service_account_namespaces=cert-manager \
  policies=pki-cert-manager \
  ttl=1h

vault write auth/kubernetes/role/eso-push \
  bound_service_account_names=external-secrets-push \
  bound_service_account_namespaces=external-secrets \
  policies=eso-push \
  ttl=1h

echo "==> Done. Root token and unseal keys are in vault-init.json — store securely."

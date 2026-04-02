#!/usr/bin/env bash
# Fetch the Sealed Secrets controller's public certificate.
# Run this once and commit the cert to your repo — developers use it to encrypt secrets locally.
# The private key never leaves the cluster.
set -euo pipefail

CERT_FILE="${1:-sealed-secrets/pub-cert.pem}"

echo "==> Fetching Sealed Secrets public certificate..."
kubeseal --controller-name=sealed-secrets-controller \
         --controller-namespace=sealed-secrets \
         --fetch-cert > "$CERT_FILE"

echo "    Certificate saved to $CERT_FILE"
echo "    Commit this file to Git — it is public and safe to share."
echo "    Developers use it to encrypt secrets offline (without cluster access):"
echo "      kubeseal --cert $CERT_FILE -f secret.yaml -w sealed-secret.yaml"

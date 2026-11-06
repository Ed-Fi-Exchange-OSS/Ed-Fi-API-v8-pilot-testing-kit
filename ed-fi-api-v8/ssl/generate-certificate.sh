#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Licensed to the Ed-Fi Alliance under one or more agreements.
# The Ed-Fi Alliance licenses this file to you under the Apache License, Version 2.0.
# See the LICENSE and NOTICES files in the project root for more information.

# Creates a self-signed TLS certificate for the kit's NGINX ingress:
# server.crt and server.key next to this script, RSA 2048, valid 365 days,
# SANs DNS:localhost, DNS:nginx, IP:127.0.0.1. For local development only.
# generate-certificate.ps1 does the same thing with the same options.

set -eu

usage() {
    cat <<'EOF'
Usage: generate-certificate.sh [--force]

Creates server.crt and server.key in the ssl directory for local HTTPS.

  --force    Replace existing server.crt and server.key.
  --help     Show this help.
EOF
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

force=false
for arg in "$@"; do
    case "$arg" in
        --force | -Force | -f) force=true ;;
        --help | -h) usage; exit 0 ;;
        *) usage >&2; fail "Unknown option '$arg'." ;;
    esac
done

ssl_dir=$(cd "$(dirname "$0")" && pwd)
crt="$ssl_dir/server.crt"
key="$ssl_dir/server.key"
days=365

if [ "$force" != true ] && [ -e "$crt" ] && [ -e "$key" ]; then
    fail "server.crt and server.key already exist in $ssl_dir. Run again with --force to replace them."
fi

command -v openssl >/dev/null 2>&1 ||
    fail "openssl was not found on PATH. Install OpenSSL, or run generate-certificate.ps1 with PowerShell 7."

# Work in a scratch directory inside ssl/ and give openssl only relative file names. Under Git Bash
# on Windows, /tmp (and /c/... style paths) exist only inside the MSYS runtime; the Windows build of
# OpenSSL can't see them, and the kit sets MSYS_NO_PATHCONV=1, which stops Git Bash from translating
# them. Relative names resolve the same way for every OpenSSL build and every platform.
work=$(mktemp -d "$ssl_dir/.generate.XXXXXX")
trap 'cd "$ssl_dir" && rm -rf "$work"' EXIT
cd "$work"

# An explicit config (instead of -subj/-addext) behaves the same on OpenSSL 1.1, 3.x,
# LibreSSL, and Git Bash. The extensions mirror a typical localhost development
# certificate: an end-entity (CA:FALSE) server certificate.
cat > openssl.cnf <<'EOF'
[req]
prompt = no
distinguished_name = dn
x509_extensions = v3

[dn]
CN = localhost

[v3]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:localhost, DNS:nginx, IP:127.0.0.1
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF

(
    umask 077
    openssl req -x509 -config openssl.cnf -newkey rsa:2048 -sha256 -nodes -days "$days" \
        -keyout server.key -out server.crt 2>openssl.log ||
        { cat openssl.log >&2; fail "openssl could not create the certificate."; }
)

chmod 644 "$work/server.crt"
mv -f "$work/server.crt" "$crt"
mv -f "$work/server.key" "$key"

cat <<EOF
Created a self-signed certificate for local development:
  $crt
  $key
  Valid for $days days. SANs: DNS:localhost, DNS:nginx, IP:127.0.0.1

Next steps:
  1. Start the kit, or run 'docker compose restart nginx' if it is already running.
  2. Clients do not trust this certificate by default. Trust server.crt in your OS or
     tool, or point the client at it, for example:
       curl --cacert ssl/server.crt https://localhost/api
       Python requests: verify="ssl/server.crt"
       Node.js: NODE_EXTRA_CA_CERTS=ssl/server.crt
  3. Keep server.key private. It is for this machine only and must not be committed.
EOF

#!/usr/bin/env bash
# Cria Root CA, ICA e OCSP signer. Uso: init-pki.sh [--force]
exec "$(dirname "$0")/pki.sh" init "$@"

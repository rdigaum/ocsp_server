#!/usr/bin/env bash
# Lista certificados da ICA e status. Uso: list-certs.sh
exec "$(dirname "$0")/pki.sh" list "$@"

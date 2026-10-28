#!/usr/bin/env bash
# Revoga certificado. Uso: revoke-cert.sh <nome|serial> [motivo]
exec "$(dirname "$0")/pki.sh" revoke "$@"

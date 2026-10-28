#!/usr/bin/env bash
# Consulta o OCSP responder. Uso: check-cert.sh <nome|serial> [--get] [--url URL]
exec "$(dirname "$0")/pki.sh" check "$@"

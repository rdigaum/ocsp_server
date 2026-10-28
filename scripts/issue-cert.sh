#!/usr/bin/env bash
# Emite certificado de cliente. Uso: issue-cert.sh <nome> [--cn CN] [--email E] [--dns H] [--days N] [--ec] [--p12-pass S]
exec "$(dirname "$0")/pki.sh" issue "$@"

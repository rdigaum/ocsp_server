#!/usr/bin/env bash
# Remove a revogação (volta a good). Uso: unrevoke-cert.sh <nome|serial>
exec "$(dirname "$0")/pki.sh" unrevoke "$@"

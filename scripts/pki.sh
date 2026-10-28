#!/usr/bin/env bash
# Executa o pkictl num container efêmero com o mesmo volume ./pki do serviço.
# O responder em execução recarrega a base sozinho — não precisa reiniciar.
set -euo pipefail
cd "$(dirname "$0")/.."
exec docker compose run --rm --no-deps -T ocsp pkictl "$@"

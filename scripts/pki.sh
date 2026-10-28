#!/usr/bin/env bash
# Executa o pkictl num container efêmero com o mesmo volume ./pki do serviço.
# O responder em execução recarrega a base sozinho — não precisa reiniciar.
#
# Roda com o UID/GID de quem chamou (mesmo via sudo), para que os arquivos em
# ./pki pertençam ao usuário e não ao root no Linux.
set -euo pipefail
cd "$(dirname "$0")/.."
uid=$(id -u) gid=$(id -g)
if [[ $uid -eq 0 && -n ${SUDO_UID:-} ]]; then uid=$SUDO_UID gid=$SUDO_GID; fi
exec docker compose run --rm --no-deps -T --user "$uid:$gid" ocsp pkictl "$@"

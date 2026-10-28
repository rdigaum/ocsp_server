#!/usr/bin/env bash
set -euo pipefail

if [[ ${1:-serve} != serve ]]; then
  exec "$@"
fi

# Espera a PKI existir em vez de entrar em restart loop — permite subir o serviço
# antes de rodar scripts/init-pki.sh.
waited=0
until [[ -f $PKI_DIR/ica/ica.crt && -f $PKI_DIR/ocsp/ocsp.crt && -f $PKI_DIR/ica/index.txt ]]; do
  (( waited % 30 == 0 )) && echo "aguardando PKI em $PKI_DIR — rode scripts/init-pki.sh" >&2
  sleep 2; waited=$((waited + 2))
done

exec python /opt/ocsp/ocsp_server.py

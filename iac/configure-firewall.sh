#!/usr/bin/env bash
# configure-firewall.sh — libera a porta HTTP do responder no UFW, se ele estiver ativo.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_sudo

PORT="$(env_get HTTP_PORT)"
PORT="${PORT:-80}"

if ! command -v ufw &>/dev/null; then
    info "UFW não instalado — nada a configurar"
elif ! $SUDO ufw status 2>/dev/null | grep -q "Status: active"; then
    info "UFW inativo — nada a configurar"
else
    $SUDO ufw allow "${PORT}/tcp" comment "OCSP responder" >/dev/null
    info "UFW: porta ${PORT}/tcp liberada ✓"
fi

warn "Em cloud (AWS/GCP/Azure/OCI...), libere também ${PORT}/tcp no security group / firewall"
warn "do provedor: a Akamai consulta o OCSP a partir da internet."

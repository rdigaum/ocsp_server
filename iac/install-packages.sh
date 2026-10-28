#!/usr/bin/env bash
# install-packages.sh — pacotes base do sistema usados pela instalação e pelos scripts.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_ubuntu
require_sudo

# ca-certificates/curl/gnupg: repositório do Docker
# git: atualizar o projeto | openssl: testes OCSP a partir do host
# iproute2 (ss): checagem da porta | dnsutils (dig): checagem do DNS
PKGS=(ca-certificates curl gnupg git openssl iproute2 dnsutils)

info "Instalando pacotes APT: ${PKGS[*]}"
$SUDO apt-get update -qq
$SUDO apt-get install -y -qq "${PKGS[@]}" >/dev/null
info "Pacotes base ✓"

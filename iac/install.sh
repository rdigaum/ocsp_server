#!/usr/bin/env bash
# install.sh — instala o OCSP responder num Ubuntu (22.04+) a partir do diretório
# clonado do projeto. Ao final, basta editar o .env e subir com docker compose.
#
# Uso:  bash iac/install.sh [--no-firewall]
#
# Etapas (cada uma também pode ser executada isoladamente):
#   1. iac/install-packages.sh    pacotes base (curl, git, openssl, ss, dig...)
#   2. iac/install-docker.sh      Docker Engine + Compose plugin + grupo docker
#   3. iac/configure-firewall.sh  libera HTTP_PORT no UFW (se ativo)
#   4. iac/prepare-project.sh     .env, ./pki e permissões
# Depois de editar o .env:  bash iac/check-env.sh
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FIREWALL=1
for arg in "$@"; do
    case $arg in
        --no-firewall) FIREWALL=0 ;;
        -h|--help) sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) error "opção desconhecida: $arg (use --help)" ;;
    esac
done

echo ""
echo "================================================"
echo "  OCSP Server — instalação (Ubuntu)"
echo "================================================"
echo ""

require_ubuntu
require_sudo
info "Sistema: ${PRETTY_NAME:-Ubuntu} | projeto: $PROJECT_DIR | usuário: $REAL_USER"

step "1/4 — Pacotes base"
bash "$IAC_DIR/install-packages.sh"

step "2/4 — Docker"
bash "$IAC_DIR/install-docker.sh"

step "3/4 — Firewall"
if ((FIREWALL)); then bash "$IAC_DIR/configure-firewall.sh"; else info "ignorado (--no-firewall)"; fi

step "4/4 — Projeto"
bash "$IAC_DIR/prepare-project.sh"

DOCKER_PREFIX=""
docker info &>/dev/null || DOCKER_PREFIX="sudo "

echo ""
echo "================================================"
echo "  Instalação concluída"
echo "================================================"
echo ""
echo "  Próximos passos (no diretório $PROJECT_DIR):"
echo ""
echo "  1. Edite o .env — principalmente OCSP_HOSTNAME e OCSP_PATH, que formam a"
echo "     URI gravada no AIA dos certificados (não muda depois da emissão):"
echo "       nano .env"
echo ""
echo "  2. Valide host e configuração:"
echo "       bash iac/check-env.sh"
echo ""
echo "  3. Construa e suba o serviço:"
echo "       ${DOCKER_PREFIX}docker compose up -d --build"
echo ""
echo "  4. Crie a PKI e emita certificados:"
echo "       ./scripts/init-pki.sh"
echo "       ./scripts/issue-cert.sh cliente01"
echo "       ./scripts/check-cert.sh cliente01"
echo ""
if [[ -n $DOCKER_PREFIX ]]; then
    warn "O grupo docker só vale após novo login. Até lá, use 'newgrp docker' ou sudo."
    echo ""
fi

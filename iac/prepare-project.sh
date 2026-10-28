#!/usr/bin/env bash
# prepare-project.sh — deixa o diretório do projeto pronto para o docker compose:
# .env a partir do modelo, diretório ./pki do usuário, permissões dos scripts.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cd "$PROJECT_DIR"

if [[ -f .env ]]; then
    info ".env já existe — mantido"
else
    as_user cp .env.example .env
    as_user chmod 600 .env
    info ".env criado a partir de .env.example"
fi

# ./pki precisa existir e pertencer ao usuário ANTES do primeiro "docker compose":
# se o Docker criar o diretório do bind mount, ele nasce com dono root.
if [[ ! -d pki ]]; then
    as_user mkdir -p pki
    info "diretório ./pki criado"
fi
owner="$(stat -c %U pki)"
if [[ "$owner" != "$REAL_USER" ]]; then
    $SUDO chown -R "$REAL_USER:$REAL_GROUP" pki
    warn "./pki pertencia a '$owner' — dono ajustado para '$REAL_USER'"
fi
as_user chmod 700 pki
info "./pki pronto (dono $REAL_USER, modo 700) ✓"

as_user chmod +x scripts/*.sh pki-tools/pkictl docker/entrypoint.sh iac/*.sh
info "permissões de execução dos scripts ✓"

if docker_cmd compose config -q 2>/dev/null; then
    info "docker-compose.yml + .env válidos ✓"
else
    warn "não foi possível validar o docker-compose.yml (o Docker está acessível?)"
fi

#!/usr/bin/env bash
# install-docker.sh — Docker Engine + Compose plugin pelo repositório oficial da Docker,
# e acesso ao Docker para o usuário que vai operar o projeto. Idempotente.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_ubuntu
require_sudo

if command -v docker &>/dev/null && docker compose version &>/dev/null; then
    info "Docker já instalado: $(docker --version | awk '{print $3}' | tr -d ','), Compose $(docker compose version --short)"
else
    if command -v docker &>/dev/null; then
        # docker.io (pacote do Ubuntu) sem o plugin compose — conflita com o repositório oficial
        error "Docker encontrado sem o plugin 'docker compose'. Remova a instalação atual
        (ex.: sudo apt-get remove docker.io docker-compose podman-docker) ou instale o
        plugin compose manualmente, e execute novamente."
    fi

    info "Instalando Docker Engine via repositório oficial (download.docker.com)..."
    $SUDO install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | $SUDO tee /etc/apt/keyrings/docker.asc >/dev/null
    $SUDO chmod a+r /etc/apt/keyrings/docker.asc

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" \
        | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null

    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin >/dev/null
    info "Docker $(docker --version | awk '{print $3}' | tr -d ','), Compose $(docker compose version --short) ✓"
fi

if has_systemd; then
    $SUDO systemctl enable --now docker >/dev/null 2>&1
    info "Serviço docker habilitado e iniciado ✓"
else
    warn "systemd não detectado (container/WSL) — inicie o daemon Docker manualmente"
fi

# Acesso ao Docker sem sudo para o usuário que opera o projeto
if [[ "$REAL_USER" != "root" ]]; then
    if id -nG "$REAL_USER" | tr ' ' '\n' | grep -qx docker; then
        info "Usuário '$REAL_USER' já pertence ao grupo docker ✓"
    else
        $SUDO usermod -aG docker "$REAL_USER"
        warn "Usuário '$REAL_USER' adicionado ao grupo docker — faça logout/login"
        warn "(ou execute 'newgrp docker') para usar docker sem sudo"
    fi
fi

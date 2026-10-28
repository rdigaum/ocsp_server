#!/usr/bin/env bash
# lib.sh — funções comuns dos scripts de instalação (iac/). Usar via "source".

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step()  { echo -e "${BLUE}[STEP]${NC}  $*"; }

IAC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$IAC_DIR")"

SUDO=""
[[ "$(id -u)" -ne 0 ]] && SUDO="sudo"

# Usuário "real" que vai operar o projeto (dono do .env e do ./pki), mesmo quando
# o script é executado com sudo. SUDO_USER só vale se estamos de fato como root —
# um "sudo -u ops" a partir do root também define SUDO_USER=root.
if [[ "$(id -u)" -eq 0 ]]; then
    REAL_USER="${SUDO_USER:-root}"
else
    REAL_USER="$(id -un)"
fi
REAL_GROUP="$(id -gn "$REAL_USER")"

export DEBIAN_FRONTEND=noninteractive

require_ubuntu() {
    [[ -r /etc/os-release ]] || error "/etc/os-release não encontrado — este instalador é para Ubuntu"
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" && " ${ID_LIKE:-} " != *" ubuntu "* ]]; then
        error "SO não suportado: ${PRETTY_NAME:-desconhecido} (requer Ubuntu 22.04+ ou derivado)"
    fi
    UBUNTU_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    [[ -n "$UBUNTU_CODENAME" ]] || error "não foi possível identificar o codename do Ubuntu"
}

require_sudo() {
    if [[ -n "$SUDO" ]]; then
        command -v sudo &>/dev/null || error "sudo não encontrado — execute como root"
        sudo -v || error "sem permissão de sudo"
    fi
}

# systemd disponível? (falso dentro de containers / WSL sem systemd)
has_systemd() { [[ -d /run/systemd/system ]]; }

# Lê uma variável do .env sem executar o arquivo (valores podem ter espaços).
env_get() {
    local key=$1 file=${2:-$PROJECT_DIR/.env}
    [[ -f $file ]] || return 0
    grep -E "^${key}=" "$file" | tail -1 | cut -d= -f2- | sed -E 's/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/'
}

# Executa como o usuário real (útil quando o instalador roda com sudo).
as_user() {
    if [[ "$(id -un)" == "$REAL_USER" ]]; then "$@"; else sudo -u "$REAL_USER" "$@"; fi
}

# Docker utilizável pelo usuário atual? Senão usa sudo.
docker_cmd() {
    if docker info &>/dev/null; then docker "$@"; else $SUDO docker "$@"; fi
}

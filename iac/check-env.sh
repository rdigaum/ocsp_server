#!/usr/bin/env bash
# check-env.sh — valida o host e o .env antes do "docker compose up".
# Erros (FAIL) impedem o funcionamento; avisos (WARN) devem ser conferidos.
set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cd "$PROJECT_DIR"
FAILS=0
ok()   { echo -e "  ${GREEN}OK${NC}    $*"; }
fail() { echo -e "  ${RED}FAIL${NC}  $*"; FAILS=$((FAILS + 1)); }
wrn()  { echo -e "  ${YELLOW}WARN${NC}  $*"; }

echo ""
echo "Verificando ambiente do OCSP responder ($PROJECT_DIR)"
echo ""

# ── Docker ────────────────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    fail "docker não instalado — execute iac/install.sh"
elif docker info &>/dev/null; then
    ok "Docker acessível pelo usuário $(id -un)"
elif $SUDO docker info &>/dev/null; then
    wrn "Docker só acessível com sudo — faça logout/login (grupo docker) ou use 'newgrp docker'"
else
    fail "daemon Docker não está respondendo (sudo systemctl start docker)"
fi
docker compose version &>/dev/null && ok "Docker Compose $(docker compose version --short)" \
    || fail "plugin docker compose ausente"

# ── .env ──────────────────────────────────────────────────────────────────────
if [[ ! -f .env ]]; then
    fail ".env não encontrado — execute iac/prepare-project.sh (ou cp .env.example .env)"
    echo ""; exit 1
fi
ok ".env encontrado"

HOSTNAME_="$(env_get OCSP_HOSTNAME)"; HOSTNAME_="${HOSTNAME_:-ocsp.rdigaum.com.br}"
PATH_="$(env_get OCSP_PATH)";         PATH_="${PATH_:-/ocsp/validation}"
PORT="$(env_get HTTP_PORT)";          PORT="${PORT:-80}"
VALIDITY="$(env_get OCSP_VALIDITY_SECONDS)"; VALIDITY="${VALIDITY:-300}"
p="/${PATH_#/}"; p="${p%/}"          # mesma normalização do pkictl: "/" -> ""
URI="http://${HOSTNAME_}${p}"

if [[ $HOSTNAME_ =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]; then
    ok "OCSP_HOSTNAME=$HOSTNAME_"
else
    fail "OCSP_HOSTNAME inválido: '$HOSTNAME_' (use um FQDN, sem http:// e sem path)"
fi
[[ $p =~ ^(/[A-Za-z0-9._~-]+)*$ ]] && ok "OCSP_PATH=${PATH_}" \
    || fail "OCSP_PATH inválido: '$PATH_' (segmentos com letras, números e . _ ~ -)"
[[ $PORT =~ ^[0-9]+$ ]] && ((PORT > 0 && PORT < 65536)) && ok "HTTP_PORT=$PORT" \
    || fail "HTTP_PORT inválida: '$PORT'"
[[ $VALIDITY =~ ^[0-9]+$ ]] && ok "OCSP_VALIDITY_SECONDS=$VALIDITY" \
    || fail "OCSP_VALIDITY_SECONDS inválido: '$VALIDITY'"
[[ $PORT == 80 ]] || wrn "HTTP_PORT=$PORT — a URI do AIA ($URI) usa a porta 80; só use outra porta atrás de proxy/NAT"
echo "        AIA dos certificados: OCSP - URI:$URI"

if docker_cmd compose config -q 2>/dev/null; then ok "docker-compose.yml + .env válidos"
else fail "docker compose config falhou — rode 'docker compose config' para ver o erro"; fi

# ── Porta ─────────────────────────────────────────────────────────────────────
if command -v ss &>/dev/null; then
    listener="$($SUDO ss -Hltnp "sport = :$PORT" 2>/dev/null | head -1)"
    if [[ -z $listener ]]; then
        ok "porta $PORT/tcp livre"
    elif [[ $listener == *docker-proxy* ]] && docker_cmd compose ps -q ocsp 2>/dev/null | grep -q .; then
        ok "porta $PORT/tcp em uso pelo próprio OCSP responder"
    else
        fail "porta $PORT/tcp ocupada: $(echo "$listener" | grep -o 'users:.*' || echo "$listener")"
        echo "        (ex.: apache2/nginx — sudo systemctl disable --now apache2 nginx)"
    fi
fi

# ── DNS ───────────────────────────────────────────────────────────────────────
resolved="$(getent ahostsv4 "$HOSTNAME_" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
if [[ -z $resolved ]]; then
    wrn "DNS: $HOSTNAME_ não resolve — necessário para a Akamai (testes locais funcionam sem)"
else
    local_ips="$(hostname -I 2>/dev/null)"
    match=0
    for ip in $resolved; do [[ " $local_ips " == *" $ip "* ]] && match=1; done
    if ((match)); then
        ok "DNS: $HOSTNAME_ → $resolved(IP deste host)"
    else
        wrn "DNS: $HOSTNAME_ → $resolved— não é um IP local ($local_ips)."
        echo "        Normal em cloud/NAT: confirme que é o IP público deste host."
    fi
fi

echo ""
if ((FAILS)); then
    echo -e "${RED}$FAILS verificação(ões) falharam — corrija antes de subir o serviço.${NC}"
    exit 1
fi
echo -e "${GREEN}Ambiente pronto.${NC} Próximos passos:"
echo "  docker compose up -d --build"
echo "  ./scripts/init-pki.sh"
echo "  ./scripts/issue-cert.sh cliente01"
echo ""

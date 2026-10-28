# OCSP Server de teste

Responder OCSP (RFC 6960 / RFC 5019) em HTTP na porta 80. Junto vem uma PKI de
teste (Root CA → ICA → certificados de cliente) e scripts para revogar e
desrevogar certificados. Serve para testar plataformas que consultam OCSP, como a
Akamai validando certificados de cliente em mTLS.

O endpoint é definido uma única vez por duas variáveis: `OCSP_HOSTNAME` (padrão
`ocsp.rdigaum.com.br`) e `OCSP_PATH` (padrão `/ocsp/validation`). O servidor usa
esses valores como o `Host` e o path esperados. Na emissão, o `pkictl` monta a URI
completa `http://<OCSP_HOSTNAME><OCSP_PATH>` e a grava no AIA de cada certificado
de cliente. É assim que o `openssl x509 -text` exibe as extensões:

```
Authority Information Access:
    OCSP - URI:http://ocsp.rdigaum.com.br/ocsp/validation
X509v3 Extended Key Usage:
    TLS Web Client Authentication
```

`URI:` é só o rótulo do tipo do campo (um *uniformResourceIdentifier*). O valor
gravado é a URI completa, com esquema e path. O cliente OCSP envia o POST para
essa URI e o GET para `<URI>/<base64>`. Para usar a raiz, defina `OCSP_PATH=/`.
A URI passa a ser `http://ocsp.rdigaum.com.br`, e as consultas vão para `/`.

## Estrutura

```
├── Dockerfile / docker-compose.yml
├── app/ocsp_server.py      # responder OCSP (Python + cryptography)
├── pki-tools/
│   ├── pkictl              # CLI da PKI (roda dentro do container)
│   └── openssl.cnf
├── docker/entrypoint.sh
├── scripts/                # wrappers para usar no host
├── iac/                    # instalação no Ubuntu (ver "Instalação no Ubuntu")
└── pki/                    # gerado: chaves, certificados, base de revogação (fora do git)
```

## Instalação no Ubuntu

O diretório `iac/` prepara um Ubuntu 22.04 ou 24.04 (ou derivado) do zero. Ao
final, falta apenas editar o `.env` e subir o serviço com `docker compose`.

```bash
git clone git@github.com:rdigaum/ocsp_server.git
cd ocsp_server
bash iac/install.sh            # como usuário comum com sudo; --no-firewall para pular o UFW

nano .env                      # OCSP_HOSTNAME, OCSP_PATH, ...
bash iac/check-env.sh          # valida .env, porta, DNS e acesso ao Docker
docker compose up -d --build
./scripts/init-pki.sh
./scripts/issue-cert.sh cliente01
```

O `install.sh` executa, em ordem, os scripts abaixo. Todos são idempotentes e
também podem ser executados isoladamente:

| Script | O que faz |
|---|---|
| `iac/install-packages.sh` | Instala `ca-certificates`, `curl`, `gnupg`, `git`, `openssl`, `iproute2` e `dnsutils` |
| `iac/install-docker.sh` | Instala o Docker Engine e o plugin Compose pelo repositório oficial (`download.docker.com`), habilita o serviço e adiciona o usuário ao grupo `docker` |
| `iac/configure-firewall.sh` | Libera `HTTP_PORT`/tcp no UFW, se ele estiver ativo |
| `iac/prepare-project.sh` | Cria o `.env` a partir do `.env.example` (sem sobrescrever um existente), cria `./pki` com dono do usuário e modo 700, ajusta as permissões e valida o compose |
| `iac/check-env.sh` | Verificação para rodar depois de editar o `.env`: Docker, `OCSP_HOSTNAME`, `OCSP_PATH`, porta, a URI resultante do AIA, se a porta está livre e se o DNS aponta para o host. Termina com código 1 se algo impedir o funcionamento |

Observações:
- **Grupo `docker`:** o usuário entra no grupo durante a instalação, mas isso só
  vale depois de um novo login. Até lá, use `newgrp docker` ou `sudo`.
- **Porta 80 ocupada:** se houver um `apache2` ou `nginx` rodando, o `check-env.sh`
  mostra o processo que ocupa a porta.
- **Firewall do provedor:** em cloud, libere também a porta 80/tcp no security
  group ou firewall do provedor. O `configure-firewall.sh` só configura o UFW.
- **Dono dos arquivos:** os scripts rodam o `pkictl` com o UID e o GID do usuário,
  e por isso os arquivos em `./pki` pertencem a ele, não ao root.

## Do início ao fim

### 1. Pré-requisitos

- Um host com Docker e Docker Compose v2 (`docker compose version`). No Ubuntu,
  o `iac/install.sh` instala os dois; veja [Instalação no Ubuntu](#instalação-no-ubuntu).
- A porta 80/TCP livre nesse host e acessível pela internet, já que a Akamai
  consulta a partir da edge.
- Um registro DNS (A ou CNAME) de `OCSP_HOSTNAME` apontando para esse host.
  Para testes só locais, ele não é necessário.

### 2. Obter o projeto e configurar

```bash
git clone git@github.com:rdigaum/ocsp_server.git
cd ocsp_server
cp .env.example .env
```

Revise o `.env` **antes de emitir certificados**. O principal são `OCSP_HOSTNAME` e
`OCSP_PATH`, porque formam a URI gravada no AIA de cada certificado e não mudam
depois da emissão.
As demais variáveis estão em [Configuração](#configuração-env).

### 3. Construir a imagem e subir o serviço

```bash
docker compose up -d --build
docker compose logs ocsp        # "aguardando PKI em /pki — rode scripts/init-pki.sh"
```

Sem a PKI, o container fica esperando, sem entrar em loop de restart.

### 4. Criar a PKI (uma única vez)

```bash
./scripts/init-pki.sh
docker compose logs ocsp        # "OCSP responder http://ocsp.rdigaum.com.br/ocsp/validation em 0.0.0.0:80 ..."
docker compose ps               # STATUS: Up ... (healthy), após alguns segundos
```

Esse passo cria em `./pki` a Root CA, a ICA e o certificado que assina as
respostas OCSP. O responder detecta os arquivos e começa a atender sozinho.

### 5. Emitir certificados de cliente

```bash
./scripts/issue-cert.sh cliente01 --email cliente01@rdigaum.com.br
./scripts/issue-cert.sh cliente02 --ec --dns cliente02.rdigaum.com.br

# conferir as extensões gravadas
openssl x509 -in pki/clients/cliente01/cliente01.crt -noout -ext authorityInfoAccess,extendedKeyUsage
```

### 6. Validar o responder

Pela rede interna do Docker:

```bash
./scripts/check-cert.sh cliente01          # POST  -> good
./scripts/check-cert.sh cliente01 --get    # GET   -> good
```

De fora, como um cliente real (exige o OpenSSL instalado no host):

```bash
# com o DNS já apontando:
openssl ocsp -issuer pki/ica/ica.crt -cert pki/clients/cliente01/cliente01.crt \
  -url http://ocsp.rdigaum.com.br/ocsp/validation -CAfile pki/root/root.crt -verify_other pki/ica/ica.crt

# sem DNS, no próprio host:
openssl ocsp -issuer pki/ica/ica.crt -cert pki/clients/cliente01/cliente01.crt \
  -url http://127.0.0.1/ocsp/validation -header Host=ocsp.rdigaum.com.br \
  -CAfile pki/root/root.crt -verify_other pki/ica/ica.crt
```

A saída esperada é `Response verify OK` seguida de `...cliente01.crt: good`.

### 7. Configurar a plataforma (Akamai)

Siga os passos em [Usando com a Akamai](#usando-com-a-akamai): cadastre a Root
CA, habilite o OCSP e use o certificado do cliente na conexão mTLS.

### 8. Testar revogação

```bash
./scripts/revoke-cert.sh cliente01 keyCompromise
./scripts/check-cert.sh cliente01          # -> revoked (keyCompromise)
./scripts/unrevoke-cert.sh cliente01
./scripts/check-cert.sh cliente01          # -> good
./scripts/list-certs.sh                    # status de todos os certificados
```

Revogar e desrevogar valem na hora: o responder relê a base quando o arquivo muda
e não precisa reiniciar. Quem guarda a resposta em cache (Akamai, navegadores) só
vê a mudança depois do `nextUpdate`; veja `OCSP_VALIDITY_SECONDS`.

### 9. Operação do dia a dia

| Ação | Comando |
|---|---|
| Acompanhar as consultas | `docker compose logs -f ocsp` |
| Parar e iniciar (o estado em `./pki` é mantido) | `docker compose stop` / `docker compose start` |
| Atualizar o código | `git pull && docker compose up -d --build` |
| Backup | copiar o diretório `./pki` inteiro, que contém chaves privadas |
| Recriar toda a PKI (invalida **todos** os certificados) | `./scripts/init-pki.sh --force` |
| Remover tudo | `docker compose down --rmi all && rm -rf pki` |

## Scripts

| Script | Função |
|---|---|
| `init-pki.sh [--force]` | Cria Root CA (RSA 4096), ICA (RSA 4096, pathlen 0) e o OCSP signer delegado. `--force` apaga e recria **tudo**, clientes incluídos |
| `issue-cert.sh <nome> [opções]` | Emite um certificado de cliente. Opções: `--cn`, `--email` (repetível), `--dns` (repetível), `--days`, `--ec` (P-256 no lugar de RSA 2048), `--p12-pass` (padrão `changeit`) |
| `revoke-cert.sh <alvo> [motivo]` | Revoga. Motivos: `unspecified` (padrão), `keyCompromise`, `CACompromise`, `affiliationChanged`, `superseded`, `cessationOfOperation`, `certificateHold` |
| `unrevoke-cert.sh <alvo>` | Remove a revogação, e o certificado volta a responder `good`. Funciona com qualquer motivo, não só `certificateHold` |
| `list-certs.sh` | Lista os certificados da ICA com status, serial, validade e revogação |
| `check-cert.sh <alvo> [--get] [--url URL]` | Consulta o responder por POST (padrão) ou GET e valida a assinatura da resposta. `--url` recebe a URL completa, com path. O padrão é `http://ocsp:80<OCSP_PATH>`, na rede do compose |
| `pki.sh <comando>` | Acesso direto ao `pkictl` (`help`, `show <alvo>`, ...) |

`<alvo>` pode ser o nome do cliente, o serial em hex ou o caminho de um `.crt`.

Os scripts rodam o `pkictl` num container efêmero (`docker compose run --rm`) com
o mesmo volume `./pki`. Funcionam com o serviço parado ou rodando.

## Arquivos gerados (`./pki`)

| Caminho | Conteúdo |
|---|---|
| `root/root.crt` | Root CA (trust anchor) |
| `ica/ica.crt`, `ica/chain.crt` | ICA, e a cadeia ICA + Root |
| `ica/index.txt` | Base de status no formato `openssl ca` (`V` = good, `R` = revoked). É a fonte de verdade do responder |
| `ica/newcerts/<SERIAL>.pem` | Todos os certificados emitidos pela ICA |
| `ocsp/ocsp.crt`, `ocsp/ocsp.key` | Signer delegado (EKU `OCSPSigning` + `ocsp-nocheck`) |
| `clients/<nome>/` | `<nome>.crt`, `.key`, `-chain.crt` (cliente + ICA), `.p12` |

## Comportamento do responder

- `POST <OCSP_PATH>` com `application/ocsp-request`, e `GET <OCSP_PATH>/<base64>`
  (RFC 6960, Apêndice A.1). O base64 é aceito com ou sem URL-encode. Barra final no
  path é tolerada. Outros paths recebem 404 e ficam registrados no log.
- Aceita CertID com SHA-1, SHA-256, SHA-384 e SHA-512.
- Status: `good` para certificados válidos, `revoked` com data e motivo, e `unknown`
  para seriais que não constam na base. Certificados de outro emissor recebem `unauthorized`.
- A resposta é assinada pelo signer delegado, que vai junto na resposta. O nonce é
  ecoado quando vem na requisição.
- Envia `Cache-Control: max-age`, `Expires`, `Last-Modified` e `ETag` de acordo com
  o `nextUpdate` (RFC 5019 §6).
- `Host` esperado = `OCSP_HOSTNAME`. Com `OCSP_STRICT_HOST=false` (padrão) o servidor
  responde mesmo assim e marca `host_mismatch` no log. Com `true`, responde `unauthorized`.
- Os logs mostram IP, `X-Forwarded-For`/`True-Client-IP`, `Host`, serial e status:
  `docker compose logs -f ocsp`.
- Healthcheck em `GET /health`. `GET /` e `GET <OCSP_PATH>` retornam uma mensagem
  informativa.

Só os certificados de cliente (emitidos pela ICA) são verificáveis. A ICA não tem
AIA OCSP, porque a Root fica offline nesse modelo.

## Configuração (`.env`)

| Variável | Padrão | Descrição |
|---|---|---|
| `OCSP_HOSTNAME` | `ocsp.rdigaum.com.br` | Hostname do responder. O servidor o usa como `Host` esperado, e a emissão grava `http://<hostname>` no AIA. Mudar o valor afeta só certificados emitidos depois; os antigos continuam apontando para o hostname anterior |
| `OCSP_PATH` | `/ocsp/validation` | Path do endpoint OCSP. O servidor atende POST em `<path>` e GET em `<path>/<base64>`, e a emissão grava `http://<hostname><path>` no AIA. `/` usa a raiz. Aceita letras, números e `. _ ~ -` em cada segmento. Assim como o hostname, vale só para certificados emitidos depois da mudança |
| `OCSP_STRICT_HOST` | `false` | `true` rejeita (`unauthorized`) requisições OCSP com `Host` diferente de `OCSP_HOSTNAME` |
| `HTTP_PORT` | `80` | Porta publicada no host |
| `OCSP_VALIDITY_SECONDS` | `300` | Intervalo entre `thisUpdate` e `nextUpdate`, também usado como `max-age`. `0` omite o `nextUpdate` |
| `PKI_ORG`, `PKI_COUNTRY`, `ROOT_CN`, `ICA_CN`, `OCSP_SIGNER_CN` | `RDigaum Test ...` | Subjects da PKI |
| `ROOT_DAYS`, `ICA_DAYS`, `OCSP_SIGNER_DAYS`, `CLIENT_DAYS` | 7300 / 3650 / 730 / 365 | Validades em dias |

## Usando com a Akamai

1. O DNS de `OCSP_HOSTNAME` (padrão `ocsp.rdigaum.com.br`) precisa apontar para o host do container, com a porta
   80/TCP liberada para a internet. A Akamai consulta a partir da edge.
2. Envie `pki/root/root.crt` (e, se a plataforma pedir, `pki/ica/ica.crt`) como CA
   confiável na configuração de mTLS do cliente, e habilite a checagem OCSP.
3. No cliente, use `pki/clients/<nome>/<nome>.p12`, ou o `.crt` e a `.key` com a cadeia:
   ```bash
   curl --cert pki/clients/cliente01/cliente01-chain.crt \
        --key pki/clients/cliente01/cliente01.key https://<hostname-na-akamai>/
   ```
4. Acompanhe as consultas da Akamai com `docker compose logs -f ocsp`. Para ver a
   revogação refletida mais rápido, reduza `OCSP_VALIDITY_SECONDS`: a edge pode cachear
   a resposta até o `nextUpdate`.

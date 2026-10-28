# OCSP Server de teste

Responder OCSP (RFC 6960 / RFC 5019) em HTTP na porta 80. Junto vem uma PKI de
teste (Root CA → ICA → certificados de cliente) e scripts para revogar e
desrevogar certificados. Serve para testar plataformas que consultam OCSP, como a
Akamai validando certificados de cliente em mTLS.

O hostname do responder é definido uma única vez em `OCSP_HOSTNAME` (padrão
`ocsp.rdigaum.com.br`). O servidor usa esse valor como o `Host` esperado, e a emissão
o grava no AIA dos certificados de cliente:

```
Authority Information Access:
    OCSP - URI:http://ocsp.rdigaum.com.br
X509v3 Extended Key Usage: TLS Web Client Authentication
```

## Estrutura

```
├── Dockerfile / docker-compose.yml
├── app/ocsp_server.py      # responder OCSP (Python + cryptography)
├── pki-tools/
│   ├── pkictl              # CLI da PKI (roda dentro do container)
│   └── openssl.cnf
├── docker/entrypoint.sh
├── scripts/                # wrappers para usar no host
└── pki/                    # gerado: chaves, certificados, base de revogação (fora do git)
```

## Uso rápido

```bash
cp .env.example .env              # opcional; todos os valores têm padrão
docker compose up -d --build      # sobe o responder e espera a PKI existir
./scripts/init-pki.sh             # cria Root CA, ICA e certificado do OCSP signer
./scripts/issue-cert.sh cliente01 --email cliente01@rdigaum.com.br
./scripts/check-cert.sh cliente01               # -> good
./scripts/revoke-cert.sh cliente01 keyCompromise
./scripts/check-cert.sh cliente01 --get         # -> revoked
./scripts/unrevoke-cert.sh cliente01
./scripts/check-cert.sh cliente01               # -> good
./scripts/list-certs.sh
```

Revogar e desrevogar têm efeito imediato: o responder recarrega a base quando o
arquivo muda (pelo mtime) e não precisa reiniciar. Quem cacheia a resposta (Akamai,
navegadores) só vê a mudança depois do `nextUpdate`; veja `OCSP_VALIDITY_SECONDS`.

## Scripts

| Script | Função |
|---|---|
| `init-pki.sh [--force]` | Cria Root CA (RSA 4096), ICA (RSA 4096, pathlen 0) e o OCSP signer delegado. `--force` apaga e recria **tudo**, clientes incluídos |
| `issue-cert.sh <nome> [opções]` | Emite um certificado de cliente. Opções: `--cn`, `--email` (repetível), `--dns` (repetível), `--days`, `--ec` (P-256 no lugar de RSA 2048), `--p12-pass` (padrão `changeit`) |
| `revoke-cert.sh <alvo> [motivo]` | Revoga. Motivos: `unspecified` (padrão), `keyCompromise`, `CACompromise`, `affiliationChanged`, `superseded`, `cessationOfOperation`, `certificateHold` |
| `unrevoke-cert.sh <alvo>` | Remove a revogação, e o certificado volta a responder `good`. Funciona com qualquer motivo, não só `certificateHold` |
| `list-certs.sh` | Lista os certificados da ICA com status, serial, validade e revogação |
| `check-cert.sh <alvo> [--get] [--url URL]` | Consulta o responder por POST (padrão) ou GET e valida a assinatura da resposta |
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

- `POST /` com `application/ocsp-request`, e `GET /<base64>` (RFC 6960, Apêndice A.1).
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
- Healthcheck em `GET /health`.

Só os certificados de cliente (emitidos pela ICA) são verificáveis. A ICA não tem
AIA OCSP, porque a Root fica offline nesse modelo.

## Configuração (`.env`)

| Variável | Padrão | Descrição |
|---|---|---|
| `OCSP_HOSTNAME` | `ocsp.rdigaum.com.br` | Hostname do responder. O servidor o usa como `Host` esperado, e a emissão grava `http://<hostname>` no AIA. Mudar o valor afeta só certificados emitidos depois; os antigos continuam apontando para o hostname anterior |
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

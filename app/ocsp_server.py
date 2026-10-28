"""OCSP responder HTTP (RFC 6960 / RFC 5019) para ambiente de teste.

Lê a base de certificados da ICA no formato padrão do `openssl ca` (index.txt)
e responde good / revoked / unknown. A base e os certificados são recarregados
automaticamente quando os arquivos mudam no disco — revogar / desrevogar via
`pkictl` reflete na próxima consulta, sem reiniciar o serviço.

Aceita:
  POST /                 body DER, Content-Type: application/ocsp-request
  GET  /<base64(DER)>    RFC 6960 Apêndice A.1 (URL-encoded)
  GET  /health           healthcheck
"""

import base64
import datetime as dt
import hashlib
import logging
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.x509 import ocsp

PKI_DIR = os.environ.get("PKI_DIR", "/pki")
ICA_CERT = os.path.join(PKI_DIR, "ica", "ica.crt")
ICA_INDEX = os.path.join(PKI_DIR, "ica", "index.txt")
SIGNER_CERT = os.path.join(PKI_DIR, "ocsp", "ocsp.crt")
SIGNER_KEY = os.path.join(PKI_DIR, "ocsp", "ocsp.key")

# Hostname do responder — o mesmo gravado no AIA dos certificados pelo pkictl.
# Requisições com Host diferente são marcadas no log (host_mismatch) e, com
# OCSP_STRICT_HOST=true, recebem "unauthorized".
OCSP_HOSTNAME = os.environ.get("OCSP_HOSTNAME", "ocsp.rdigaum.com.br").strip().lower()
STRICT_HOST = os.environ.get("OCSP_STRICT_HOST", "false").strip().lower() in ("1", "true", "yes")
LISTEN_ADDR = os.environ.get("LISTEN_ADDR", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "80"))
# Janela thisUpdate → nextUpdate. Também define o Cache-Control enviado ao cliente
# (Akamai/CDNs podem cachear a resposta até nextUpdate). 0 = omite nextUpdate.
VALIDITY_SECONDS = int(os.environ.get("OCSP_VALIDITY_SECONDS", "300"))
MAX_REQUEST_BYTES = 64 * 1024

log = logging.getLogger("ocsp")

REASONS = {
    "unspecified": x509.ReasonFlags.unspecified,
    "keycompromise": x509.ReasonFlags.key_compromise,
    "cacompromise": x509.ReasonFlags.ca_compromise,
    "affiliationchanged": x509.ReasonFlags.affiliation_changed,
    "superseded": x509.ReasonFlags.superseded,
    "cessationofoperation": x509.ReasonFlags.cessation_of_operation,
    "certificatehold": x509.ReasonFlags.certificate_hold,
    "removefromcrl": x509.ReasonFlags.remove_from_crl,
}

HASH_ALGS = (hashes.SHA1(), hashes.SHA256(), hashes.SHA384(), hashes.SHA512())


def _parse_openssl_time(value):
    """index.txt usa UTCTime (YYMMDDHHMMSSZ) ou GeneralizedTime (YYYYMMDDHHMMSSZ)."""
    fmt = "%y%m%d%H%M%SZ" if len(value) == 13 else "%Y%m%d%H%M%SZ"
    return dt.datetime.strptime(value, fmt).replace(tzinfo=dt.timezone.utc)


class Entry:
    __slots__ = ("status", "revoked_at", "reason", "subject")

    def __init__(self, status, revoked_at, reason, subject):
        self.status = status
        self.revoked_at = revoked_at
        self.reason = reason
        self.subject = subject


def load_index(path):
    entries = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            fields = line.rstrip("\n").split("\t")
            if len(fields) < 6:
                continue
            status, _expiry, revocation, serial_hex, _fname, subject = fields[:6]
            revoked_at, reason = None, None
            if status == "R" and revocation:
                when, _, why = revocation.partition(",")
                revoked_at = _parse_openssl_time(when)
                reason = REASONS.get(why.lower()) if why else None
            entries[int(serial_hex, 16)] = Entry(status, revoked_at, reason, subject)
    return entries


class State:
    """Material criptográfico + base de revogação, recarregados por mtime."""

    _files = (ICA_CERT, ICA_INDEX, SIGNER_CERT, SIGNER_KEY)

    def __init__(self):
        self._lock = threading.Lock()
        self._stamp = None
        self.ica = self.signer = self.signer_key = None
        self.entries = {}
        self.issuer_hashes = set()

    def _current_stamp(self):
        return tuple(os.stat(p).st_mtime_ns for p in self._files)

    def refresh(self):
        stamp = self._current_stamp()
        if stamp == self._stamp:
            return
        with self._lock:
            if stamp == self._stamp:
                return
            with open(ICA_CERT, "rb") as fh:
                ica = x509.load_pem_x509_certificate(fh.read())
            with open(SIGNER_CERT, "rb") as fh:
                signer = x509.load_pem_x509_certificate(fh.read())
            with open(SIGNER_KEY, "rb") as fh:
                signer_key = serialization.load_pem_private_key(fh.read(), password=None)
            entries = load_index(ICA_INDEX)

            # Hashes (issuerNameHash, issuerKeyHash) da ICA para cada algoritmo que
            # um cliente pode usar no CertID. O issuerKeyHash vem do builder (calculado
            # sobre a chave do "issuer"); o issuerNameHash é o hash do DER do subject
            # da ICA — o builder o calcularia sobre o campo issuer do "cert".
            name_der = ica.subject.public_bytes()
            issuer_hashes = set()
            for alg in HASH_ALGS:
                req = ocsp.OCSPRequestBuilder().add_certificate(ica, ica, alg).build()
                digest = hashes.Hash(alg)
                digest.update(name_der)
                issuer_hashes.add((alg.name, digest.finalize(), req.issuer_key_hash))

            self.ica, self.signer, self.signer_key = ica, signer, signer_key
            self.entries, self.issuer_hashes = entries, issuer_hashes
            self._stamp = stamp
            revoked = sum(1 for e in entries.values() if e.status == "R")
            log.info("base carregada: %d certificados (%d revogados)", len(entries), revoked)


STATE = State()


def build_response(der_request):
    """Retorna (der_response, next_update, descrição para log)."""
    try:
        req = ocsp.load_der_ocsp_request(der_request)
    except ValueError as exc:
        return _unsuccessful(ocsp.OCSPResponseStatus.MALFORMED_REQUEST), None, f"malformed ({exc})"

    try:
        STATE.refresh()
    except (OSError, ValueError) as exc:
        log.error("falha ao carregar PKI: %s", exc)
        return _unsuccessful(ocsp.OCSPResponseStatus.INTERNAL_ERROR), None, "internal_error"

    key = (req.hash_algorithm.name, req.issuer_name_hash, req.issuer_key_hash)
    serial = req.serial_number
    if key not in STATE.issuer_hashes:
        return _unsuccessful(ocsp.OCSPResponseStatus.UNAUTHORIZED), None, f"serial={serial:X} issuer desconhecido"

    entry = STATE.entries.get(serial)
    revoked_at = reason = None
    if entry is None:
        status, label = ocsp.OCSPCertStatus.UNKNOWN, "unknown"
    elif entry.status == "R":
        status, label = ocsp.OCSPCertStatus.REVOKED, "revoked"
        revoked_at, reason = entry.revoked_at, entry.reason
    else:
        status, label = ocsp.OCSPCertStatus.GOOD, "good"

    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    next_update = now + dt.timedelta(seconds=VALIDITY_SECONDS) if VALIDITY_SECONDS > 0 else None

    builder = (
        ocsp.OCSPResponseBuilder()
        .add_response_by_hash(
            issuer_name_hash=req.issuer_name_hash,
            issuer_key_hash=req.issuer_key_hash,
            serial_number=serial,
            algorithm=req.hash_algorithm,
            cert_status=status,
            this_update=now,
            next_update=next_update,
            revocation_time=revoked_at,
            revocation_reason=reason,
        )
        .responder_id(ocsp.OCSPResponderEncoding.HASH, STATE.signer)
        .certificates([STATE.signer])
    )
    try:
        nonce = req.extensions.get_extension_for_class(x509.OCSPNonce)
        builder = builder.add_extension(nonce.value, critical=False)
    except x509.ExtensionNotFound:
        pass

    resp = builder.sign(STATE.signer_key, hashes.SHA256())
    subject = f" {entry.subject}" if entry else ""
    return resp.public_bytes(serialization.Encoding.DER), next_update, f"serial={serial:X} {label}{subject}"


def _unsuccessful(status):
    return ocsp.OCSPResponseBuilder.build_unsuccessful(status).public_bytes(serialization.Encoding.DER)


def _decode_get_path(path):
    raw = unquote(path.lstrip("/"))
    raw = raw.replace("-", "+").replace("_", "/")  # tolera base64url
    raw += "=" * (-len(raw) % 4)
    return base64.b64decode(raw, validate=True)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "ocsp-test-responder"
    sys_version = ""

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/health", "/healthz"):
            return self._send(200, b"ok\n", "text/plain")
        if path == "/":
            msg = f"OCSP responder http://{OCSP_HOSTNAME} - envie POST application/ocsp-request\n"
            return self._send(200, msg.encode(), "text/plain")
        try:
            der = _decode_get_path(path)
        except ValueError:
            return self._ocsp_reply(_unsuccessful(ocsp.OCSPResponseStatus.MALFORMED_REQUEST), None, "GET base64 inválido")
        self._handle(der)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_REQUEST_BYTES:
            return self._ocsp_reply(_unsuccessful(ocsp.OCSPResponseStatus.MALFORMED_REQUEST), None, f"POST tamanho inválido ({length})")
        self._handle(self.rfile.read(length))

    def _handle(self, der):
        host_ok = self._request_host() == OCSP_HOSTNAME
        if not host_ok and STRICT_HOST:
            return self._ocsp_reply(_unsuccessful(ocsp.OCSPResponseStatus.UNAUTHORIZED), None,
                                    f"host_mismatch (esperado {OCSP_HOSTNAME}) rejeitado")
        try:
            body, next_update, desc = build_response(der)
        except Exception:  # noqa: BLE001 - nunca derrubar a conexão sem resposta OCSP
            log.exception("erro inesperado")
            body, next_update, desc = _unsuccessful(ocsp.OCSPResponseStatus.INTERNAL_ERROR), None, "internal_error"
        if not host_ok:
            desc += " host_mismatch"
        self._ocsp_reply(body, next_update, desc)

    def _request_host(self):
        host = (self.headers.get("Host") or "").strip().lower()
        return host.rsplit(":", 1)[0] if ":" in host and not host.endswith("]") else host

    def _ocsp_reply(self, body, next_update, desc):
        headers = {"Content-Type": "application/ocsp-response"}
        if next_update is not None:
            # RFC 5019 §6: cabeçalhos de cache coerentes com thisUpdate/nextUpdate.
            now = dt.datetime.now(dt.timezone.utc)
            max_age = max(int((next_update - now).total_seconds()), 0)
            headers["Cache-Control"] = f"max-age={max_age}, public, no-transform, must-revalidate"
            headers["Last-Modified"] = now.strftime("%a, %d %b %Y %H:%M:%S GMT")
            headers["Expires"] = next_update.strftime("%a, %d %b %Y %H:%M:%S GMT")
            headers["ETag"] = '"%s"' % hashlib.sha1(body).hexdigest()
        else:
            headers["Cache-Control"] = "no-cache"
        log.info("%s %s %s", self.command, self._client(), desc)
        self._send(200, body, None, headers)

    def _send(self, code, body, ctype, headers=None):
        self.send_response(code)
        if ctype:
            self.send_header("Content-Type", ctype)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _client(self):
        fwd = self.headers.get("X-Forwarded-For") or self.headers.get("True-Client-IP")
        host = self.headers.get("Host", "-")
        return f"{self.client_address[0]}{' xff=' + fwd if fwd else ''} host={host}"

    def log_message(self, fmt, *args):  # silencia o log padrão do http.server
        pass


def main():
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"),
                        format="%(asctime)s %(levelname)s %(message)s")
    STATE.refresh()
    server = ThreadingHTTPServer((LISTEN_ADDR, LISTEN_PORT), Handler)
    server.daemon_threads = True
    log.info("OCSP responder http://%s em %s:%d (validade %ss, strict_host=%s)",
             OCSP_HOSTNAME, LISTEN_ADDR, LISTEN_PORT, VALIDITY_SECONDS, STRICT_HOST)
    server.serve_forever()


if __name__ == "__main__":
    main()

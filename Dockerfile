FROM python:3.12-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends openssl curl \
 && rm -rf /var/lib/apt/lists/*

COPY requirements.txt /opt/ocsp/requirements.txt
RUN pip install --no-cache-dir -r /opt/ocsp/requirements.txt

COPY app/ocsp_server.py /opt/ocsp/ocsp_server.py
COPY pki-tools/openssl.cnf /opt/ocsp/openssl.cnf
COPY pki-tools/pkictl /usr/local/bin/pkictl
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/pkictl /usr/local/bin/entrypoint.sh

ENV PKI_DIR=/pki \
    PYTHONUNBUFFERED=1
VOLUME ["/pki"]
EXPOSE 80

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
  CMD curl -fsS http://127.0.0.1/health || exit 1

ENTRYPOINT ["entrypoint.sh"]
CMD ["serve"]

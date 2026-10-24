#!/usr/bin/env bash
# =============================================================================
# Sinh chứng chỉ TLS tự ký cho Nginx reverse proxy.
#
#   bash scripts/gen-certs.sh              # CN=localhost + SAN localhost/127.0.0.1
#   bash scripts/gen-certs.sh 192.168.1.50 # thêm SAN cho IP máy ảo
#
# Kết quả: nginx/certs/server.crt (644) và nginx/certs/server.key (600)
# Chạy lại script này là thay chứng chỉ; nhớ `docker compose restart nginx`.
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

CERT_DIR="nginx/certs"
VM_IP="${1:-}"

mkdir -p "$CERT_DIR"

SAN="DNS:localhost,DNS:de3.local,IP:127.0.0.1"
if [[ -n "$VM_IP" ]]; then
  SAN="${SAN},IP:${VM_IP}"
fi

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "${CERT_DIR}/server.key" \
  -out    "${CERT_DIR}/server.crt" \
  -subj   "/C=VN/ST=ThaiNguyen/O=ICTU/OU=Khoa CNTT/CN=localhost" \
  -addext "subjectAltName=${SAN}" \
  -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
  -addext "extendedKeyUsage=serverAuth" \
  2>/dev/null

chmod 600 "${CERT_DIR}/server.key"
chmod 644 "${CERT_DIR}/server.crt"

echo "Đã tạo chứng chỉ:"
echo "  ${CERT_DIR}/server.crt"
echo "  ${CERT_DIR}/server.key  (quyền 600)"
echo
openssl x509 -in "${CERT_DIR}/server.crt" -noout -subject -dates -ext subjectAltName
echo
echo "Kiểm tra:  openssl s_client -connect localhost:8443 -CAfile ${CERT_DIR}/server.crt </dev/null"

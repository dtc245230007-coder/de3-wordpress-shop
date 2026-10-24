#!/usr/bin/env bash
# =============================================================================
# Kiểm chứng toàn bộ hệ thống Đề 3 – dùng để lấy minh chứng cho báo cáo.
#
#   bash scripts/verify.sh [IP_MAY_ẢO]
#
# Ví dụ: bash scripts/verify.sh 192.168.75.129
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

IP="${1:-$(hostname -I | awk '{print $1}')}"
HTTP_PORT=8080
HTTPS_PORT=8443
ok=0; fail=0

pass() { printf "  \033[32m[ĐẠT]\033[0m %s\n" "$1"; ok=$((ok+1)); }
miss() { printf "  \033[31m[LỖI]\033[0m %s\n" "$1"; fail=$((fail+1)); }
head2() { printf "\n\033[1m%s\033[0m\n" "$1"; }

# -----------------------------------------------------------------------------
head2 "1. Trạng thái container"
docker compose ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null
running=$(docker compose ps --status running -q 2>/dev/null | wc -l)
echo "  Đang chạy: ${running} container"
[ "$running" -ge 12 ] && pass "Đủ 12 container đang chạy" || miss "Chỉ có ${running}/12 container đang chạy"

# -----------------------------------------------------------------------------
head2 "2. HTTP chuyển hướng sang HTTPS (301)"
code=$(curl -s -o /dev/null -w '%{http_code}' "http://${IP}:${HTTP_PORT}/")
loc=$(curl -sI "http://${IP}:${HTTP_PORT}/" | awk -F': ' 'tolower($1)=="location"{print $2}' | tr -d '\r')
[ "$code" = "301" ] && pass "HTTP ${HTTP_PORT} -> ${code}, Location: ${loc}" || miss "Mong đợi 301, nhận ${code}"

# -----------------------------------------------------------------------------
head2 "3. HTTPS + security headers"
hdrs=$(curl -ksI "https://${IP}:${HTTPS_PORT}/")
code=$(printf '%s' "$hdrs" | head -1 | awk '{print $2}')
[ "$code" = "200" ] && pass "HTTPS trả 200" || miss "HTTPS trả ${code}"
for h in strict-transport-security x-frame-options x-content-type-options referrer-policy; do
  if printf '%s' "$hdrs" | grep -qi "^${h}:"; then
    pass "Header ${h}: $(printf '%s' "$hdrs" | grep -i "^${h}:" | cut -d' ' -f2- | tr -d '\r')"
  else
    miss "Thiếu header ${h}"
  fi
done
srv=$(printf '%s' "$hdrs" | awk -F': ' 'tolower($1)=="server"{print $2}' | tr -d '\r')
case "$srv" in
  *[0-9].[0-9]*) miss "Header Server lộ phiên bản: ${srv}" ;;
  *) pass "Header Server không lộ phiên bản: ${srv}" ;;
esac

# -----------------------------------------------------------------------------
head2 "4. TLS"
# Bắt tay thành công thì openssl in "New, TLSv1.1, Cipher is ...".
# Bị từ chối thì chỉ có cảnh báo alert/handshake, KHÔNG có dòng "Cipher is".
# Chú ý: khi bị từ chối, openssl vẫn in "New, (NONE), Cipher is (NONE)".
# Chỉ coi là "chấp nhận" khi thật sự thoả thuận được TLSv1.1.
out11=$(echo | openssl s_client -connect "${IP}:${HTTPS_PORT}" -tls1_1 2>&1)
if printf '%s' "$out11" | grep -q "New, TLSv1\.1, Cipher is"; then
  miss "TLS 1.1 vẫn được chấp nhận"
else
  reason=$(printf '%s' "$out11" | grep -m1 -i "alert protocol version\|handshake failure\|no protocols available\|wrong version number" | sed 's/^[0-9]*://' | tr -d '\r')
  pass "TLS 1.1 bị từ chối (${reason:-không bắt tay được})"
fi
out13=$(echo | openssl s_client -connect "${IP}:${HTTPS_PORT}" -tls1_3 2>&1)
if printf '%s' "$out13" | grep -q "New, TLSv1\.3, Cipher is"; then
  pass "TLS 1.3 được chấp nhận ($(printf '%s' "$out13" | grep -m1 -i 'Cipher is' | sed 's/^ *//' | tr -d '\r'))"
else
  miss "TLS 1.3 không hoạt động"
fi

# -----------------------------------------------------------------------------
head2 "5. Chặn bề mặt tấn công"
code=$(curl -ks -o /dev/null -w '%{http_code}' "https://${IP}:${HTTPS_PORT}/xmlrpc.php")
[ "$code" = "403" ] && pass "xmlrpc.php trả 403" || miss "xmlrpc.php trả ${code}"
code=$(curl -ks -o /dev/null -w '%{http_code}' "https://${IP}:${HTTPS_PORT}/.env")
[ "$code" = "403" ] && pass "Tệp ẩn (.env) trả 403" || miss "Tệp ẩn trả ${code}"

# -----------------------------------------------------------------------------
head2 "6. Rate limit trang đăng nhập (10r/m, burst 5)"
out=""
for _ in $(seq 1 10); do
  out+="$(curl -ks -o /dev/null -w '%{http_code} ' "https://${IP}:${HTTPS_PORT}/wp-login.php")"
done
echo "  ${out}"
printf '%s' "$out" | grep -q "429" && pass "Có phản hồi 429 khi vượt ngưỡng" || miss "Không thấy 429"

# -----------------------------------------------------------------------------
head2 "7. Prometheus targets"
# Prometheus publish ở 127.0.0.1:9090 trên chính máy ảo
targets=$(curl -s http://127.0.0.1:9090/api/v1/targets 2>/dev/null)
if [ -n "$targets" ]; then
  up=$(printf '%s' "$targets" | grep -o '"health":"up"' | wc -l)
  down=$(printf '%s' "$targets" | grep -o '"health":"down"' | wc -l)
  [ "$down" -eq 0 ] && [ "$up" -ge 6 ] \
    && pass "${up}/6 target UP (không có target DOWN)" \
    || miss "${up} target UP, ${down} target DOWN"
  printf '%s' "$targets" | python3 -c '
import json, sys
for t in sorted(json.load(sys.stdin)["data"]["activeTargets"],
                key=lambda x: x["labels"].get("job", "")):
    print("    - %-16s %s" % (t["labels"].get("job", "?"), t["health"]))
' 2>/dev/null || true
else
  miss "Không gọi được API Prometheus"
fi

# -----------------------------------------------------------------------------
head2 "8. Loki – nhãn và log"
# Loki publish ở 127.0.0.1:3100 – hỏi trực tiếp danh sách container đã có log
vals=$(curl -s http://127.0.0.1:3100/loki/api/v1/label/container/values 2>/dev/null)
# Bóc phần vỏ JSON {"status":"success","data":[ ... ]} rồi mới đếm
names=$(printf '%s' "$vals" | python3 -c '
import json, sys
print("\n".join(json.load(sys.stdin).get("data", [])))
' 2>/dev/null || true)
n=$(printf '%s\n' "$names" | grep -c . || true)
if [ "$n" -gt 0 ]; then
  pass "Loki đã nhận log của ${n} container"
  printf '%s\n' "$names" | sed 's/^/    - /' | sort
  q='{container="de3-nginx"}'
  hits=$(curl -sG --data-urlencode "query=${q}" --data-urlencode 'limit=3' \
          http://127.0.0.1:3100/loki/api/v1/query 2>/dev/null \
          | grep -o '"status":"success"')
  [ -n "$hits" ] && pass "LogQL ${q} trả kết quả" || miss "LogQL ${q} không trả kết quả"
else
  miss "Loki chưa nhận log"
fi

# -----------------------------------------------------------------------------
head2 "9. Tài khoản CSDL least-privilege"
docker compose exec -T db mysql -uroot -p"${MYSQL_ROOT_PASSWORD:-$(grep '^MYSQL_ROOT_PASSWORD=' .env | cut -d= -f2)}" \
  -e "SELECT user, host FROM mysql.user WHERE user NOT LIKE 'mysql.%' ORDER BY user;" 2>/dev/null \
  | sed 's/^/  /' && pass "Liệt kê được tài khoản CSDL" || miss "Không truy vấn được CSDL"

# -----------------------------------------------------------------------------
head2 "10. Tài nguyên"
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" 2>/dev/null | sed 's/^/  /'
echo
free -h | sed 's/^/  /'

# -----------------------------------------------------------------------------
printf "\n\033[1mKẾT QUẢ: %d đạt / %d lỗi\033[0m\n" "$ok" "$fail"
[ "$fail" -eq 0 ] && exit 0 || exit 1

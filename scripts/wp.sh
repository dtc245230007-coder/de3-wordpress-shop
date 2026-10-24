#!/usr/bin/env bash
# =============================================================================
# Chạy WP-CLI trên volume của container wordpress.
#
#   bash scripts/wp.sh core version
#   bash scripts/wp.sh plugin list
#   bash scripts/wp.sh post list --post_type=page
#
# Vì sao phải dựng container tạm thay vì `docker compose exec`:
#   - wp-config.php dùng getenv_docker() nên cần cùng bộ biến WORDPRESS_DB_*.
#   - Image wordpress:cli (Alpine) có www-data = uid 82, còn wordpress:apache
#     (Debian) là uid 33 → phải chạy bằng --user 33 mới ghi được vào volume.
#   - Mạng backend đặt internal: true nên container chỉ có backend sẽ không ra
#     được Internet (cần cho theme/plugin/language). Ta nối thêm frontend.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

set -a
# shellcheck disable=SC1091
. ./.env
set +a

CID="de3-wpcli-$$"
cleanup() { docker rm -f "$CID" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

docker run -d --name "$CID" \
  --network de3-wp_backend \
  --user 33:33 \
  --volumes-from de3-wordpress \
  -e WORDPRESS_DB_HOST=db:3306 \
  -e WORDPRESS_DB_NAME="${MYSQL_DATABASE}" \
  -e WORDPRESS_DB_USER="${MYSQL_USER}" \
  -e WORDPRESS_DB_PASSWORD="${MYSQL_PASSWORD}" \
  --entrypoint sleep \
  wordpress:cli 900 >/dev/null

docker network connect de3-wp_frontend "$CID"

# Không dùng -i: nếu gắn stdin, docker exec sẽ đọc hết heredoc của script gọi nó.
docker exec -u 33:33 "$CID" wp "$@"

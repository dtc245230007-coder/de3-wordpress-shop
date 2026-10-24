#!/usr/bin/env bash
# =============================================================================
# Sao lưu cơ sở dữ liệu WordPress bằng mysqldump, giữ 7 bản gần nhất.
#
#   bash scripts/backup.sh
#   # crontab -e
#   # 30 2 * * * cd /opt/de3-wordpress-shop && bash scripts/backup.sh >> backups/backup.log 2>&1
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

set -a; source .env; set +a

BACKUP_DIR="${BACKUP_DIR:-backups}"
RETENTION="${RETENTION:-7}"
STAMP="$(date +%F_%H%M%S)"
FILE="${BACKUP_DIR}/wordpress_${STAMP}.sql.gz"

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

echo "[$(date '+%F %T')] Bắt đầu sao lưu ${MYSQL_DATABASE}..."

docker compose exec -T db \
  mysqldump -u root -p"${MYSQL_ROOT_PASSWORD}" \
  --single-transaction --quick --routines --triggers \
  "${MYSQL_DATABASE}" | gzip -9 > "$FILE"

chmod 600 "$FILE"
SIZE=$(du -h "$FILE" | cut -f1)
echo "[$(date '+%F %T')] Xong: ${FILE} (${SIZE})"

# Chỉ giữ RETENTION bản mới nhất
ls -1t "${BACKUP_DIR}"/wordpress_*.sql.gz 2>/dev/null \
  | tail -n +$((RETENTION + 1)) \
  | xargs -r rm -f

echo "[$(date '+%F %T')] Số bản sao lưu còn lại: $(ls -1 "${BACKUP_DIR}"/wordpress_*.sql.gz | wc -l)"

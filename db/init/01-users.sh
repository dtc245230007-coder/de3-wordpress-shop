#!/bin/bash
# =============================================================================
# Script khởi tạo tài khoản CSDL theo nguyên tắc đặc quyền tối thiểu.
# Chỉ chạy MỘT LẦN khi volume db_data còn trống (MySQL entrypoint tự gọi).
# Nhớ: chmod +x db/init/01-users.sh
# =============================================================================
set -euo pipefail

echo "[init] Tạo tài khoản chỉ đọc ${WP_READONLY_USER} và tài khoản exporter ${MYSQL_EXPORTER_USER}..."

mysql --protocol=socket -uroot -p"${MYSQL_ROOT_PASSWORD}" <<-EOSQL
    -- 1) Tài khoản CHỈ ĐỌC: chỉ SELECT + SHOW VIEW trên đúng database ứng dụng
    CREATE USER IF NOT EXISTS '${WP_READONLY_USER}'@'%' IDENTIFIED BY '${WP_READONLY_PASSWORD}';
    GRANT SELECT, SHOW VIEW ON \`${MYSQL_DATABASE}\`.* TO '${WP_READONLY_USER}'@'%';

    -- 2) Tài khoản cho Prometheus mysqld_exporter: chỉ quyền đọc trạng thái
    CREATE USER IF NOT EXISTS '${MYSQL_EXPORTER_USER}'@'%' IDENTIFIED BY '${MYSQL_EXPORTER_PASSWORD}';
    GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO '${MYSQL_EXPORTER_USER}'@'%';

    FLUSH PRIVILEGES;
EOSQL

echo "[init] Xong."

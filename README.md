# Đề 3 – Website Quảng bá Sản phẩm (WordPress)

Đồ án học phần **Triển khai và Quản trị Hệ thống phần mềm**.

Hệ thống gồm 12 container: WordPress, MySQL 8, phpMyAdmin, Nginx reverse proxy,
Prometheus, Grafana, Node Exporter, cAdvisor, MySQL Exporter, Nginx Exporter,
Loki và Promtail — tất cả định nghĩa trong một tệp `docker-compose.yml`.

---

## 1. Bảng đối chiếu yêu cầu

| # | Yêu cầu chung | Thành phần đáp ứng | Minh chứng |
|---|---|---|---|
| 1 | Website quảng bá sản phẩm | `wordpress:6.6-php8.2-apache`, volume `wp_data` | Trang chủ, danh mục, chi tiết sản phẩm tại `https://<ip>:8443` |
| 2 | CSDL MySQL + phpMyAdmin | `mysql:8.0` (không publish cổng 3306), `phpmyadmin:5.2` ở `127.0.0.1:8081` | Đăng nhập phpMyAdmin qua SSH tunnel, thấy các bảng `wp_*` |
| 3 | Quản lý mã nguồn GitHub | Thư mục này là repo, 3 commit mốc (mục 8) | Lịch sử commit trên GitHub |
| 4 | Nginx reverse proxy | `nginx:1.27-alpine`, HTTP→HTTPS 301, TLS 1.2/1.3, security headers | `curl -I`, `openssl s_client` (mục 6) |
| 5 | Prometheus + Grafana | 6 job scrape 15s, 9 quy tắc cảnh báo, datasource tự nạp | Trang `/targets` xanh toàn bộ, dashboard Grafana |
| 6 | Loki + LogQL | Loki 2.9.6 + Promtail đọc Docker socket, lưu 168h | Truy vấn LogQL trong Grafana Explore |
| 7 | Hardening | `read_only`, `cap_drop: ALL`, `no-new-privileges`, `tmpfs`, mạng `backend` internal, tài khoản DB least-privilege, `.env` 600, TLS + headers | Bảng 7 trong báo cáo |

---

## 2. Kiến trúc

```
                      Internet / LAN
                            │
                   ┌────────▼─────────┐
        :8080 ────►│  nginx (reverse  │──── :8443 (TLS 1.2/1.3, self-signed)
                   │  proxy + headers)│
                   └────────┬─────────┘
                            │ frontend network
                   ┌────────▼─────────┐
                   │    wordpress     │  (Apache + PHP 8.2, read_only)
                   └────────┬─────────┘
                            │ backend network (internal: true)
                   ┌────────▼─────────┐        ┌──────────────┐
                   │      mysql       │◄───────│  phpmyadmin  │ 127.0.0.1:8081
                   └────────┬─────────┘        └──────────────┘
                            │
        ┌───────────────────┴──────────────────────────────┐
        │            monitoring network                    │
        │ prometheus ── node-exporter / cadvisor /         │
        │            mysqld-exporter / nginx-exporter      │
        │ grafana (127.0.0.1:3000) ◄── loki ◄── promtail   │
        └──────────────────────────────────────────────────┘
```

| Container | Vai trò | Cổng |
|---|---|---|
| `de3-nginx` | Reverse proxy, TLS, security headers, rate limit | `8080`, `8443` |
| `de3-wordpress` | Ứng dụng WordPress (Apache + PHP 8.2) | nội bộ `80` |
| `de3-db` | MySQL 8.0, volume `db_data` | nội bộ `3306` |
| `de3-phpmyadmin` | Giao diện quản trị CSDL | `127.0.0.1:8081` |
| `de3-prometheus` | Thu thập & lưu số liệu | `127.0.0.1:9090` |
| `de3-grafana` | Dashboard & Explore log | `127.0.0.1:3000` |
| `de3-node-exporter` | CPU/RAM/đĩa/mạng máy chủ | nội bộ `9100` |
| `de3-cadvisor` | Tài nguyên từng container | nội bộ `8080` |
| `de3-mysqld-exporter` | Số liệu MySQL | nội bộ `9104` |
| `de3-nginx-exporter` | Số liệu Nginx (qua `stub_status`) | nội bộ `9113` |
| `de3-loki` | Kho log tập trung | `127.0.0.1:3100` |
| `de3-promtail` | Đọc log Docker, đẩy lên Loki | nội bộ `9080` |

> Chỉ Nginx công bố cổng ra ngoài. Mọi cổng quản trị đều bind `127.0.0.1`,
> truy cập từ máy khác phải qua SSH tunnel — đây là một biện pháp hardening.

> **Vì sao phpMyAdmin nằm trên hai mạng?** Docker không thiết lập được ánh xạ
> cổng cho container chỉ tham gia mạng `internal: true` (bridge không có
> gateway), biểu hiện là `NetworkSettings.Ports` rỗng và cổng 8081 không
> listen. Vì vậy phpMyAdmin vừa ở `backend` (để nói chuyện với MySQL) vừa ở
> mạng `admin` — một bridge thường chỉ có duy nhất nó — để publish được
> `127.0.0.1:8081`. Không container nào khác tham gia mạng `admin`.

---

## 3. Cấu trúc thư mục

```
de3-wordpress-shop/
├── docker-compose.yml
├── .env.example                  # mẫu biến môi trường (không commit .env)
├── nginx/
│   ├── conf.d/default.conf       # reverse proxy + TLS + headers + rate limit
│   ├── snippets/proxy.conf       # header chuyển tiếp dùng chung
│   └── certs/                    # server.crt / server.key (sinh tự động)
├── php/uploads.ini               # giới hạn upload 64M
├── db/init/01-users.sh           # tài khoản DB least-privilege
├── monitoring/
│   ├── prometheus/{prometheus.yml,alerts.yml}
│   ├── loki/loki-config.yml
│   ├── promtail/promtail-config.yml
│   └── grafana/
│       ├── provisioning/{datasources,dashboards}
│       └── dashboards/de3-*.json  # 3 dashboard mẫu + 1 dashboard tự viết
├── scripts/
│   ├── gen-certs.sh              # sinh chứng chỉ tự ký (SAN = IP máy ảo)
│   ├── wp.sh                     # chạy WP-CLI trên volume của container
│   ├── seed-demo.sh              # nạp dữ liệu mẫu (idempotent)
│   └── verify.sh                 # 17 kiểm tra, in minh chứng cho báo cáo
├── docs/
│   ├── screenshots/              # ảnh minh chứng
│   ├── grab.py                   # chụp ảnh trang cần đăng nhập qua DevTools
│   └── verify-output.txt         # kết quả lần kiểm chứng gần nhất
└── README.md
```

---

## 4. Yêu cầu môi trường

- Ubuntu Server 22.04/24.04 (hoặc 20.04), 2 vCPU, ≥ 4 GB RAM, ≥ 20 GB đĩa
- Docker Engine ≥ 24, Docker Compose v2 (`docker compose version`)
- Cổng `8080`, `8443` chưa bị chiếm

---

## 5. Cài đặt

```bash
# 1. Vào thư mục dự án
cd de3-wordpress-shop

# 2. Tạo tệp biến môi trường và đổi toàn bộ mật khẩu
cp .env.example .env
nano .env
chmod 600 .env

# 3. Cấp quyền chạy cho các script
chmod +x db/init/01-users.sh scripts/*.sh

# 4. Sinh chứng chỉ TLS tự ký (truyền IP máy ảo để đưa vào SAN)
bash scripts/gen-certs.sh 192.168.1.50

# 5. Kiểm tra cú pháp compose trước khi chạy
docker compose config -q

# 6. Khởi động toàn bộ hệ thống
docker compose up -d

# 7. Theo dõi trạng thái (chờ tất cả "healthy")
docker compose ps
```

Lần chạy đầu, container `db` sẽ thực thi `db/init/01-users.sh` để tạo:
`wp_readonly` (chỉ `SELECT`) và `exporter` (chỉ đọc trạng thái).

**Cài đặt WordPress:** mở `https://<IP_VM>:8443` → chọn ngôn ngữ → điền tên site,
tài khoản quản trị → cài đặt. Sau đó vào **Sản phẩm → Thêm mới** để tạo nội dung
quảng bá, và **Giao diện** để chọn theme phù hợp.

---

## 6. Truy cập & kiểm chứng

### 6.1 SSH tunnel cho các cổng quản trị

Trên máy cá nhân:

```bash
ssh -p 22 -L 3000:127.0.0.1:3000 \
           -L 9090:127.0.0.1:9090 \
           -L 8081:127.0.0.1:8081 \
           -L 3100:127.0.0.1:3100 \
           user@192.168.1.50
```

Với máy ảo của đồ án: `nguyenduykien@192.168.75.129`.

Sau đó mở trên trình duyệt máy cá nhân:

| Dịch vụ | URL |
|---|---|
| WordPress | `https://192.168.1.50:8443` |
| phpMyAdmin | `http://127.0.0.1:8081` |
| Prometheus | `http://127.0.0.1:9090` |
| Grafana | `http://127.0.0.1:3000` |
| Loki (API) | `http://127.0.0.1:3100` |

### 6.2 Kiểm chứng Nginx / HTTPS / headers

```bash
# Chuyển hướng HTTP -> HTTPS
curl -I http://192.168.1.50:8080
#   HTTP/1.1 301 Moved Permanently
#   Location: https://192.168.1.50:8443/

# HTTPS + security headers
curl -kI https://192.168.1.50:8443/
#   HTTP/2 200
#   strict-transport-security: max-age=31536000; includeSubDomains
#   x-frame-options: SAMEORIGIN
#   x-content-type-options: nosniff
#   referrer-policy: strict-origin-when-cross-origin

# Không lộ phiên bản
curl -kI https://192.168.1.50:8443/ | grep -i server
#   server: nginx

# TLS 1.1 bị từ chối, TLS 1.3 được chấp nhận
openssl s_client -connect 192.168.1.50:8443 -tls1_1 </dev/null
#   ...tlsv1 alert protocol version
openssl s_client -connect 192.168.1.50:8443 -tls1_3 </dev/null | grep Protocol
#   Protocol: TLSv1.3

# xmlrpc bị chặn
curl -k -o /dev/null -w '%{http_code}\n' https://192.168.1.50:8443/xmlrpc.php
#   403

# Rate limit đăng nhập: 8 lần liên tiếp -> 6 lần 200/302, sau đó 429
for i in $(seq 1 8); do
  curl -k -o /dev/null -s -w '%{http_code} ' https://192.168.1.50:8443/wp-login.php
done; echo
```

### 6.3 Prometheus

Mở `http://127.0.0.1:9090/targets` — cả 6 job phải ở trạng thái **UP**:
`prometheus`, `node`, `cadvisor`, `mysql`, `nginx`, `loki`.

PromQL mẫu:

```promql
# CPU máy chủ (%)
100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# RAM đã dùng (%)
(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100

# Request/giây tới Nginx
sum(rate(nginx_http_requests_total[1m]))

# RAM từng container
sum by (name) (rate(container_memory_working_set_bytes{name=~"de3-.*"}[5m]))

# Số kết nối MySQL đang mở
mysql_global_status_threads_connected
```

### 6.4 Grafana

Đăng nhập bằng tài khoản trong `.env`. Datasource Prometheus/Loki đã được nạp
tự động. Dashboard gợi ý (Dashboard → Import → nhập ID):

| ID | Dashboard | Dùng cho |
|---|---|---|
| `1860` | Node Exporter Full | CPU, RAM, đĩa, mạng máy chủ |
| `14282` | Cadvisor | Tài nguyên 12 container |
| `7362` | MySQL Overview | Kết nối, truy vấn, InnoDB |

Sau khi import, **Dashboard → Share → Export → Save to file**, thả tệp JSON vào
`monitoring/grafana/dashboards/` để lần sau Grafana tự nạp (provisioning 30s).

### 6.5 LogQL

Vào **Grafana → Explore → chọn datasource Loki**:

```logql
# Toàn bộ log của dự án
{project="de3-wp"}

# Log Nginx
{container="de3-nginx"}

# Chỉ các dòng lỗi
{container=~"de3-.*"} |= "error"

# Mã 5xx trong access log của Nginx
{container="de3-nginx"} |~ "HTTP/[0-9.]+\\" 5[0-9][0-9] "

# Lỗi PHP / WordPress
{container="de3-wordpress"} |~ "(PHP (Warning|Fatal|Parse)|WordPress database error)"

# Tốc độ log (dòng/giây)
rate({container="de3-nginx"}[1m])

# Đếm request theo mã trạng thái trong 5 phút
sum by (status) (
  count_over_time({container="de3-nginx"} | regexp `" (?P<status>[0-9]{3}) ` [5m])
)
```

### 6.6 Sao lưu và phục hồi

```bash
# Sao lưu (giữ 7 bản gần nhất trong backups/)
bash scripts/backup.sh

# Phục hồi vào database đang chạy
gunzip -c backups/wordpress_2026-10-24_023000.sql.gz \
  | docker compose exec -T db mysql -u root -p"$MYSQL_ROOT_PASSWORD" wordpress

# Lịch tự động: crontab -e
# 30 2 * * * cd /opt/de3-wordpress-shop && bash scripts/backup.sh >> backups/backup.log 2>&1
```

---

## 7. Hardening đã áp dụng

| Biện pháp | Chi tiết |
|---|---|
| Root filesystem chỉ đọc | `read_only: true` cho nginx, wordpress, phpmyadmin, prometheus, grafana, loki, promtail |
| Bỏ toàn bộ capability | `cap_drop: [ALL]`, chỉ thêm lại đúng quyền cần thiết |
| Chống leo thang đặc quyền | `security_opt: ["no-new-privileges:true"]` toàn bộ container |
| Ghi tạm trong RAM | `tmpfs` cho `/tmp`, `/var/run/apache2`, `/var/cache/nginx`... |
| Cô lập mạng | `backend` đặt `internal: true`; MySQL không publish cổng |
| Cổng quản trị | Prometheus/Grafana/phpMyAdmin/Loki chỉ bind `127.0.0.1` |
| CSDL least-privilege | `wp_app` chỉ có quyền trên `wordpress.*`; `wp_readonly` chỉ `SELECT`; `exporter` chỉ `PROCESS, REPLICATION CLIENT, SELECT` |
| Bí mật | Toàn bộ mật khẩu trong `.env` quyền 600, `.gitignore` chặn commit |
| PHP | `expose_php = Off`, `DISALLOW_FILE_EDIT` chặn sửa mã từ wp-admin |
| TLS | Chỉ TLS 1.2/1.3, tắt session tickets, khóa riêng quyền 600 |
| Header | HSTS, X-Frame-Options, nosniff, Referrer-Policy, Permissions-Policy |
| Chống dò mật khẩu | `limit_req` 10r/m (burst 5) riêng cho `wp-login.php`, trả 429; toàn site 30r/s |
| Chặn bề mặt thừa | `xmlrpc.php` trả 403, chặn tệp ẩn (`.git`, `.env`) |

**Ghi chú kỹ thuật cần nêu trong báo cáo:**

- WordPress **bắt buộc** ghi vào `/var/www/html` (media, plugin, cập nhật), nên
  `read_only: true` chỉ áp cho phần còn lại của rootfs; thư mục web đặt trên
  volume `wp_data`, `/tmp` và thư mục runtime của Apache chuyển sang `tmpfs`.
  Đây là khác biệt so với ứng dụng Node.js/Django thuần nơi `read_only` áp được
  cho toàn bộ container.
- `X-Frame-Options` dùng **SAMEORIGIN** chứ không phải `DENY`: WordPress dùng
  iframe cùng origin cho phần tuỳ biến giao diện, `DENY` sẽ làm hỏng chức năng.
- Đổi `8080/8443` thành `80/443` nếu máy ảo không có dịch vụ nào chiếm cổng
  chuẩn; khi đó sửa `return 301 https://$host$request_uri;` trong
  `nginx/conf.d/default.conf`.

---

## 8. Minh chứng triển khai

Toàn bộ ảnh nằm trong `docs/screenshots/`, kết quả kiểm chứng bằng văn bản ở
`docs/verify-output.txt` (17 đạt / 0 lỗi).

| Ảnh | Nội dung |
|---|---|
| `site-home.png` | Trang chủ TechMart qua HTTPS 8443: menu 3 mục, khối "Sản phẩm nổi bật" lấy 6 bài mới nhất bằng block `latest-posts` |
| `site-product.png` | Trang chi tiết `san-pham-1` (TechPhone X1 Pro): giá, mô tả, thông số |
| `prometheus-targets.png` | Prometheus `/targets` — 6/6 job UP (cadvisor, loki, mysql, nginx, node, prometheus) |
| `grafana-website.png` | Dashboard tự viết "Website – Nginx & WordPress": req/s, kết nối đang mở, tổng request 5 phút, log Nginx đọc từ Loki |
| `grafana-node.png` | Dashboard *Node Exporter Full* (ID 1860) |
| `grafana-cadvisor.png` | Dashboard *Cadvisor exporter* (ID 14282) — CPU/RAM/mạng theo từng container |
| `grafana-mysql.png` | Dashboard *MySQL Overview* (ID 7362) |
| `phpmyadmin-tables.png` | phpMyAdmin đăng nhập bằng `wp_readonly`, xem `wordpress.wp_posts` |
| `wp-admin-login.png` | Trang đăng nhập `/wp-login.php` (giao diện tiếng Việt) |
| `wp-admin-dashboard.png` | Bảng điều khiển WordPress: "Xin chào, admin", 6 bài viết, 4 trang, giao diện Astra |
| `wp-admin-products.png` | Danh sách 6 sản phẩm trong mục Bài viết, tác giả `admin` |

Ảnh của Grafana/phpMyAdmin được chụp bằng `docs/grab.py`; ảnh `/wp-admin` chụp
theo cùng cách (đăng nhập HTTP để lấy cookie phiên rồi nạp vào Chrome headless
qua DevTools Protocol) — không cần bật anonymous hay hạ cấu hình bảo mật nào.

---

## 9. Lộ trình 3 commit mốc

```bash
git init
git add .
git commit -m "feat: mốc 1 - WordPress + MySQL + phpMyAdmin + Nginx reverse proxy"

# (mốc 2: thêm Prometheus + Grafana + Node Exporter + cAdvisor)
git add monitoring/prometheus monitoring/grafana docker-compose.yml
git commit -m "feat: mốc 2 - Prometheus + Grafana + Node Exporter + cAdvisor"

# (mốc 3: thêm Loki + Promtail + hardening)
git add monitoring/loki monitoring/promtail nginx docker-compose.yml db scripts
git commit -m "feat: mốc 3 - Loki + Promtail + hardening container"

git tag -a v1.0 -m "Bản nghiệm thu"
git remote add origin https://github.com/<user>/de3-wordpress-shop.git
git push -u origin main --tags
```

> Thứ tự commit này khớp với cấu trúc báo cáo: Phần 2 (ứng dụng + CSDL),
> Phần 4.1–4.2 (Prometheus/Grafana), Phần 4.3 (Loki) và Phần 3 (hardening).

---

## 10. Xử lý sự cố

| Hiện tượng | Nguyên nhân thường gặp | Cách xử lý |
|---|---|---|
| `502 Bad Gateway` | WordPress chưa healthy hoặc sai `WORDPRESS_DB_*` | `docker compose logs wordpress` |
| WordPress báo "Error establishing a database connection" | Sai mật khẩu trong `.env`, hoặc volume `db_data` tạo từ lần chạy trước | `docker compose down -v` rồi `up -d` (mất dữ liệu) |
| `mysqld_exporter` báo `no user specified in section or parent` | Bản 0.15+ bỏ biến `DATA_SOURCE_NAME` | Dùng `--mysqld.address` + `--mysqld.username` + `MYSQLD_EXPORTER_PASSWORD` (đã cấu hình sẵn) |
| Target `mysql` DOWN | Tài khoản `exporter` chưa được tạo (init script không chạy) | `docker compose exec db mysql -uroot -p -e "SELECT user,host FROM mysql.user"` |
| Promtail không có log | Chưa mount `/var/lib/docker/containers` hoặc socket | `docker compose logs promtail` |
| `read_only` làm container không khởi động | Phần mềm cần ghi vào đường dẫn khác | Xem log, bổ sung `tmpfs` tương ứng |
| Nginx 403 với `.well-known` | Quy tắc chặn tệp ẩn | Kiểm tra `location ~ /\.(?!well-known)` |
| Nginx lỗi `open() "/etc/nginx/certs/server.key" failed (13: Permission denied)` | `cap_drop: ALL` bỏ mất `DAC_OVERRIDE`, không đọc được khóa quyền 600 | Giữ `DAC_OVERRIDE` trong `cap_add` của nginx |
| `docker compose pull` lỗi `GDBus ... org.freedesktop.secrets` | Credential helper của GNOME không chạy trong phiên SSH | `docker pull` từng image, hoặc để `~/.docker/config.json` là `{"auths":{}}` |
| Container "Up" nhưng cổng publish không listen, `NetworkSettings.Ports` rỗng | Container chỉ nằm trên mạng `internal: true` – bridge không có gateway nên Docker bỏ qua ánh xạ cổng | Thêm một mạng bridge thường (ở đây là `admin`) cho container cần publish cổng |
| phpMyAdmin lỗi `config.secret.inc.php: Read-only file system` | `read_only: true` chặn entrypoint ghi khoá blowfish | Mount named volume `pma_config` vào `/etc/phpmyadmin` (đã cấu hình sẵn) |
| phpMyAdmin báo `Error during session start ... Read-only file system` | PHP ghi session vào `/sessions` | Thêm `/sessions` vào `tmpfs` (đã cấu hình sẵn) |
| `wp: command not found` trong `wordpress:cli` | Entrypoint của image chỉ tự thêm `wp` khi `wp help "$1"` chạy được | Gọi bằng `--entrypoint wp`, hoặc dùng `scripts/wp.sh` đã đóng gói sẵn |
| WP-CLI báo không ghi được `wp-content/uploads` | `wordpress:cli` (Alpine) có `www-data` = uid 82, còn image Apache (Debian) là uid 33 | Chạy container CLI với `--user 33:33` |
| `wp db query` báo `Plugin caching_sha2_password could not be loaded` | Client MariaDB trong `wordpress:cli` không có plugin xác thực của MySQL 8 | Sửa dữ liệu bằng `wp post update ...` (chạy qua PHP), hoặc dùng `docker compose exec db mysql ...` |
| Bài viết hiện "By" trống, link `/author/` trả 404 | Bài do WP-CLI tạo khi không có phiên đăng nhập nên `post_author = 0` | Chạy lại `scripts/seed-demo.sh` — script đã gán `--post_author` và tự sửa các bài cũ |
| Promtail lặp lại `could not inspect container info ... No such container` | `docker_sd_configs` quét mọi container trên máy trước khi relabel; container tạm của `scripts/wp.sh` biến mất giữa hai lần quét | Đã thêm `filters` theo label `com.docker.compose.project=de3-wp` ngay ở Docker API |
| Log bị trùng sau khi restart Promtail | `positions.yaml` nằm trong `/tmp` (tmpfs) nên mất theo container | Đã chuyển sang volume `promtail_data:/var/lib/promtail` |

---

## 11. Tài liệu tham khảo

1. WordPress, *Docker Official Image* – <https://hub.docker.com/_/wordpress>
2. MySQL, *MySQL 8.0 Reference Manual* – <https://dev.mysql.com/doc/refman/8.0/en/>
3. Nginx, *ngx_http_limit_req_module* – <https://nginx.org/en/docs/http/ngx_http_limit_req_module.html>
4. Prometheus, *Configuration* – <https://prometheus.io/docs/prometheus/latest/configuration/configuration/>
5. Grafana Labs, *Loki & Promtail* – <https://grafana.com/docs/loki/latest/>
6. OWASP, *Secure Headers Project* – <https://owasp.org/www-project-secure-headers/>
7. CIS, *Docker Benchmark* – <https://www.cisecurity.org/benchmark/docker>

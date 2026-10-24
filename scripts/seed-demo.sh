#!/usr/bin/env bash
# =============================================================================
# Tạo dữ liệu mẫu cho website quảng bá sản phẩm (idempotent).
#   bash scripts/seed-demo.sh
# Mỗi trang/bài được nhận diện bằng slug: chạy lại nhiều lần không nhân đôi.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

WP=(bash scripts/wp.sh)
SITE_URL="https://192.168.75.129:8443"

# WP-CLI tạo bài khi không có phiên đăng nhập sẽ để post_author = 0, khiến theme
# in "By" với tên trống và sinh link hỏng /author/. Luôn gán tác giả là admin.
ADMIN_ID=$("${WP[@]}" user list --role=administrator --field=ID 2>/dev/null | head -1)
[ -n "$ADMIN_ID" ] || ADMIN_ID=1

# Sửa cả những bài đã tạo trước khi có dòng trên (idempotent)
mapfile -t ORPHANS < <("${WP[@]}" post list --post_type=post,page \
  --fields=ID,post_author --format=csv 2>/dev/null \
  | awk -F, -v a="$ADMIN_ID" 'NR>1 && $2!=a {print $1}')
if [ "${#ORPHANS[@]}" -gt 0 ]; then
  "${WP[@]}" post update "${ORPHANS[@]}" --post_author="$ADMIN_ID" >/dev/null
  echo "  - gán tác giả admin cho ${#ORPHANS[@]} bài cũ" >&2
fi

# --- Hàm tiện ích ------------------------------------------------------------
id_of() {  # $1 = post_type, $2 = slug
  "${WP[@]}" post list --post_type="$1" --name="$2" --field=ID --format=ids 2>/dev/null | head -1
}

ensure_page() {  # $1=title $2=slug $3=content
  local id; id=$(id_of page "$2")
  if [ -z "$id" ]; then
    id=$("${WP[@]}" post create --post_type=page --post_status=publish \
      --post_title="$1" --post_name="$2" --post_content="$3" \
      --post_author="$ADMIN_ID" --porcelain)
    echo "  + trang: $1 (ID $id)" >&2
  fi
  printf '%s' "$id"
}

ensure_featured() {  # $1=post_id $2=picsum_id
  local cur; cur=$("${WP[@]}" post meta get "$1" _thumbnail_id 2>/dev/null || true)
  [ -n "$cur" ] && return 0
  "${WP[@]}" media import "https://picsum.photos/id/$2/800/600.jpg" \
    --post_id="$1" --featured_image --porcelain >/dev/null 2>&1 || true
}

echo "== Gói ngôn ngữ, giao diện =="
"${WP[@]}" language core install vi --activate >/dev/null 2>&1 \
  || echo "  (không cài được gói tiếng Việt)"
"${WP[@]}" theme install astra --activate >/dev/null 2>&1 \
  || "${WP[@]}" theme activate astra 2>/dev/null || true

echo "== Cấu hình =="
"${WP[@]}" option update timezone_string 'Asia/Ho_Chi_Minh' >/dev/null
"${WP[@]}" option update blogdescription 'Sản phẩm công nghệ chính hãng – bảo hành 12 tháng' >/dev/null
"${WP[@]}" option update posts_per_page 9 >/dev/null
"${WP[@]}" option update default_comment_status closed >/dev/null
"${WP[@]}" option update default_ping_status closed >/dev/null

echo "== Dọn nội dung mẫu của WordPress =="
delete_by_slug() {  # $1=post_type $2=slug
  local ids; ids=$(id_of "$1" "$2")
  if [ -n "$ids" ]; then
    "${WP[@]}" post delete "$ids" --force >/dev/null && echo "  - xoá ${2}" >&2
  fi
}
delete_by_slug post hello-world
delete_by_slug post test
delete_by_slug page sample-page
delete_by_slug page privacy-policy

echo "== Trang tĩnh =="
HOME_CONTENT='
<h2>Chào mừng đến với TechMart</h2>
<p>TechMart chuyên cung cấp điện thoại, laptop và phụ kiện công nghệ chính hãng, bảo hành 12 tháng, giao hàng toàn quốc.</p>
<h3>Vì sao chọn TechMart?</h3>
<ul>
  <li>Sản phẩm chính hãng, có tem bảo hành.</li>
  <li>Đổi trả trong 7 ngày nếu lỗi nhà sản xuất.</li>
  <li>Hỗ trợ kỹ thuật 24/7 qua hotline 1900 1234.</li>
</ul>
<h3>Sản phẩm nổi bật</h3>
<!-- wp:latest-posts {"postsToShow":6,"columns":3,"displayPostContent":true,"excerptLength":18,"displayPostDate":false,"postLayout":"grid","addLinkToPost":true} /-->'

HOME_ID=$(ensure_page 'Trang chủ' 'trang-chu' "$HOME_CONTENT")
# Trang đã tồn tại từ lần chạy trước vẫn phải nhận nội dung mới (idempotent)
"${WP[@]}" post update "$HOME_ID" --post_content="$HOME_CONTENT" >/dev/null
ABOUT_ID=$(ensure_page 'Giới thiệu' 'gioi-thieu' '<h2>Về TechMart</h2><p>Được thành lập từ năm 2020, TechMart là chuỗi bán lẻ sản phẩm công nghệ với hơn 20 cửa hàng trên toàn quốc.</p>')
CONTACT_ID=$(ensure_page 'Liên hệ' 'lien-he' '<h2>Liên hệ</h2><p>Hotline: 1900 1234<br>Email: cskh@techmart.example<br>Địa chỉ: Số 1 Đường Công Nghệ, TP. Thái Nguyên</p>')
ensure_page 'Chính sách bảo hành' 'chinh-sach-bao-hanh' '<h2>Chính sách bảo hành</h2><ul><li>Bảo hành 12 tháng cho tất cả sản phẩm.</li><li>Hỗ trợ 1 đổi 1 trong 7 ngày đầu.</li><li>Miễn phí vệ sinh máy trọn đời.</li></ul>' >/dev/null

"${WP[@]}" option update show_on_front page >/dev/null
"${WP[@]}" option update page_on_front "$HOME_ID" >/dev/null

echo "== Danh mục sản phẩm =="
CAT_ID=$("${WP[@]}" term list category --slug=san-pham --field=term_id 2>/dev/null | head -1)
if [ -z "$CAT_ID" ]; then
  CAT_ID=$("${WP[@]}" term create category 'Sản phẩm' --slug=san-pham --porcelain)
fi

echo "== Sản phẩm (danh mục ID ${CAT_ID}) =="
idx=0
while IFS='|' read -r title price desc imgid; do
  idx=$((idx+1))
  slug="san-pham-${idx}"
  post_id=$(id_of post "$slug")
  if [ -z "$post_id" ]; then
    content="<h3>${title}</h3>
<p><strong>Giá: ${price}</strong></p>
<p>${desc}</p>
<h4>Thông số nổi bật</h4>
<ul><li>Bảo hành chính hãng 12 tháng</li><li>Giao hàng trong 24 giờ</li><li>Hỗ trợ trả góp 0%</li></ul>
<p>Liên hệ hotline <strong>1900 1234</strong> để được tư vấn.</p>"
    post_id=$("${WP[@]}" post create --post_type=post --post_status=publish \
      --post_title="$title" --post_name="$slug" --post_content="$content" \
      --post_excerpt="$desc" --post_category="$CAT_ID" \
      --post_author="$ADMIN_ID" --porcelain)
    echo "  + ${title}"
  fi
  ensure_featured "$post_id" "$imgid"
done <<'DATA'
TechPhone X1 Pro|12.990.000đ|Điện thoại flagship với màn hình AMOLED 6.7 inch, camera 108MP và pin 5000mAh sạc nhanh 65W.|20
TechBook Air 14|21.490.000đ|Laptop mỏng nhẹ 1.2kg, chip xử lý 8 nhân, RAM 16GB, SSD 512GB, màn hình 2.8K 90Hz.|2
TechPods Pro|2.490.000đ|Tai nghe không dây chống ồn chủ động ANC, pin 30 giờ, kháng nước IPX4.|3
TechWatch S2|4.990.000đ|Đồng hồ thông minh theo dõi sức khỏe, GPS tích hợp, pin 14 ngày.|5
TechKey K87|1.290.000đ|Bàn phím cơ không dây 87 phím, switch êm, đèn nền RGB.|8
TechCharge 65W|590.000đ|Củ sạc nhanh GaN 65W, 3 cổng, hỗ trợ PD và QC 4+.|9
DATA

echo "== Menu =="
"${WP[@]}" menu create 'Chính' >/dev/null 2>&1 || true
# Xoá item cũ trước khi thêm: nếu không, mỗi lần chạy lại menu sẽ dài thêm
# một bộ Trang chủ / Giới thiệu / Liên hệ (menu item không có slug để nhận diện).
read -r -a OLD_ITEMS <<< "$("${WP[@]}" menu item list chinh --format=ids 2>/dev/null || true)"
if [ "${#OLD_ITEMS[@]}" -gt 0 ]; then
  "${WP[@]}" menu item delete "${OLD_ITEMS[@]}" >/dev/null 2>&1 || true
  echo "  - xoá ${#OLD_ITEMS[@]} item menu cũ" >&2
fi
"${WP[@]}" menu item add-post chinh "$HOME_ID"    --title='Trang chủ'  >/dev/null 2>&1 || true
"${WP[@]}" menu item add-post chinh "$ABOUT_ID"   --title='Giới thiệu' >/dev/null 2>&1 || true
"${WP[@]}" menu item add-post chinh "$CONTACT_ID" --title='Liên hệ'    >/dev/null 2>&1 || true
"${WP[@]}" menu location assign chinh primary >/dev/null 2>&1 || true

echo
echo "Bài viết : $("${WP[@]}" post list --post_type=post --format=count)"
echo "Trang    : $("${WP[@]}" post list --post_type=page --format=count)"
echo "Ảnh      : $("${WP[@]}" post list --post_type=attachment --format=count)"
echo "Mở ${SITE_URL}"

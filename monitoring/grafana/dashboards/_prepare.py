"""Chuẩn hoá dashboard tải từ grafana.com để Grafana tự nạp (provisioning).

Provisioning KHÔNG xử lý khối __inputs như khi import qua giao diện, nên mọi
tham chiếu tới datasource mẫu phải được thay bằng UID cố định "prometheus"
(khai báo trong monitoring/grafana/provisioning/datasources/datasources.yml).
"""
import json
import pathlib
import sys

DS = "prometheus"
PLACEHOLDERS = ("${DS_PROMETHEUS}", "$DS_PROMETHEUS", "Prometheus")


def fix(node):
    if isinstance(node, dict):
        return {k: (DS if k == "uid" and v == "${DS_PROMETHEUS}" else fix(v))
                for k, v in node.items()}
    if isinstance(node, list):
        return [fix(v) for v in node]
    if isinstance(node, str) and node in ("${DS_PROMETHEUS}", "$DS_PROMETHEUS"):
        return DS
    return node


def main() -> int:
    for src in sorted(pathlib.Path(".").glob("raw-*.json")):
        dash = json.loads(src.read_text(encoding="utf-8"))
        dash.pop("__requires", None)
        dash.pop("__inputs", None)
        dash["id"] = None
        dash["uid"] = f"de3-{src.stem.removeprefix('raw-')}"
        dash = fix(dash)
        out = src.with_name(src.name.replace("raw-", "de3-"))
        out.write_text(json.dumps(dash, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"{src.name} -> {out.name}  (title: {dash.get('title')})")
        src.unlink()
    return 0


if __name__ == "__main__":
    sys.exit(main())

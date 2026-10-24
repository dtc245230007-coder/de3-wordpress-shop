#!/usr/bin/env python3
"""Chụp ảnh minh chứng các trang cần đăng nhập (Grafana, phpMyAdmin).

Trình duyệt headless thuần (`--screenshot`) không đăng nhập được, nên script
đăng nhập bằng HTTP (urllib) để lấy cookie phiên, nạp cookie đó vào Chrome qua
DevTools Protocol rồi chụp ảnh trang đích. Không bật anonymous, không hạ bất kỳ
cấu hình bảo mật nào của hệ thống.

    python docs/grab.py <grafana_url> <pma_url> <g_user> <g_pass> \
                        <pma_user> <pma_pass> [db]
"""
import base64
import http.client
import http.cookiejar
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

import websocket

CHROME = r"C:\Program Files\Google\Chrome\Application\chrome.exe"
PORT = 9222
VIEWPORT = (1600, 1200)
OUT = pathlib.Path(__file__).parent / "screenshots"


# --------------------------------------------------------------------------
# Đăng nhập bằng HTTP, trả về danh sách cookie của phiên
# --------------------------------------------------------------------------
def _opener(jar):
    return urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))


def login_grafana(base, user, password):
    jar = http.cookiejar.CookieJar()
    op = _opener(jar)
    # Grafana 10.x nhận JSON ở /login; gửi form-urlencoded sẽ trả
    # 400 "bad login data" (form-auth.invalid).
    body = json.dumps({"user": user, "password": password}).encode()
    req = urllib.request.Request(base + "/login", data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    with op.open(req, timeout=30) as resp:
        resp.read()
    return jar


def login_pma(base, user, password):
    jar = http.cookiejar.CookieJar()
    op = _opener(jar)
    with op.open(base + "/index.php", timeout=30) as resp:
        page = resp.read().decode("utf-8", "replace")
    m = re.search(r'name="token"\s+value="([^"]+)"', page)
    if not m:
        raise RuntimeError("Không tìm thấy token đăng nhập phpMyAdmin")
    body = urllib.parse.urlencode({
        "pma_username": user,
        "pma_password": password,
        "server": "1",
        "target": "index.php",
        "token": m.group(1),
    }).encode()
    req = urllib.request.Request(base + "/index.php", data=body, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    with op.open(req, timeout=30) as resp:
        resp.read()
    return jar


# --------------------------------------------------------------------------
# DevTools Protocol
# --------------------------------------------------------------------------
class Page:
    def __init__(self, ws_url):
        self.ws = websocket.create_connection(ws_url, timeout=90, max_size=64 << 20)
        self.n = 0

    def cmd(self, method, **params):
        self.n += 1
        self.ws.send(json.dumps({"id": self.n, "method": method, "params": params}))
        while True:
            msg = json.loads(self.ws.recv())
            if msg.get("id") == self.n:
                if "error" in msg:
                    raise RuntimeError(f"{method}: {msg['error']}")
                return msg.get("result", {})

    def set_cookies(self, jar, base):
        for c in jar:
            self.cmd("Network.setCookie", name=c.name, value=c.value,
                     url=base, path=c.path or "/")
        return len(jar)

    def goto(self, url, settle=2.0):
        self.cmd("Page.navigate", url=url)
        time.sleep(settle)

    def shot(self, name):
        data = self.cmd("Page.captureScreenshot", format="png",
                        captureBeyondViewport=False)
        path = OUT / f"{name}.png"
        path.write_bytes(base64.b64decode(data["data"]))
        print(f"  -> {path.name} ({path.stat().st_size} bytes)")


def http_json(method, path):
    conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=30)
    conn.request(method, path)
    body = conn.getresponse().read()
    conn.close()
    return json.loads(body) if body else {}


def start_chrome(profile):
    proc = subprocess.Popen([
        CHROME, "--headless=new", "--disable-gpu", "--no-sandbox",
        "--no-first-run", "--no-default-browser-check", "--disable-extensions",
        "--ignore-certificate-errors", "--remote-allow-origins=*",
        f"--remote-debugging-port={PORT}", f"--user-data-dir={profile}",
        f"--window-size={VIEWPORT[0]},{VIEWPORT[1]}", "about:blank",
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(60):
        try:
            http_json("GET", "/json/version")
            return proc
        except Exception:
            time.sleep(0.5)
    proc.terminate()
    raise RuntimeError("Chrome không mở được cổng DevTools")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    gw, pma = sys.argv[1], sys.argv[2]
    guser, gpass, puser, ppass = sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
    dbname = sys.argv[7] if len(sys.argv) > 7 else "wordpress"

    print("Đăng nhập Grafana")
    gjar = login_grafana(gw, guser, gpass)

    profile = tempfile.mkdtemp(prefix="cdp-")
    proc = start_chrome(profile)
    page = None
    try:
        page = Page(http_json("PUT", "/json/new?about:blank")["webSocketDebuggerUrl"])
        page.cmd("Page.enable")
        page.cmd("Network.enable")
        page.cmd("Emulation.setDeviceMetricsOverride", width=VIEWPORT[0],
                 height=VIEWPORT[1], deviceScaleFactor=1, mobile=False)
        print(f"  nạp {page.set_cookies(gjar, gw)} cookie Grafana")

        for uid, name in [("de3-website", "grafana-website"),
                          ("de3-1860", "grafana-node"),
                          ("de3-14282", "grafana-cadvisor"),
                          ("de3-7362", "grafana-mysql")]:
            print(f"Chụp {uid}")
            page.goto(f"{gw}/d/{uid}/?orgId=1&from=now-1h&to=now&kiosk", settle=10)
            page.shot(name)

        print("Đăng nhập phpMyAdmin")
        pjar = login_pma(pma, puser, ppass)
        print(f"  nạp {page.set_cookies(pjar, pma)} cookie phpMyAdmin")
        page.goto(f"{pma}/index.php?route=/sql&db={dbname}&table=wp_posts&pos=0",
                  settle=8)
        page.shot("phpmyadmin-tables")
    finally:
        if page:
            page.ws.close()
        proc.terminate()
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill()
        shutil.rmtree(profile, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())

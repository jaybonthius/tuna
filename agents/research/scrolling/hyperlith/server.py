#!/usr/bin/env python3
"""Throwaway demo (not Tuna code): hyperlith's virtual scroll, faithfully.

A port of /home/jay/Code/hyperlith/src/hyperlith/extras/ui/virtual_scroll.clj
(`virtual-scroll-logic` and the `::virtual` alias) to show what it looks
and feels like:

- One native scroll container. Its content box is the full height of every
  item (count × item size), so the scroll bar is the browser's own and exact.
- Every item has the same size, which is what makes that height known
  rather than guessed. Here: 50,000 text lines of 24 px, not wrapped.
- The server draws only the visible items plus a buffer of 4,000 px of items
  on each side, in a layer translated to where they belong.
- The page keeps the scroll offset in a signal ($y, `data-on:scroll`); a
  `data-effect` posts it when it leaves the server's thresholds (half the
  buffer from either edge) and removes itself, so one post is in flight;
  the next screen puts it back. Size is posted on load and on resize.

Screens go out one at a time, each after the page applied the last
(go-latest-frame-spike), newest only.

Run: python3 server.py [--host ADDR] [--port N]
"""
import argparse, json, math, random, secrets, socket, threading, time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse, parse_qs

HERE = Path(__file__).parent
DATASTAR = Path("/home/jay/Code/workbench-gerbil/tuna/plugins/web/web/datastar-v1.0.2.js")
N = 50000
ITEM = 24                                   # px: every line, as hyperlith's item-size
BUFFER = int(4000 / ITEM)                   # hyperlith: items that fill 4,000 px each side

WORDS = ("tuna buffer node view layout scroll anchor height estimate measure browser "
         "server morph frame window emacs redisplay point mark region column tree").split()
r = random.Random(7)
LINES = [f"{i + 1} " + " ".join(r.choice(WORDS) for _ in range(r.randint(1, 14))) for i in range(N)]

def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

def logic(y, h):
    """hyperlith's virtual-scroll-logic for one axis."""
    visible = max(1, math.ceil(h / ITEM))
    rendered = 2 * BUFFER + visible
    offset = max(0, min(round(y / ITEM) - BUFFER, N - rendered))
    remaining = N - offset
    threshold = 0.5 * BUFFER
    low = (offset + threshold) * ITEM if offset else 0
    high = ((offset + rendered - visible - threshold) * ITEM) if remaining > rendered else "Infinity"
    return offset, min(rendered, remaining), low, high

class Page:
    def __init__(self, cid):
        self.cid = cid
        self.lock = threading.Condition()
        self.y, self.h = 0, 800
        self.revision, self.applied = 0, 0

    def screen(self):
        offset, count, low, high = logic(self.y, self.h)
        items = "".join(f'<div class="line">{esc(LINES[i])}</div>' for i in range(offset, offset + count))
        post = f"@post('/scroll?c={self.cid}', {{retryMaxCount: Infinity}})"
        effect = f"if ({low} > $y || {high} < $y) {{ {post}; el.removeAttribute('data-effect') }}"
        applied = f"@post('/applied?c={self.cid}&n={self.revision}'); el.removeAttribute('data-init')"
        return (f'<main id="screen" data-init="{esc_attr(applied)}">'
                f'<div id="scroller" data-on:scroll="$y = Math.floor(el.scrollTop)" data-effect="{esc_attr(effect)}">'
                f'<div id="table" style="height:{N * ITEM}px">'
                f'<div id="translate" style="transform:translateY({offset * ITEM}px)">{items}</div>'
                f'</div></div></main>')

def esc_attr(s):
    return s.replace("&", "&amp;").replace('"', "&quot;").replace("<", "&lt;")

PAGES = {}

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass

    def setup(self):
        super().setup()
        self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

    def send_body(self, ctype, data, status=200):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def page(self):
        return PAGES.get(parse_qs(urlparse(self.path).query).get("c", [""])[0])

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/":
            cid = secrets.token_hex(4)
            page = PAGES[cid] = Page(cid)
            html = (HERE / "page.html").read_text().replace("{{C}}", cid).replace("{{SCREEN}}", page.screen())
            self.send_body("text/html; charset=utf-8", html.encode())
        elif path == "/datastar.js":
            self.send_body("text/javascript", DATASTAR.read_bytes())
        elif path == "/stream":
            page = self.page()
            if not page: return self.send_body("text/plain", b"reload the page", 404)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            sent = -1
            try:
                while True:
                    with page.lock:
                        # The newest screen, once the page applied the last one
                        # (or after a second, in case a screen was lost).
                        deadline = time.monotonic() + 1.0
                        while not (page.revision > sent and page.applied >= sent):
                            if time.monotonic() > deadline and page.revision >= sent:
                                break
                            page.lock.wait(0.1)
                        sent = page.revision
                        html = page.screen()
                    data = "".join(f"data: elements {line}\n" for line in html.split("\n"))
                    event = f"event: datastar-patch-elements\n{data}\n".encode()
                    self.wfile.write(b"%x\r\n%s\r\n" % (len(event), event))
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass
        else:
            self.send_body("text/plain", b"not found", 404)

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))   # read before answering
        url = urlparse(self.path)
        page = self.page()
        self.send_response(204 if page else 404); self.send_header("Content-Length", "0"); self.end_headers()
        if not page: return
        with page.lock:
            if url.path == "/applied":
                page.applied = max(page.applied, int(parse_qs(url.query)["n"][0]))
            else:
                signals = json.loads(raw or b"{}")
                page.y = max(0, int(signals.get("y", page.y)))
                page.h = max(1, int(signals.get("h", page.h)))
                page.revision += 1
            page.lock.notify_all()

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8765)
    args = p.parse_args()
    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    srv.daemon_threads = True
    print(f"http://{args.host}:{args.port}/", flush=True)
    srv.serve_forever()

if __name__ == "__main__":
    main()

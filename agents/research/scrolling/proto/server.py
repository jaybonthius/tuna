#!/usr/bin/env python3
"""Throwaway prototype for the Tuna scrolling research (not Tuna code).

Native scrolling with server-side windowing, after hyperlith's
virtual_scroll.clj. The browser scrolls; the server renders only the nodes
near the viewport, between two spacers, as one Datastar morph on the page's
screen stream.

Unlike hyperlith, node heights are unknown (wrapped paragraphs, code, tall
boxes), so the server only estimates them. To stay robust it never maps a
raw scroll offset through its estimates of the whole document; it places
the window relative to what the browser actually has on screen:

- a node is at the top of the viewport: keep that node exactly where it is
  (browser scroll anchoring absorbs estimate errors above it);
- the viewport is inside a spacer (a fast fling or a scrollbar drag): walk
  from the nearest edge of the rendered window by estimates, then put the
  node found exactly at the viewport.

Like hyperlith's batch loop, the stream re-renders the page's view every
50 ms tick and sends it once the previous screen has been written, whether
or not anything changed. Reports only update the view. A screen that is
lost or stuck therefore costs at most one tick: the next one replaces it
and puts back the data-effect the browser removed when it reported.

The browser side is two Datastar attributes on the scroller (see render()).

Run: python3 server.py [--host ADDR] [--port N] [--latency MS]
"""
import argparse, itertools, json, math, random, secrets, socket, threading, time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse, parse_qs

HERE = Path(__file__).parent
DATASTAR = Path("/home/jay/Code/workbench-gerbil/tuna/plugins/web/web/datastar-v1.0.2.js")
N = 20000
BEFORE, AFTER = 3000, 4000   # px rendered above / below the viewport (hyperlith uses 4000)

WORDS = ("tuna buffer node view layout scroll anchor height estimate measure "
         "browser server morph frame window emacs redisplay point mark region "
         "column tree text proportional monospace wrapped paragraph").split()

def make_nodes():
    r = random.Random(7)
    nodes = []
    for i in range(N):
        k = r.random()
        if k < 0.06:
            nodes.append(("h", f"Section {i}"))
        elif k < 0.16:
            lines = [" ".join(r.choice(WORDS) for _ in range(r.randint(1, 8))) for _ in range(r.randint(1, 14))]
            nodes.append(("pre", "\n".join(lines)))
        elif k < 0.19:
            nodes.append(("box", r.randint(80, 320)))
        else:
            nodes.append(("p", " ".join(r.choice(WORDS) for _ in range(r.randint(3, 90)))))
    return nodes

NODES = make_nodes()

def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

def node_html(i):
    kind, v = NODES[i]
    a = f'id="n{i}" data-i="{i}" class="n {kind}"'
    if kind == "h": return f'<h2 {a}>{esc(v)}</h2>'
    if kind == "pre": return f'<pre {a}>{esc(v)}</pre>'
    if kind == "box": return f'<div {a} style="height:{v}px">image {i}</div>'
    return f'<p {a}>{i}: {esc(v)}</p>'

_prefix = {}
def prefix(w):
    """Prefix sums of estimated node heights for a viewport width W.
    prefix(w)[i] is the estimated height of nodes 0..i-1."""
    w = int(w) // 10 * 10
    if w not in _prefix:
        cpl = max(20, (w - 32) / 8.6)            # characters per line, roughly
        def est(kind, v):
            if kind == "h": return 44
            if kind == "pre": return 16 + 20 * (v.count("\n") + 1)
            if kind == "box": return v
            return 12 + 24 * math.ceil(len(v) / cpl)
        _prefix[w] = [0] + list(itertools.accumulate(est(k, v) for k, v in NODES))
    return _prefix[w]

class Page:
    """One browser page: its view's anchor (a node and the content y of its
    top), its viewport size, and its screen stream."""
    def __init__(self, cid):
        self.cid = cid
        self.lock = threading.Lock()
        self.anchor, self.pos = 0, 0.0
        self.w, self.h = 800, 800
        self.revision, self.screen = 0, ""

    def place(self, s):
        """Set the anchor from what the browser reports it has on screen."""
        P = prefix(self.w)
        est = lambda i, j: P[j] - P[i]            # estimated height of nodes i..j-1
        y, top = float(s["at"]), int(s["top"])
        if top >= 0:                              # a node is at the viewport top
            self.anchor, self.pos = top, y - float(s["off"])
            return
        a, b, start, end = int(s["a"]), int(s["b"]), float(s["s"]), float(s["end"])
        if y < start:                             # above the window: walk back from a
            i, d = a, start - y
            while i > 0 and d > 0:
                i -= 1; d -= est(i, i + 1)
            self.anchor, self.pos = i, (y if d > 0 else y + d)
        else:                                     # below the window: walk on from b
            i, d = min(b, N - 1), max(0.0, y - end)
            while i < N - 1 and d >= est(i, i + 1):
                d -= est(i, i + 1); i += 1
            self.anchor, self.pos = i, y - d

    def render(self):
        P = prefix(self.w)
        est = lambda i, j: P[j] - P[i]
        t, h = self.anchor, self.h
        a = t
        while a > 0 and est(a, t) < BEFORE: a -= 1
        b = t
        while b < N and est(t, b) < h + AFTER: b += 1
        # Top spacer: put the anchor node where the browser has it, but leave
        # at least the estimated room for everything above the window.
        top = 0 if a == 0 else max(self.pos - est(a, t), P[a])
        bottom = est(b, N)
        # Re-post when the top node leaves [lo, hi]: half the margin above,
        # or less than a viewport plus half the margin left below.
        lo = t
        while lo > a and est(lo, t) < BEFORE / 2: lo -= 1
        hi = b - 1
        while hi > t and est(hi, b) < h + AFTER / 2: hi -= 1
        self.revision += 1
        self.last = f"anchor {t}@{self.pos:.0f} window {a}..{b} top-spacer {top:.0f} lo/hi {lo}/{hi} h {h}"
        body = "".join(node_html(i) for i in range(a, b))
        # The report rides in the URL, not in signals: writing signals here
        # and then posting (which reads every signal) re-runs the effect once
        # Datastar flushes its batch, which would post twice.
        post = (f"@post(`/scroll?c={self.cid}&a={a}&b={b}&s={top:.0f}"
                "&top=${i}&off=${n ? r.top - n.getBoundingClientRect().top : 0}"
                "&at=${el.scrollTop}&end=${el.lastElementChild.offsetTop}`, {retryMaxCount: Infinity})")
        # data-on:scroll records the offset; data-effect runs on every scroll
        # and once after each morph, finds the node at the top of the viewport,
        # and posts only if it is outside [lo, hi]. It removes itself, so one
        # request is in flight until the next screen puts it back (hyperlith's
        # pattern).
        effect = ("$y; const r = el.getBoundingClientRect(); "
                  "const n = document.elementFromPoint(r.left + r.width / 2, r.top + 1)?.closest('#scroller > [data-i]'); "
                  "const i = n ? +n.dataset.i : -1; "
                  f"if (i < {lo} || i > {hi}) {{ el.removeAttribute('data-effect'); {post} }}")
        self.screen = (
            f'<main id="screen" data-revision="{self.revision}">'
            f'<div id="scroller" data-on:scroll="$y = el.scrollTop" data-effect="{esc_attr(effect)}">'
            f'<div id="sp-top" class="spacer" style="height:{top:.0f}px"></div>{body}'
            f'<div id="sp-bot" class="spacer" style="height:{bottom:.0f}px"></div></div></main>')

def esc_attr(s):
    return s.replace("&", "&amp;").replace('"', "&quot;").replace("<", "&lt;")

def log(page, *msg):
    """Diagnostics: one line per event, to stdout."""
    print(f"{time.strftime('%H:%M:%S')}.{int(time.time() * 1000) % 1000:03d} {page.cid if page else '-'}", *msg, flush=True)

PAGES = {}
ARGS = None
POSTS = [0]   # for tests: total scroll/resize posts
TICK = 0.05   # s; hyperlith's default batch-tick-ms is 50

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass

    def setup(self):
        super().setup()
        # Small SSE writes must not wait for Nagle + delayed ACK (~40 ms).
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
            cid = secrets.token_hex(6)
            page = PAGES[cid] = Page(cid)
            with page.lock:
                page.render()
                screen = page.screen
            html = (HERE / "page.html").read_text().replace("{{SCREEN}}", screen).replace("{{C}}", cid)
            self.send_body("text/html; charset=utf-8", html.encode())
        elif path == "/stats":
            self.send_body("application/json", json.dumps({"posts": POSTS[0]}).encode())
        elif path == "/check.js":                    # for tests: see check.js
            self.send_body("text/javascript", (HERE / "check.js").read_bytes())
        elif path == "/datastar.js":
            self.send_body("text/javascript", DATASTAR.read_bytes())
        elif path == "/screen":
            page = self.page()
            if not page: return self.send_body("text/plain", b"reload the page", 404)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            log(page, "stream open")
            try:
                while True:                          # hyperlith's batch loop, one page
                    next_tick = time.monotonic() + TICK
                    with page.lock:
                        page.render()
                        screen = page.screen
                    if ARGS.latency: time.sleep(ARGS.latency / 1000)
                    # Every line of the HTML needs its own "data: elements" prefix.
                    data = "".join(f"data: elements {line}\n" for line in screen.split("\n"))
                    event = f"event: datastar-patch-elements\n{data}\n".encode()
                    # Blocks until written: the next screen is rendered only
                    # after this one went out (hyperlith's backpressure).
                    self.wfile.write(b"%x\r\n%s\r\n" % (len(event), event))
                    self.wfile.flush()
                    time.sleep(max(0.0, next_tick - time.monotonic()))
            except (BrokenPipeError, ConnectionResetError) as e:
                log(page, "stream closed:", type(e).__name__)
        else:
            self.send_body("text/plain", b"not found", 404)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(n)
        page = self.page()
        signals = json.loads(raw or b"{}")
        self.send_response(204 if page else 404); self.send_header("Content-Length", "0"); self.end_headers()
        if not page: return
        POSTS[0] += 1
        if ARGS.latency: time.sleep(ARGS.latency / 1000)
        q = {k: v[0] for k, v in parse_qs(urlparse(self.path).query).items()}
        with page.lock:
            page.w, page.h = signals.get("w") or page.w, signals.get("h") or page.h
            if urlparse(self.path).path == "/scroll":
                page.place(q)
                page.render()
                log(page, f"scroll report: top {q['top']} off {float(q['off']):.0f} at {float(q['at']):.0f} "
                          f"end {float(q['end']):.0f} (window {q['a']}..{q['b']} spacer {q['s']}) -> {page.last}")
            else:
                log(page, f"resize {page.w}x{page.h}")

def main():
    global ARGS
    p = argparse.ArgumentParser()
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--latency", type=float, default=0, help="one-way delay added to every screen and post (ms)")
    ARGS = p.parse_args()
    srv = ThreadingHTTPServer((ARGS.host, ARGS.port), Handler)
    srv.daemon_threads = True
    print(f"http://{ARGS.host}:{ARGS.port}/", flush=True)
    srv.serve_forever()

if __name__ == "__main__":
    main()

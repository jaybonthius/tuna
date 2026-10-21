#!/usr/bin/env python3
"""Throwaway prototype (not Tuna code): scrolling done entirely by the server.

The browser never scrolls. It sends scroll input (wheel deltas, finger
movement, and a fling's momentum after the finger lifts) as pixel deltas;
the server moves the view and streams frames. Content is generic blocks of
unknown height (paragraphs, code, headings, tall boxes), never lines.

- Position: an anchor block and how many px of it are above the view's top.
  Frames place the anchor block exactly at -offset; blocks above it stack
  upward from it, so a wrong height estimate never moves what you see.
- Heights: each frame's confirmation reports the real height of blocks whose
  height differs from the server's guess, so moves use real heights.
- Input: deltas add up, so order does not matter and nothing waits on a
  lost one. The page keeps up to three input posts in flight.
- Frames: up to WINDOW frames in flight; each confirms itself when applied
  (go-latest-frame-spike's /next). Frames are gzip-compressed on the stream
  unless ?gz=0, so a frame that differs little from the last costs little.

Modes (?mode=), the first three with up to WINDOW frames in flight, the
last three with ONE (go-latest-frame-spike: the next frame goes out only
after the page applied the last, so the frame rate is what the phone and
network can take):
  a  Emacs-like: each delta moves the view at once.
  b  server-smoothed: the server animates toward where the input says,
     sending intermediate frames (like pixel-scroll-precision interpolation).
  c  b plus a finger preview: while frames are on their way the page slides
     the current frame by the input the server has not shown yet.
  latest  each frame jumps to where the input has taken the view.
  steps   like latest, but the view moves by whole blocks (no pixel offsets),
          as Emacs moves by lines.
  glide   like latest; the page animates between the two positions the
          server sent, over about the time between frames.
?inflight=N overrides how many frames may be in flight.

Run: python3 server.py [--host ADDR] [--port N] [--latency MS]
--latency adds MS one way to every frame and every post, without limiting
how many are in flight (a 2,000-mile link is ~40 ms each way).
"""
import argparse, bisect, heapq, itertools, json, math, random, secrets, socket, threading, time, zlib
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse, parse_qs

HERE = Path(__file__).parent
DATASTAR = Path("/home/jay/Code/workbench-gerbil/tuna/plugins/web/web/datastar-v1.0.2.js")
N = 20000
WINDOW = 8          # frames in flight before the server waits for a confirmation; compressed
                    # frames are ~160 bytes, so this costs nothing and lets frames
                    # keep up with the display across an 80 ms round trip
TICK = 1 / 60       # animation step for modes b and c
RESEND = 1.0        # s without any confirmation before the newest frame is sent again

WORDS = ("tuna buffer node view layout scroll anchor height estimate measure "
         "browser server morph frame window emacs redisplay point mark region "
         "column tree text proportional monospace wrapped paragraph").split()

def make_blocks():
    r = random.Random(7)
    out = []
    for i in range(N):
        k = r.random()
        if k < 0.06: out.append(("h", f"Section {i}"))
        elif k < 0.16:
            out.append(("pre", "\n".join(" ".join(r.choice(WORDS) for _ in range(r.randint(1, 8)))
                                         for _ in range(r.randint(1, 14)))))
        elif k < 0.19: out.append(("box", r.randint(80, 320)))
        else: out.append(("p", " ".join(r.choice(WORDS) for _ in range(r.randint(3, 90)))))
    return out

BLOCKS = make_blocks()

_prefix = {}
def guess(i, w):
    kind, v = BLOCKS[i]
    cpl = max(20, (w - 32) / 8.6)
    if kind == "h": return 44
    if kind == "pre": return 24 + 20 * (v.count("\n") + 1)
    if kind == "box": return v
    return 12 + 24 * math.ceil(len(v) / cpl)

def prefix(w):
    """prefix(w)[i]: the guessed height of blocks 0..i-1 at width W."""
    w = int(w)
    if w not in _prefix:
        _prefix[w] = [0] + list(itertools.accumulate(guess(i, w) for i in range(N)))
    return _prefix[w]

def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

def block_html(i, h):
    kind, v = BLOCKS[i]
    a = f'id="b{i}" data-b="{i}" data-h="{h:.0f}" class="b {kind}"'
    if kind == "h": return f'<h2 {a}>{esc(v)}</h2>'
    if kind == "pre": return f'<pre {a}>{esc(v)}</pre>'
    if kind == "box": return f'<div {a} style="height:{v}px">box {i}</div>'
    return f'<p {a}>{i}: {esc(v)}</p>'

class Page:
    def __init__(self, cid, mode, inflight):
        self.cid, self.mode, self.inflight = cid, mode, inflight
        self.carry = 0.0                        # steps: input not yet a whole block
        self.lock = threading.Condition()
        self.anchor, self.offset = 0, 0.0      # what frames show
        self.remaining = 0.0                    # px of input not shown yet (modes b, c)
        self.heights = {}                       # block -> measured px
        self.w, self.h = 400, 700
        self.input_seq = 0                      # newest input folded into the position
        self.goto_seq = 0                       # newest scrollbar position applied
        self.frame, self.acked, self.last_ack = 0, 0, time.monotonic()
        self.dirty = True

    def est(self, i):
        if i in self.heights: return self.heights[i]
        return guess(i, self.w)

    def position(self):
        """(px above the view's top, total px): measured heights where known,
        guesses elsewhere. Drives the scrollbar."""
        p = prefix(self.w)
        fix_above = sum(px - guess(i, self.w) for i, px in self.heights.items() if i < self.anchor)
        fix_all = sum(px - guess(i, self.w) for i, px in self.heights.items())
        return p[self.anchor] + fix_above + self.offset, p[N] + fix_all

    def go_to(self, seq, fraction):
        """Scrollbar drag: show the block FRACTION of the way down. A drag
        sends several; one that arrives late is ignored."""
        if seq < self.goto_seq: return
        self.goto_seq = seq
        self.input_seq = max(self.input_seq, seq)
        p = prefix(self.w)
        y = max(0.0, min(1.0, fraction)) * max(0, p[N] - self.h)
        i = max(0, bisect.bisect_right(p, y) - 1)
        self.anchor, self.offset, self.remaining = min(i, N - 1), y - p[min(i, N - 1)], 0.0
        self.dirty = True

    def move(self, dy):
        self.offset += dy
        while self.offset >= self.est(self.anchor) and self.anchor < N - 1:
            self.offset -= self.est(self.anchor); self.anchor += 1
        while self.offset < 0 and self.anchor > 0:
            self.anchor -= 1; self.offset += self.est(self.anchor)
        if self.anchor == 0 and self.offset < 0:
            self.offset = 0.0
        self.dirty = True

    def input(self, seq, dy):
        self.input_seq = max(self.input_seq, seq)
        if self.mode in ("a", "latest", "glide"):
            self.move(dy)
        elif self.mode == "steps":
            self.carry += dy
            self.offset = 0.0
            while self.anchor < N - 1 and self.carry >= self.est(self.anchor):
                self.carry -= self.est(self.anchor); self.anchor += 1
            while self.anchor > 0 and self.carry <= -self.est(self.anchor - 1):
                self.anchor -= 1; self.carry += self.est(self.anchor)
            if self.anchor == 0 and self.carry < 0: self.carry = 0.0
        else:
            self.remaining += dy
        self.dirty = True                       # also confirms the input seq

    def animate(self):
        """One step toward where the input says (modes b and c)."""
        if abs(self.remaining) < 0.5:
            if self.remaining:
                self.move(self.remaining); self.remaining = 0.0
            return
        step = self.remaining * 0.35
        self.move(step); self.remaining -= step

    def render(self):
        """The frame: blocks a screen above and two below the anchor, placed
        relative to the anchor block, which sits at -offset."""
        above, acc, a = [], 0.0, self.anchor
        while a > 0 and acc < self.h:
            a -= 1; acc += self.est(a); above.append(a)
        below, acc, b = [], -self.offset, self.anchor
        while b < N and acc < 2 * self.h:
            below.append(b); acc += self.est(b); b += 1
        self.frame += 1
        heights = lambda i: self.est(i)
        # data-init confirms the frame and reports blocks whose real height
        # differs from the server's guess (data-h).
        confirm = (f"@post('/applied?c={self.cid}&n={self.frame}&h=' + encodeURIComponent(JSON.stringify("
                   "Object.fromEntries([...el.querySelectorAll('[data-b]')]"
                   ".filter(b => Math.abs(b.offsetHeight - b.dataset.h) > 0.5)"
                   ".map(b => [b.dataset.b, b.offsetHeight])))), {retryMaxCount: 3}); "
                   "el.removeAttribute('data-init')")
        return (f'<main id="frame" data-frame="{self.frame}" data-input="{self.input_seq}" '
                f'data-remaining="{self.remaining:.1f}" data-init="{esc_attr(confirm)}">'
                f'<div id="view"><div id="preview" data-preserve-attr="style">'
                f'<div id="content" style="top:{-self.offset:.1f}px">'
                f'<div id="above">{"".join(block_html(i, heights(i)) for i in reversed(above))}</div>'
                f'{"".join(block_html(i, heights(i)) for i in below)}'
                f'</div></div></div>{self.scrollbar()}</main>')

    def scrollbar(self):
        """The scrollbar: the server draws it like any other part. The page
        only previews the thumb while you drag it."""
        above, total = self.position()
        size = min(1.0, self.h / max(1.0, total))
        top = above / max(1.0, total - self.h) * (1 - size) if total > self.h else 0
        return (f'<div id="bar" data-size="{size:.6f}">'
                f'<div id="thumb" style="top:{top * 100:.4f}%;height:{size * 100:.4f}%"></div></div>')

def esc_attr(s):
    return s.replace("&", "&amp;").replace('"', "&quot;").replace("<", "&lt;")

PAGES, ARGS = {}, None

def log(page, *msg):
    print(f"{time.strftime('%H:%M:%S')} {page.cid if page else '-'}", *msg, flush=True)

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"                # keep-alive: posts reuse connections
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
        url = urlparse(self.path); q = parse_qs(url.query)
        if url.path == "/":
            cid = secrets.token_hex(4)
            mode = q.get("mode", ["latest"])[0]
            inflight = int(q.get("inflight", [WINDOW if mode in ("a", "b", "c") else 1])[0])
            page = PAGES[cid] = Page(cid, mode, max(1, inflight))
            gz = q.get("gz", ["1"])[0]
            html = ((HERE / "page.html").read_text().replace("{{C}}", cid)
                    .replace("{{MODE}}", page.mode).replace("{{GZ}}", gz)
                    .replace("{{INFLIGHT}}", str(page.inflight)))
            log(page, f"page loaded, mode {page.mode}, gzip {gz}, latency {ARGS.latency} ms each way")
            self.send_body("text/html; charset=utf-8", html.encode())
        elif url.path in ("/input.js", "/datastar.js"):
            self.send_body("text/javascript", (HERE / "input.js" if url.path == "/input.js" else DATASTAR).read_bytes())
        elif url.path == "/stream":
            self.stream(self.page(), q.get("gz", ["1"])[0] == "1")
        else:
            self.send_body("text/plain", b"not found", 404)

    def stream(self, page, gz):
        if not page: return self.send_body("text/plain", b"reload the page", 404)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Transfer-Encoding", "chunked")
        if gz: self.send_header("Content-Encoding", "gzip")
        self.end_headers()
        comp = zlib.compressobj(6, zlib.DEFLATED, 31) if gz else None
        out, out_lock = [], threading.Condition()   # (due, n, bytes): delayed, still pipelined
        alive = [True]
        stats = {"frames": 0, "bytes": 0, "t": time.monotonic()}

        def sender():
            try:
                while alive[0]:
                    with out_lock:
                        while not out: out_lock.wait(0.5)
                        due, _, data = out[0]
                        wait = due - time.monotonic()
                        if wait > 0:
                            out_lock.wait(wait); continue
                        heapq.heappop(out)
                    self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, OSError):
                alive[0] = False

        threading.Thread(target=sender, daemon=True).start()
        log(page, "stream open")
        try:
            while alive[0]:
                with page.lock:
                    if page.mode in ("b", "c"): page.animate()
                    stalled = page.frame > page.acked and time.monotonic() - page.last_ack > RESEND
                    if (page.dirty and page.frame - page.acked < page.inflight) or stalled:
                        if stalled:                    # a frame or its confirmation was lost
                            page.acked = page.frame; page.last_ack = time.monotonic()
                        page.dirty = False
                        html = page.render()
                        n = page.frame
                    else:
                        html = None
                        page.lock.wait(TICK)
                if html is None: continue
                event = ("event: datastar-patch-elements\n"
                         + "".join(f"data: elements {line}\n" for line in html.split("\n")) + "\n").encode()
                data = comp.compress(event) + comp.flush(zlib.Z_SYNC_FLUSH) if comp else event
                stats["frames"] += 1; stats["bytes"] += len(data)
                if time.monotonic() - stats["t"] > 5:
                    log(page, f"{stats['frames'] / 5:.0f} frames/s, {stats['bytes'] / max(1, stats['frames']):.0f} bytes/frame on the wire")
                    stats.update(frames=0, bytes=0, t=time.monotonic())
                with out_lock:
                    heapq.heappush(out, (time.monotonic() + ARGS.latency / 1000, n, data))
                    out_lock.notify()
                if page.mode in ("b", "c"):
                    time.sleep(TICK)
        finally:
            alive[0] = False
            log(page, "stream closed")

    def do_POST(self):
        # Read the body before answering (Tuna's iPhone lesson).
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        url = urlparse(self.path); q = parse_qs(url.query)
        page = self.page()
        if ARGS.latency: time.sleep(ARGS.latency / 1000)
        if page and url.path == "/input":
            f = json.loads(raw or b"{}")
            with page.lock:
                if "w" in f:
                    page.w, page.h = f["w"], f["h"]
                if f.get("dy"):
                    page.input(int(f["seq"]), float(f["dy"]))
                if "to" in f:
                    page.go_to(int(f["seq"]), float(f["to"]))
                page.dirty = True
                page.lock.notify_all()
        elif page and url.path == "/applied":
            with page.lock:
                page.acked = max(page.acked, int(q["n"][0]))
                page.last_ack = time.monotonic()
                for i, px in json.loads(q.get("h", ["{}"])[0]).items():
                    page.heights[int(i)] = float(px)
                page.lock.notify_all()
        self.send_response(204 if page else 404); self.send_header("Content-Length", "0"); self.end_headers()

def main():
    global ARGS
    p = argparse.ArgumentParser()
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--latency", type=float, default=0, help="one-way delay in ms")
    ARGS = p.parse_args()
    srv = ThreadingHTTPServer((ARGS.host, ARGS.port), Handler)
    srv.daemon_threads = True
    print(f"http://{ARGS.host}:{ARGS.port}/?mode=latest|steps|glide|a|b|c[&inflight=N][&gz=0]", flush=True)
    srv.serve_forever()

if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Throwaway prototype for the Tuna scrolling research (not Tuna code).

One view over a 20,000-node "rich buffer" whose node heights the server
cannot know (wrapped paragraphs, code blocks, tall boxes). The server
owns the scroll anchor and renders only a window of nodes; every screen
is one Datastar fat morph over SSE, as in Tuna.

Modes (?mode=...):
  native   native scroll container; server windows the content with
           top/bottom spacers sized from a height map (estimates corrected
           by measurements the client reports); browser scroll anchoring
           keeps the view still when spacers change.
  backend  no native scrolling; wheel/touch deltas go to the server, which
           moves the anchor and re-renders (pure server-side scrolling).
  hybrid   like backend, but the client moves already-rendered content
           locally (CSS transform) until the server's screen catches up,
           and runs its own touch momentum.

Point (?point=follow|stay): the server keeps a cursor on one node. With
"follow", scrolling moves point into view, as Emacs does; with "stay",
point stays put and the next command that uses it brings it back into
view. Commands (keys or the toolbar) are server-side, like C-v in Emacs.

Options: --host ADDR binds another address (e.g. a Tailscale IP for a
phone); --latency MS adds one-way delay to every screen; --bad-estimates
makes every estimate one line, to stress correction; --ack sends a screen
only after the client reports the previous one applied.
"""
import argparse, json, math, random, threading, time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

HERE = Path(__file__).parent
DATASTAR = Path("/home/jay/Code/workbench-gerbil/tuna/plugins/web/web/datastar-v1.0.2.js")
N = 20000

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

class View:
    """The server's per-view scroll state: an anchor (node index plus a
    pixel offset into it), the viewport size, and a height map."""
    def __init__(self, bad):
        self.anchor, self.offset = 0, 0.0
        self.h, self.w = 800, 800
        self.measured = {}          # node index -> measured px, for width self.w
        self.bad = bad

    def estimate(self, i):
        kind, v = NODES[i]
        if self.bad:
            return 24
        cpl = max(20, (self.w - 48) / 8.6)
        if kind == "h": return 44
        if kind == "pre": return 16 + 20 * (v.count("\n") + 1)
        if kind == "box": return v + 16
        return 12 + 24 * math.ceil(len(v) / cpl)

    def height(self, i):
        return self.measured.get(i) or self.estimate(i)

    def window(self, overscan):
        a, acc = self.anchor, self.offset
        while a > 0 and acc < overscan:
            a -= 1; acc += self.height(a)
        b, acc2 = self.anchor, -self.offset
        while b < N and acc2 < self.h + overscan:
            acc2 += self.height(b); b += 1
        return a, b

    def last_visible(self):
        """The last node at least partly in the viewport, from the height map."""
        b, acc = self.anchor, -self.offset
        while b < N - 1:
            acc += self.height(b)
            if acc >= self.h: break
            b += 1
        return b

    def first_visible(self):
        """The first node whose top is in the viewport."""
        return self.anchor if self.offset <= 0.5 else min(N - 1, self.anchor + 1)

    def show(self, i):
        """Scroll as little as possible so node I is in view (Emacs keeps
        point visible). Returns True if the anchor moved."""
        if self.first_visible() <= i < self.last_visible() or (i == self.anchor and self.offset <= 0.5):
            return False
        if i < self.first_visible():
            self.anchor, self.offset = i, 0.0
        else:                                    # put node I at the bottom
            a, acc = i, self.height(i)
            while a > 0 and acc + self.height(a - 1) <= self.h:
                a -= 1; acc += self.height(a)
            self.anchor, self.offset = a, 0.0
        return True

    def move(self, dy):
        """Scroll by DY pixels through the height map (backend modes)."""
        self.offset += dy
        while self.offset < 0 and self.anchor > 0:
            self.anchor -= 1; self.offset += self.height(self.anchor)
        if self.offset < 0: self.offset = 0
        while self.anchor < N - 1 and self.offset >= self.height(self.anchor):
            self.offset -= self.height(self.anchor); self.anchor += 1

TYPED = {}                          # node index -> text typed at its end

def node_html(i, est, point):
    kind, v = NODES[i]
    cls = "n point" if i == point else "n"
    attrs = f'id="n{i}" data-i="{i}" data-est="{est}"'
    t = esc(TYPED.get(i, ""))
    if kind == "h": return f'<h2 {attrs} class="{cls}">{esc(v)}{t}</h2>'
    if kind == "pre": return f'<pre {attrs} class="{cls}">{esc(v)}{t}</pre>'
    if kind == "box": return f'<div {attrs} class="{cls} box" style="height:{v}px">image {i}{t}</div>'
    return f'<p {attrs} class="{cls}">{i}: {esc(v)}{t}</p>'

class App:
    def __init__(self, args):
        self.args = args
        self.lock = threading.Condition()
        self.view = View(args.bad_estimates)
        self.mode = "native"
        self.revision = 0
        self.screen = ""
        self.ack_input = 0       # newest input sequence folded into the state
        self.applied = 0         # newest revision the client says it applied
        self.point = 0           # the cursor: a node index
        self.follow = True       # scrolling moves point into view (Emacs)
        self.request = 0         # bumped when a command moves the anchor
        self.render_count = 0
        self.render_ms = 0.0

    def render(self):
        t0 = time.perf_counter()
        v = self.view
        self.revision += 1
        if self.mode == "native":
            a, b = v.window(1500)
            top = sum(v.height(k) for k in range(a))       # a real height map is a sum tree
            bottom = sum(v.height(k) for k in range(b, N))
            mid_lo = (a + v.anchor) // 2 if a > 0 else -1
            last = b - 1
            hi = (v.anchor + last) // 2 + 1 if b < N else N + 1
            body = "".join(node_html(i, v.height(i), self.point) for i in range(a, b))
            html = (f'<main id="screen" data-revision="{self.revision}" data-mode="native" data-ack="{self.ack_input}" {self.status()}>'
                    f'<div id="scroller" class="scroller" data-lo="{mid_lo}" data-hi="{hi}" '
                    f'data-req="{self.request}" data-req-anchor="{v.anchor}" data-req-offset="{v.offset:.1f}">'
                    f'<div id="sp-top" style="height:{top:.0f}px"></div>{body}'
                    f'<div id="sp-bot" style="height:{bottom:.0f}px"></div></div></main>')
        else:
            a, b = v.window(600)
            y = sum(v.height(k) for k in range(a, v.anchor)) + v.offset
            total = sum(v.height(k) for k in range(N))
            above = sum(v.height(k) for k in range(v.anchor)) + v.offset
            body = "".join(node_html(i, v.height(i), self.point) for i in range(a, b))
            html = (f'<main id="screen" data-revision="{self.revision}" data-mode="{self.mode}" data-ack="{self.ack_input}" data-y="{y:.1f}" {self.status()}>'
                    f'<div id="scroller" class="scroller owned">'
                    f'<div id="content" style="transform:translateY({-y:.1f}px)">{body}</div>'
                    f'<div id="thumb" style="top:{100 * above / max(1, total):.3f}%"></div></div></main>')
        self.screen = html
        self.render_count += 1
        self.render_ms += (time.perf_counter() - t0) * 1000
        self.lock.notify_all()

    def status(self):
        return f'data-point="{self.point}" data-follow="{int(self.follow)}"'

    def follow_point(self, last=None):
        """After a scroll: with "follow", move point into the viewport."""
        if not self.follow: return
        v = self.view
        first, last = v.first_visible(), (last if last is not None else v.last_visible())
        if self.point < first: self.point = min(first, last)
        elif self.point > last: self.point = last

    def command(self, f):
        """Server-side commands, like Emacs commands bound to keys."""
        with self.lock:
            v, c = self.view, f["cmd"]
            scrolled = False
            if c == "down": self.point = min(N - 1, self.point + 1)
            elif c == "up": self.point = max(0, self.point - 1)
            elif c == "set": self.point = int(f["i"])
            elif c == "type":
                TYPED[self.point] = TYPED.get(self.point, "") + f.get("text", " typed")
                v.measured.pop(self.point, None)
            elif c == "follow": self.follow = not self.follow
            elif c == "pgdn":                       # C-v: the last visible node goes to the top
                v.anchor, v.offset = max(v.anchor + 1, v.last_visible()), 0.0; scrolled = True
            elif c == "pgup":                       # M-v: the first visible node goes to the bottom
                a, acc = v.anchor, 0.0
                while a > 0 and acc + v.height(a - 1) <= v.h:
                    a -= 1; acc += v.height(a)
                v.anchor, v.offset = a, 0.0; scrolled = True
            if scrolled:
                self.follow_point()                 # with "stay", point may now be off screen
            elif c in ("down", "up", "type", "set"):
                scrolled = v.show(self.point)       # commands that use point bring it into view
            if scrolled: self.request += 1
            self.render()

    def facts(self, f):
        with self.lock:
            v = self.view
            if "w" in f and abs(f["w"] - v.w) > 0.5:
                v.measured.clear()                 # wrapping changed: measurements are stale
            for k in ("h", "w"):
                if k in f: setattr(v, k, f[k])
            for i, px in f.get("measured", {}).items():
                v.measured[int(i)] = px
            if "pixel" in f:                       # native: scrolled past the window
                y, i = float(f["pixel"]), 0
                while i < N - 1 and y >= v.height(i):
                    y -= v.height(i); i += 1
                v.anchor, v.offset = i, y
                self.follow_point()
            stale = int(f.get("req", self.request)) < self.request
            if "pixel" in f and stale: del f["pixel"]
            if "anchor" in f and not stale:        # native: the browser scrolled
                v.anchor, v.offset = int(f["anchor"]), float(f["offset"])
                self.follow_point(int(f["last"]) if "last" in f else None)
            if "dy" in f:                          # backend/hybrid: a scroll delta
                v.move(float(f["dy"]))
                self.follow_point()
            if "seq" in f:
                self.ack_input = max(self.ack_input, int(f["seq"]))
            self.render()

APP = None

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass

    def send_body(self, ctype, data, status=200):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/":
            mode = "native"
            if "mode=" in self.path:
                mode = self.path.split("mode=")[1].split("&")[0]
            with APP.lock:
                APP.mode = mode
                APP.follow = "point=stay" not in self.path
                APP.point = 0
                APP.view.anchor, APP.view.offset = 0, 0.0
                APP.render()
                screen = APP.screen
            page = (HERE / "page.html").read_text().replace("{{SCREEN}}", screen)
            self.send_body("text/html; charset=utf-8", page.encode())
        elif path == "/datastar.js":
            self.send_body("text/javascript", DATASTAR.read_bytes())
        elif path == "/client.js":
            self.send_body("text/javascript", (HERE / "client.js").read_bytes())
        elif path == "/stats":
            with APP.lock:
                s = {"renders": APP.render_count, "render_ms_avg": APP.render_ms / max(1, APP.render_count),
                     "measured": len(APP.view.measured), "anchor": APP.view.anchor, "offset": APP.view.offset}
            self.send_body("application/json", json.dumps(s).encode())
        elif path == "/screen":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            sent = -1
            try:
                while True:
                    with APP.lock:
                        while not (APP.revision > sent and (not APP.args.ack or APP.applied >= sent)):
                            APP.lock.wait(15)
                        sent, screen = APP.revision, APP.screen
                    if APP.args.latency:
                        time.sleep(APP.args.latency / 1000)
                    data = "".join(f"data: elements {line}\n" for line in screen.split("\n"))
                    self.wfile.write(f"event: datastar-patch-elements\n{data}\n".encode())
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
        else:
            self.send_body("text/plain", b"not found", 404)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        f = json.loads(self.rfile.read(n) or b"{}")
        self.send_response(204); self.send_header("Content-Length", "0"); self.end_headers()
        if APP.args.latency:
            time.sleep(APP.args.latency / 1000)
        if self.path == "/cmd":
            APP.command(f)
        elif self.path == "/applied":
            with APP.lock:
                APP.applied = max(APP.applied, int(f["revision"]))
                APP.lock.notify_all()
        else:
            APP.facts(f)

def main():
    global APP
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--latency", type=float, default=0)
    p.add_argument("--bad-estimates", action="store_true")
    p.add_argument("--ack", action="store_true")
    args = p.parse_args()
    APP = App(args)
    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    srv.daemon_threads = True
    print(f"http://{args.host}:{args.port}/?mode=native|backend|hybrid&point=follow|stay", flush=True)
    srv.serve_forever()

if __name__ == "__main__":
    main()

// Throwaway client for the scrolling prototype. Datastar opens the screen
// stream and morphs #screen; this file reports layout facts and input.
const P = (window.__proto = { latencies: [], applied: 0, reports: 0 });
const CLIENT = document.documentElement.dataset.client;
const post = (path, body) => fetch(`${path}?c=${CLIENT}`, {
  method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
});
const scroller = () => document.getElementById("scroller");
const mode = () => document.getElementById("screen").dataset.mode;

let seq = 0;
const sentAt = new Map();      // input seq -> time sent
let unacked = [];              // hybrid: [seq, dy] not yet in a screen
let pendingDy = 0, dyFrame = 0;
const bound = new WeakSet();

// ---- facts for native mode -------------------------------------------------
function visible(sc) {
  const top = sc.scrollTop, bottom = top + sc.clientHeight;
  let first = null, last = null;
  for (const el of sc.children) {
    if (!el.dataset.i) continue;
    const t = el.offsetTop, b = t + el.offsetHeight;
    if (b > top && !first) first = el;
    if (t < bottom) last = el;
  }
  return { first, last, top };
}
function measured(sc) {
  const m = {}, kids = [...sc.children];
  for (let k = 0; k < kids.length - 1; k++) {
    const el = kids[k];
    if (!el.dataset.i) continue;
    const h = kids[k + 1].offsetTop - el.offsetTop;
    if (Math.abs(h - Number(el.dataset.est)) > 0.5) m[el.dataset.i] = h;
  }
  return m;
}
// At most one report waits for its screen; while it waits, only the
// newest facts are kept (the next report reads them fresh).
let waitingFor = 0, wanted = false, appliedReq = 0;
// Scroll velocity in px/s, smoothed, so the server can draw further ahead.
let lastTop = 0, lastT = 0, velocity = 0;
function trackVelocity(sc) {
  const t = performance.now(), dt = t - lastT;
  if (lastT && dt > 0 && dt < 200) velocity = 0.7 * velocity + 0.3 * ((sc.scrollTop - lastTop) / dt) * 1000;
  else velocity = 0;
  lastTop = sc.scrollTop; lastT = t;
}
function send(facts) {
  const s = ++seq;
  facts.v = performance.now() - lastT > 120 ? 0 : Math.round(velocity);   // stale means stopped
  waitingFor = s; P.reports++;
  post("/facts", { ...facts, seq: s });
  // A lost report must never freeze the view: give up waiting after a second.
  setTimeout(() => { if (waitingFor === s) { waitingFor = 0; report(true); } }, 1000);
}
function report(force) {
  const sc = scroller();
  if (!sc || mode() !== "native") return;
  if (waitingFor) { wanted = true; return; }
  const { first, last, top } = visible(sc);
  if (!first) {                      // inside a spacer: only the pixel offset is known
    send({ pixel: top, h: sc.clientHeight, w: sc.clientWidth, req: appliedReq });
    return;
  }
  const m = measured(sc);
  const outside = Number(first.dataset.i) < Number(sc.dataset.lo) || Number(last.dataset.i) > Number(sc.dataset.hi);
  if (force || outside || Object.keys(m).length) {
    send({ anchor: Number(first.dataset.i), offset: top - first.offsetTop, last: Number(last.dataset.i),
           h: sc.clientHeight, w: sc.clientWidth, measured: m, req: appliedReq });
  }
}
let reportFrame = 0;
const scheduleReport = () => { if (!reportFrame) reportFrame = requestAnimationFrame(() => { reportFrame = 0; report(false); }); };

// ---- input for backend and hybrid modes -----------------------------------
function serverY() { return Number(document.getElementById("screen").dataset.y || 0); }
function applyLocal() {
  if (mode() !== "hybrid") return;
  const local = unacked.reduce((s, [, dy]) => s + dy, 0) + pendingDy;
  const c = document.getElementById("content");
  if (c) c.style.transform = `translateY(${-(serverY() + local)}px)`;
}
// Like go-web-terminal: deltas are summed, and at most one is in flight.
// While it waits for its screen, new deltas only add to the pending sum,
// so the server always gets the newest total, never a backlog.
let dyInFlight = 0;
function flushDy() {
  if (dyInFlight || !pendingDy) return;
  const s = ++seq, sc = scroller();
  sentAt.set(s, performance.now());
  unacked.push([s, pendingDy]);
  dyInFlight = s;
  post("/facts", { dy: pendingDy, seq: s, h: sc.clientHeight, w: sc.clientWidth });
  pendingDy = 0;
  setTimeout(() => { if (dyInFlight === s) { dyInFlight = 0; flushDy(); } }, 1000);
}
function queueDy(dy) {
  pendingDy += dy;
  applyLocal();
  if (dyFrame) return;
  dyFrame = requestAnimationFrame(() => { dyFrame = 0; flushDy(); });
}
let momentum = 0;
function bindOwned(sc) {
  sc.addEventListener("wheel", (e) => {
    e.preventDefault();
    const unit = e.deltaMode === 1 ? 24 : e.deltaMode === 2 ? sc.clientHeight : 1;
    queueDy(e.deltaY * unit);
  }, { passive: false });
  let lastY = null, samples = [];
  sc.addEventListener("pointerdown", (e) => {
    cancelAnimationFrame(momentum); lastY = e.clientY; samples = [[e.timeStamp, e.clientY]];
    sc.setPointerCapture(e.pointerId);
  });
  sc.addEventListener("pointermove", (e) => {
    if (lastY === null) return;
    queueDy(lastY - e.clientY); lastY = e.clientY;
    samples.push([e.timeStamp, e.clientY]); if (samples.length > 6) samples.shift();
  });
  sc.addEventListener("pointerup", (e) => {
    if (lastY === null) return;
    lastY = null;
    const [t0, y0] = samples[0], [t1, y1] = samples[samples.length - 1];
    let v = t1 > t0 ? (y0 - y1) / (t1 - t0) : 0;       // px per ms
    let prev = performance.now();
    const step = (now) => {                                // iOS-like 0.998/ms friction
      const dt = now - prev; prev = now;
      queueDy(v * dt); v *= Math.pow(0.998, dt);
      if (Math.abs(v) > 0.02) momentum = requestAnimationFrame(step);
    };
    momentum = requestAnimationFrame(step);
  });
}

// ---- per screen -------------------------------------------------------------
function onScreen() {
  const screen = document.getElementById("screen"), sc = scroller();
  const ack = Number(screen.dataset.ack);
  const now = performance.now();
  for (const [k, t] of sentAt) if (k <= ack) { P.latencies.push(now - t); sentAt.delete(k); }
  unacked = unacked.filter(([k]) => k > ack);
  applyLocal();
  P.applied++;
  post("/applied", { revision: Number(screen.dataset.revision) });
  if (sc && !bound.has(sc)) {
    bound.add(sc);
    if (mode() === "native") {
      sc.addEventListener("scroll", () => { trackVelocity(sc); scheduleReport(); }, { passive: true });
      sc.addEventListener("scrollend", () => report(true));
      new ResizeObserver(() => report(true)).observe(sc);
    } else {
      bindOwned(sc);
      new ResizeObserver(() => post("/facts", { h: sc.clientHeight, w: sc.clientWidth })).observe(sc);
    }
  }
  if (waitingFor && ack >= waitingFor) waitingFor = 0;
  if (dyInFlight && ack >= dyInFlight) { dyInFlight = 0; flushDy(); }
  // A command moved the anchor: apply it once, instantly (never smooth,
  // or the animation sweeps through the thresholds and posts reports).
  if (sc && mode() === "native" && Number(sc.dataset.req) > appliedReq) {
    const el = document.getElementById("n" + sc.dataset.reqAnchor);
    if (el) sc.scrollTop = el.offsetTop + Number(sc.dataset.reqOffset);
    appliedReq = Number(sc.dataset.req);
    wanted = true;
  }
  if (mode() === "native") requestAnimationFrame(() => { const w = wanted; wanted = false; report(w); });
  document.getElementById("hud").textContent =
    `${mode()} · point ${screen.dataset.point} · rev ${screen.dataset.revision} · reports ${P.reports}`;
  document.getElementById("follow").textContent =
    screen.dataset.follow === "1" ? "point: follows scroll" : "point: stays put";
}
let lastRev = 0;
new MutationObserver(() => {
  const s = document.getElementById("screen");
  if (!s || Number(s.dataset.revision) === lastRev) return;
  lastRev = Number(s.dataset.revision);
  onScreen();
}).observe(document.body, { subtree: true, attributes: true, attributeFilter: ["data-revision"], childList: true });
onScreen();

// ---- measurement helpers, driven from agent_browser -----------------------
// Scroll D px per frame for STEPS frames; track one rendered node and report
// how far it strays from where the scroll alone should put it (a visible jump).
P.scrollTest = (steps, d) => new Promise((resolve) => {
  const devs = []; let tracked = null, before = 0, k = 0;
  const pick = () => {
    const sc = scroller();
    if (mode() !== "native") {
      const top = sc.getBoundingClientRect().top;
      const el = [...document.getElementById("content").children].find((c) => c.getBoundingClientRect().top >= top);
      return el ? el.id : null;
    }
    const { first } = visible(sc);
    let el = first;
    while (el && el.offsetTop < sc.scrollTop) el = el.nextElementSibling;   // first fully visible
    return el && el.dataset.i ? el.id : null;
  };
  const frame = () => {
    const sc = scroller();
    if (tracked) {
      const el = document.getElementById(tracked);
      if (el) devs.push(el.getBoundingClientRect().top - (before - d));
    }
    tracked = pick();
    if (!tracked || k++ >= steps) {
      const abs = devs.map(Math.abs).sort((a, b) => a - b);
      return resolve({ frames: devs.length, maxDev: abs.at(-1), over1px: abs.filter((x) => x > 1).length,
                       p99: abs[Math.floor(abs.length * 0.99)], scrollTop: sc.scrollTop, applied: P.applied });
    }
    before = document.getElementById(tracked).getBoundingClientRect().top;
    if (mode() === "native") sc.scrollBy(0, d); else queueDy(d);
    requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);
});
P.latencySummary = () => {
  const l = [...P.latencies].sort((a, b) => a - b);
  const q = (p) => l[Math.min(l.length - 1, Math.floor(l.length * p))];
  return { n: l.length, p50: q(0.5), p95: q(0.95), max: l.at(-1) };
};

// ---- point and commands (server-side, like Emacs commands) -----------------
const cmd = (body) => post("/cmd", body);
document.getElementById("bar").addEventListener("click", (e) => {
  const b = e.target.closest("button[data-cmd]");
  if (b) { e.preventDefault(); cmd({ cmd: b.dataset.cmd }); }
});
const keys = { ArrowDown: "down", ArrowUp: "up", PageDown: "pgdn", PageUp: "pgup" };
document.addEventListener("keydown", (e) => {
  if (e.ctrlKey || e.metaKey || e.altKey) return;
  if (keys[e.key]) { e.preventDefault(); cmd({ cmd: keys[e.key] }); }
  else if (e.key.length === 1) { e.preventDefault(); cmd({ cmd: "type", text: e.key }); }
});
// A tap (not a drag) on a node puts point there.
let downAt = null;
document.addEventListener("pointerdown", (e) => { downAt = [e.clientX, e.clientY]; }, true);
document.addEventListener("pointerup", (e) => {
  if (!downAt || Math.hypot(e.clientX - downAt[0], e.clientY - downAt[1]) > 8) return;
  const n = document.elementFromPoint(e.clientX, e.clientY)?.closest(".n");
  if (n && !e.target.closest("#bar")) cmd({ cmd: "set", i: Number(n.dataset.i) });
}, true);

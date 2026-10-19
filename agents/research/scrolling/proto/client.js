// Throwaway client for the scrolling prototype. Datastar opens the screen
// stream and morphs #screen; this file reports layout facts and input.
const P = (window.__proto = { latencies: [], applied: 0, reports: 0 });
const post = (path, body) => fetch(path, {
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
let waitingFor = 0, wanted = false;
function send(facts) {
  const s = ++seq;
  waitingFor = s; P.reports++;
  post("/facts", { ...facts, seq: s });
}
function report(force) {
  const sc = scroller();
  if (!sc || mode() !== "native") return;
  if (waitingFor) { wanted = true; return; }
  const { first, last, top } = visible(sc);
  if (!first) {                      // inside a spacer: only the pixel offset is known
    send({ pixel: top, h: sc.clientHeight, w: sc.clientWidth });
    return;
  }
  const m = measured(sc);
  const outside = Number(first.dataset.i) < Number(sc.dataset.lo) || Number(last.dataset.i) > Number(sc.dataset.hi);
  if (force || outside || Object.keys(m).length) {
    send({ anchor: Number(first.dataset.i), offset: top - first.offsetTop,
           h: sc.clientHeight, w: sc.clientWidth, measured: m });
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
function queueDy(dy) {
  pendingDy += dy;
  applyLocal();
  if (dyFrame) return;
  dyFrame = requestAnimationFrame(() => {
    dyFrame = 0;
    if (!pendingDy) return;
    const s = ++seq, sc = scroller();
    sentAt.set(s, performance.now());
    unacked.push([s, pendingDy]);
    post("/facts", { dy: pendingDy, seq: s, h: sc.clientHeight, w: sc.clientWidth });
    pendingDy = 0;
  });
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
      sc.addEventListener("scroll", scheduleReport, { passive: true });
      sc.addEventListener("scrollend", () => report(true));
      new ResizeObserver(() => report(true)).observe(sc);
    } else {
      bindOwned(sc);
      new ResizeObserver(() => post("/facts", { h: sc.clientHeight, w: sc.clientWidth })).observe(sc);
    }
  }
  if (waitingFor && ack >= waitingFor) waitingFor = 0;
  if (mode() === "native") requestAnimationFrame(() => { const w = wanted; wanted = false; report(w); });
  document.getElementById("hud").textContent =
    `${mode()} rev ${screen.dataset.revision} reports ${P.reports} last ${P.latencies.length ? P.latencies.at(-1).toFixed(1) : "-"} ms`;
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

// Throwaway prototype client. The browser never scrolls: it turns wheel and
// finger movement into pixel deltas and sends them; the server moves the
// view and streams frames. Deltas add up, so up to three posts may be in
// flight and none has to arrive in order.
const C = document.body.dataset.client;
const MODE = document.body.dataset.mode;
const view = () => document.getElementById("view");
const post = (path, body) => fetch(`${path}?c=${C}`, {
  method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
});

// ---- input ------------------------------------------------------------------
let pending = 0, seq = 0, inFlight = 0;
const unshown = [];        // [seq, dy, sentAt] the server has not shown yet
function add(dy) { pending += dy; preview(); scrolled(); }
function flush() {
  if (pending && inFlight < 3) {
    const s = ++seq, dy = pending;
    pending = 0; inFlight++;
    unshown.push([s, dy, performance.now()]);
    post("/input", { seq: s, dy }).finally(() => { inFlight--; });
  }
  requestAnimationFrame(flush);
}
requestAnimationFrame(flush);

addEventListener("wheel", (e) => {
  e.preventDefault();
  const unit = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? view().clientHeight : 1;
  add(e.deltaY * unit);
}, { passive: false });

// A finger drags the content; when it lifts, a fling keeps sending deltas
// that slow down, as a trackpad's momentum does. This is input, not a guess
// at what the screen will show.
let lastY = null, samples = [], fling = 0;
addEventListener("pointerdown", (e) => {
  if (e.target.closest("#bar")) return;
  if (e.pointerType === "mouse") return;
  cancelAnimationFrame(fling); lastY = e.clientY; samples = [[e.timeStamp, e.clientY]];
});
addEventListener("pointermove", (e) => {
  if (lastY === null) return;
  add(lastY - e.clientY); lastY = e.clientY;
  samples.push([e.timeStamp, e.clientY]);
  while (samples.length > 2 && e.timeStamp - samples[0][0] > 100) samples.shift();
});
addEventListener("pointerup", (e) => {
  if (lastY === null) return;
  lastY = null;
  const [t0, y0] = samples[0], [t1, y1] = samples.at(-1);
  let v = t1 > t0 ? (y0 - y1) / (t1 - t0) : 0;          // px per ms
  let prev = performance.now();
  const step = (now) => {
    const dt = now - prev; prev = now;
    add(v * dt); v *= Math.pow(0.998, dt);
    if (Math.abs(v) > 0.02) fling = requestAnimationFrame(step);
  };
  fling = requestAnimationFrame(step);
});
addEventListener("pointercancel", () => { lastY = null; });

const sendSize = () => post("/input", { w: view().clientWidth, h: view().clientHeight });
addEventListener("resize", sendSize);
sendSize();

// ---- mode c: slide the current frame by input not shown yet ------------------
let remaining = 0;
function preview() {
  if (MODE !== "c") return;
  const ahead = pending + unshown.reduce((sum, [, dy]) => sum + dy, 0) + remaining;
  const p = document.getElementById("preview");
  if (p) p.style.transform = `translateY(${-ahead}px)`;
}

// ---- per frame: what the server has shown, and the numbers in the HUD -------
const latencies = [], frameTimes = [];
function onFrame(frame) {
  const now = performance.now();
  const shown = Number(frame.dataset.input);
  remaining = Number(frame.dataset.remaining) || 0;
  while (unshown.length && unshown[0][0] <= shown) {
    latencies.push(now - unshown.shift()[2]);
    if (latencies.length > 60) latencies.shift();
  }
  glide(now);
  frameTimes.push(now);
  while (frameTimes.length && now - frameTimes[0] > 1000) frameTimes.shift();
  preview();
}
let lastFrame = 0;
new MutationObserver(() => {
  const f = document.getElementById("frame");
  if (f && f.dataset.frame && Number(f.dataset.frame) !== lastFrame) {
    lastFrame = Number(f.dataset.frame);
    onFrame(f);
  }
}).observe(document.body, { subtree: true, attributes: true, attributeFilter: ["data-frame"], childList: true });

const pct = (xs, p) => {
  if (!xs.length) return "-";
  const s = [...xs].sort((a, b) => a - b);
  return Math.round(s[Math.min(s.length - 1, Math.floor(s.length * p))]);
};
setInterval(() => {
  document.getElementById("hud").textContent =
    `${MODE} · ${document.body.dataset.inflight} in flight · ${frameTimes.length} frames/s\ninput→screen ${pct(latencies, 0.5)} / ${pct(latencies, 0.95)} ms (p50/p95)`;
}, 250);

// For checks driven from agent_browser.
window.__proto = { add, latencies, frameTimes };

// ---- the scrollbar ----------------------------------------------------------
// The server draws it. Dragging the thumb previews a thumb under the
// pointer at once and sends "go to this fraction" each animation frame;
// the content follows about one round trip later. A click on the track
// pages up or down.
let drag = null, goTo = null;
const dragThumb = document.getElementById("drag-thumb");
addEventListener("pointerdown", (e) => {
  const bar = e.target.closest("#bar");
  if (!bar) return;
  e.preventDefault();
  const thumb = document.getElementById("thumb");
  const t = thumb.getBoundingClientRect(), b = bar.getBoundingClientRect();
  if (e.clientY < t.top || e.clientY > t.bottom) {      // the track: a page
    add((e.clientY < t.top ? -1 : 1) * 0.9 * view().clientHeight);
    return;
  }
  drag = { grab: e.clientY - t.top, height: t.height, barTop: b.top, barHeight: b.height };
  dragThumb.style.height = `${t.height}px`;
  moveThumb(e.clientY);
  document.body.classList.add("dragging");
}, true);
function moveThumb(y) {
  const room = drag.barHeight - drag.height;
  const top = Math.max(0, Math.min(room, y - drag.grab - drag.barTop));
  dragThumb.style.top = `${drag.barTop + top}px`;
  goTo = room > 0 ? top / room : 0;
  scrolled();
}
addEventListener("pointermove", (e) => { if (drag) moveThumb(e.clientY); }, true);
addEventListener("pointerup", () => {
  if (!drag) return;
  drag = null;
  document.body.classList.remove("dragging");
}, true);
(function sendGoTo() {
  if (goTo !== null && inFlight < 3) {
    const s = ++seq, to = goTo;
    goTo = null; inFlight++;
    unshown.push([s, 0, performance.now()]);
    post("/input", { seq: s, to }).finally(() => { inFlight--; });
  }
  requestAnimationFrame(sendGoTo);
})();

// Phones show the indicator while you scroll.
let hideBar = 0;
function scrolled() {
  document.body.classList.add("scrolling");
  clearTimeout(hideBar);
  hideBar = setTimeout(() => document.body.classList.remove("scrolling"), 800);
}

// ---- glide: animate between the two positions the server sent ---------------
// Not prediction: the page only slides from where the last frame showed a
// block to where the new frame shows it, over about the time between
// frames, so a few frames a second look smooth.
let ref = null;                      // [block id, its top on screen] at the last animation frame
(function watch() {
  if (MODE === "glide") {
    const v = view().getBoundingClientRect();
    const el = [...document.querySelectorAll("#content [data-b]")]
      .find((b) => b.getBoundingClientRect().bottom > v.top);
    ref = el ? [el.id, el.getBoundingClientRect().top] : null;
  }
  requestAnimationFrame(watch);
})();
let lastFrameAt = 0, interval = 100;
function glide(now) {
  if (MODE !== "glide") return;
  if (lastFrameAt) interval = 0.7 * interval + 0.3 * (now - lastFrameAt);
  lastFrameAt = now;
  const p = document.getElementById("preview");
  const el = ref && document.getElementById(ref[0]);
  if (!p || !el) return;
  const current = new DOMMatrix(getComputedStyle(p).transform).m42;     // mid-slide, if any
  const from = ref[1] - (el.getBoundingClientRect().top - current);
  if (Math.abs(from) < 0.5) return;
  p.style.transition = "none";
  p.style.transform = `translateY(${from}px)`;
  p.getBoundingClientRect();                                            // apply before animating
  const ms = Math.round(Math.min(250, Math.max(40, interval)));
  p.style.transition = `transform ${ms}ms linear`;
  p.style.transform = "translateY(0)";
}

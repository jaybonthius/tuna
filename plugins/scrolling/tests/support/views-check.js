// Browser check that each view keeps its place while another view is
// shown in its stead or scrolls beside it. Run it with agent_browser
// `eval --stdin` on a freshly loaded Tuna page started with the demo
// configuration (whose C-c g shows *long*, a line each starting with its
// number). window.__viewsMode chooses the scenario:
// - "tabs" (default): *long* scrolled to 0.4 of its range, a new tab
//   (C-x t 2) on *long* scrolled to 0.2, then ten switches (C-x t o);
// - "split": the view split side by side (C-x 3), the left half at 0.4
//   and the right on *long* at 0.2, then each scrolled by a screen in
//   turn, ten times, while the other is watched.
// After each step it watches the view shown, or the one left alone, on
// every animation frame for 1.5 s: the first line in view, and the
// server's scroll state for it, which every screen carries in the view's
// placement marker (target and offset). A view keeps its place when every
// frame shows the line it showed when last seen, and the server's state
// is the one it had then. Scrolling sets scrollTop, as a drag of the
// browser's scroll bar does. Starts in the background; read
// window.__views once it is not null.
window.__views = null;
(async () => {
  const mode = window.__viewsMode ?? "tabs";
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const frame = () => new Promise((r) => requestAnimationFrame(r));
  const key = (k, ctrl = false) => {
    const code = /^[a-z]$/.test(k) ? "Key" + k.toUpperCase() : /^[0-9]$/.test(k) ? "Digit" + k : "";
    document.dispatchEvent(new KeyboardEvent("keydown", { key: k, code, ctrlKey: ctrl, bubbles: true, cancelable: true }));
  };
  const keys = async (...sequence) => {
    for (const [k, ctrl] of sequence) { key(k, ctrl); await sleep(50); }
  };
  const scrollerOf = (view) => document.querySelector(`[data-view="${view}"] > .buffer`);
  const selected = () => document.querySelector("[data-view][data-selected]")?.dataset.view;
  const firstLine = (sc) => {
    const r = sc.getBoundingClientRect();
    const item = [...sc.querySelectorAll("[data-item]")].find((e) => e.getBoundingClientRect().bottom > r.top + 1);
    return item ? parseInt(item.textContent, 10) : null;
  };
  const serverState = (sc) => {
    const m = sc.querySelector(".placement");
    return `${m?.dataset.target}@${m?.dataset.offset}`;
  };
  // Where VIEW is now: its first line in view and the server's state.
  const place = (view) => {
    const sc = scrollerOf(view);
    return sc ? { line: firstLine(sc), state: serverState(sc) } : null;
  };
  // C-c g, then wait until the selected view shows *long*.
  const showLong = async () => {
    await keys(["c", true], ["g"]);
    for (let k = 0; k < 100 && scrollerOf(selected())?.getAttribute("aria-label") !== "*long*"; k++) await sleep(100);
    await sleep(1000);
  };
  const toFraction = (view, f) => {
    const sc = scrollerOf(view);
    sc.scrollTop = f * (sc.scrollHeight - sc.clientHeight);
  };
  const steps = [];
  // Run ACT, then watch VIEW, expected at EXPECTED, every frame for 1.5 s:
  // the first lines it showed, in order, while it was on the page.
  const step = async (name, view, expected, act) => {
    const lines = [];
    const end = performance.now() + 1500;
    await act();
    while (performance.now() < end) {
      const p = place(view);
      if (p && p.line !== null && lines[lines.length - 1] !== p.line) lines.push(p.line);
      await frame();
    }
    const now = place(view);
    steps.push({ name, view, expected, lines, state: now?.state,
                 kept: lines.every((l) => l === expected.line) && now?.state === expected.state });
    return now;
  };
  try {
    await showLong();
    const first = selected();
    toFraction(first, 0.4);
    await sleep(2500);
    if (mode === "tabs") {
      // Where each view was when it was last shown.
      const places = { [first]: place(first) };
      await keys(["x", true], ["t"], ["2"]);
      await sleep(1500);
      await showLong();
      const second = selected();
      toFraction(second, 0.2);
      await sleep(2500);
      for (let k = 0; k < 10; k++) {
        const to = k % 2 === 0 ? first : second;
        const from = to === first ? second : first;
        places[from] = place(from);
        await step(`switch ${k + 1} to view ${to}`, to, places[to], () => keys(["x", true], ["t"], ["o"]));
      }
    } else {
      await keys(["x", true], ["3"]);
      await sleep(1500);
      const other = [...document.querySelectorAll("[data-view] > .buffer")]
        .map((b) => b.parentElement.dataset.view)
        .find((v) => v !== first && scrollerOf(v).getAttribute("aria-label") === "*long*");
      toFraction(other, 0.2);
      await sleep(2500);
      for (let k = 0; k < 10; k++) {
        const moving = k % 2 === 0 ? first : other;
        const still = moving === first ? other : first;
        await step(`view ${moving} scrolled, view ${still} watched`, still, place(still),
                   async () => { const sc = scrollerOf(moving); sc.scrollTop += sc.clientHeight; });
        await sleep(1000);
      }
    }
    window.__views = { mode, kept: steps.every((s) => s.kept), steps };
  } catch (e) {
    window.__views = { mode, error: String(e), steps };
  }
})();

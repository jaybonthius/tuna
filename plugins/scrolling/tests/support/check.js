// Browser check for scrolling a view, ported from the prototype's
// agents/research/scrolling/proto/check.js. Run it with agent_browser
// `eval --stdin` on a Tuna page whose selected view shows a long buffer
// (the demo's C-c g, *long*, or C-c G, *rows*), scrolled to its start. It
// scrolls the way a person would (long runs down and up, flings, a run
// back to the start) and reports blank frames (no drawn item in view),
// visible jumps (an item in view that did not move by exactly the scroll),
// whether the first item is reachable at the top, and whether the page
// stops reporting when it is left alone. Then it jumps the way a drag of
// the browser's scroll bar does, setting scrollTop to random fractions of
// the scroll range, and reports how long each took to show drawn items
// (a jump lands in a spacer until the server draws there), and whether
// any stayed blank; then two far jumps 5 ms apart, left alone, which must
// show drawn items without further input. It counts scroll reports by
// watching the page's POSTs to /commands. It knows items only by their
// data-item. Starts in the background; read window.__check once it is not
// null. window.__checkSeed seeds the random jumps (default 1).
window.__check = null;
(async () => {
  if (!window.__scrollReports) {
    window.__scrollReports = 0;
    const fetch = window.fetch.bind(window);
    window.fetch = (url, options) => {
      if (url === "/commands" && typeof options?.body === "string" && options.body.includes('"type":"scroll"')) {
        window.__scrollReports++;
      }
      return fetch(url, options);
    };
  }
  const scroller = () => document.querySelector("[data-view][data-selected] > .buffer");
  const frame = () => new Promise((r) => requestAnimationFrame(r));
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const visible = () => {
    const sc = scroller();
    const r = sc.getBoundingClientRect();
    return [...sc.querySelectorAll("[data-item]")].filter((e) => {
      const b = e.getBoundingClientRect();
      return b.bottom > r.top && b.top < r.bottom;
    });
  };
  const firstToken = visible()[0]?.dataset.item;
  // Scroll by D px per frame for N frames. A "jump" is a frame where an
  // item that stayed drawn and should still be in view did not move by
  // exactly the scroll delta; the first few are listed with where they
  // happened. (An item the scroll took out of view may move with what is
  // drawn while only a spacer is in view, which nobody sees.)
  const jumpDetails = [];
  const run = async (d, n, decay = 1, name = "") => {
    let blank = 0, longest = 0, cur = 0, jumps = 0, worst = 0;
    for (let k = 0; k < n; k++) {
      const sc = scroller();
      const v = visible(), probe = v[0], before = probe && probe.getBoundingClientRect().top;
      const top0 = sc.scrollTop;
      sc.scrollBy(0, d);
      const moved = sc.scrollTop - top0;
      d *= decay;
      await frame();
      const view = sc.getBoundingClientRect();
      const expected = probe && before - moved;
      if (probe && probe.isConnected && expected + probe.getBoundingClientRect().height > view.top
          && expected < view.bottom) {
        const dev = Math.abs(probe.getBoundingClientRect().top - expected);
        if (dev > 1) {
          jumps++; worst = Math.max(worst, dev);
          if (jumpDetails.length < 10) {
            jumpDetails.push({ run: name, frame: k, item: probe.dataset.item, px: Math.round(dev),
                               scrollTop: Math.round(sc.scrollTop) });
          }
        }
      }
      if (visible().length === 0) { blank++; cur++; longest = Math.max(longest, cur); } else cur = 0;
    }
    await sleep(1500);
    const v = visible();
    return { frames: n, blank, longestBlank: longest, jumps, worstJumpPx: Math.round(worst),
             settledVisible: v.length, topItem: v[0]?.dataset.item ?? null,
             scrollTop: Math.round(scroller().scrollTop) };
  };
  // Wait up to LIMIT ms for drawn items in view; the ms it took, or null.
  const content = async (limit) => {
    const t0 = performance.now();
    while (performance.now() - t0 < limit) {
      if (visible().length > 0) return Math.round(performance.now() - t0);
      await frame();
    }
    return visible().length > 0 ? Math.round(performance.now() - t0) : null;
  };
  // A small seeded generator, so a run can be repeated.
  let seed = window.__checkSeed ?? 1;
  const random = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
  // N jumps to random fractions of the scroll range, as a drag of the
  // scroll bar makes them; each must show drawn items within 1.5 s and
  // keep showing them for the next 0.5 s.
  const jumps = async (n) => {
    const times = [];
    let stuck = 0, relapses = 0;
    const landed = [];
    for (let k = 0; k < n; k++) {
      const sc = scroller();
      const fraction = random();
      sc.scrollTop = fraction * (sc.scrollHeight - sc.clientHeight);
      const ms = await content(1500);
      if (ms === null) { stuck++; continue; }
      times.push(ms);
      for (let t = performance.now(); performance.now() - t < 500;) {
        await frame();
        if (visible().length === 0) { relapses++; break; }
      }
      if (landed.length < 6) landed.push({ fraction: Math.round(fraction * 1000) / 1000, ms, topItem: visible()[0]?.dataset.item });
    }
    times.sort((a, b) => a - b);
    return { jumps: n, stuck, relapses, medianMs: times[times.length >> 1] ?? null,
             worstMs: times[times.length - 1] ?? null, landed };
  };
  const out = {};
  await sleep(1000);
  out["down 9000px/s"] = await run(150, 300, 1, "down 9000px/s");
  out["down fling 24000px/s decaying"] = await run(400, 200, 0.98, "down fling 24000px/s decaying");
  out["up 9000px/s"] = await run(-150, 600, 1, "up 9000px/s");
  out["up fling to the top"] = await run(-600, 300, 0.995, "up fling to the top");
  out["first item at the top"] = scroller().scrollTop < 1 && visible()[0]?.dataset.item === firstToken;
  if (!out["first item at the top"]) {
    out["at the top instead"] = { scrollTop: scroller().scrollTop, item: visible()[0]?.dataset.item, firstToken };
  }
  out["down again 3000px/s"] = await run(50, 300, 1, "down again 3000px/s");
  // At rest, nothing should be reported.
  let p0 = window.__scrollReports; await sleep(2000);
  out["reports while idle for 2 s"] = window.__scrollReports - p0;
  out["random scroll bar jumps"] = await jumps(20);
  // Two far jumps 5 ms apart, then nothing: drawn items must come.
  {
    const sc = scroller();
    sc.scrollTop = 0.2 * (sc.scrollHeight - sc.clientHeight);
    await sleep(5);
    sc.scrollTop = 0.85 * (sc.scrollHeight - sc.clientHeight);
    const ms = await content(3000);
    out["double jump"] = { ms, topItem: visible()[0]?.dataset.item ?? null };
  }
  await sleep(1500);
  p0 = window.__scrollReports; await sleep(2000);
  out["reports while idle after the jumps"] = window.__scrollReports - p0;
  out["reports in total"] = window.__scrollReports;
  out["jump details"] = jumpDetails;
  window.__check = out;
})();
"started"

// Browser check for scrolling a view, ported from the prototype's
// agents/research/scrolling/proto/check.js. Run it with agent_browser
// `eval --stdin` on a Tuna page whose selected view shows a long buffer
// (the demo's C-c g, *long*, or C-c G, *rows*), scrolled to its start. It
// scrolls the way a person would (long runs down and up, flings, a run
// back to the start) and reports blank frames (no item in view), visible
// jumps (an item in view that did not move by exactly the scroll), whether
// the first item is reachable at the top, and whether the page stops
// reporting when it is left alone. It counts scroll reports by watching
// the page's POSTs to /commands. It knows items only by their data-item.
// Starts in the background; read window.__check once it is not null.
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
  // item that stayed drawn did not move by exactly the scroll delta; the
  // first few are listed with where they happened.
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
      if (probe && probe.isConnected) {
        const dev = Math.abs(probe.getBoundingClientRect().top - (before - moved));
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
  const out = {};
  await sleep(1000);
  out["down 9000px/s"] = await run(150, 300, 1, "down 9000px/s");
  out["down fling 24000px/s decaying"] = await run(400, 200, 0.98, "down fling 24000px/s decaying");
  out["up 9000px/s"] = await run(-150, 600, 1, "up 9000px/s");
  out["up fling to the top"] = await run(-600, 300, 0.995, "up fling to the top");
  out["first item at the top"] = scroller().scrollTop < 1 && visible()[0]?.dataset.item === firstToken;
  out["down again 3000px/s"] = await run(50, 300, 1, "down again 3000px/s");
  // At rest, nothing should be reported.
  const p0 = window.__scrollReports; await sleep(2000);
  out["reports while idle for 2 s"] = window.__scrollReports - p0;
  out["reports in total"] = window.__scrollReports;
  out["jump details"] = jumpDetails;
  window.__check = out;
})();
"started"

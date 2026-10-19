// Browser-side check for the scrolling prototype; run with agent_browser
// `eval --stdin` on an open page. Scrolls the way a person would (long runs
// down and up, flings, scrollbar jumps) and reports blank frames, visible
// jumps, and whether the page settles without posting forever.
// Starts in the background; read window.__check when it is not null.
window.__check = null;
(async () => {
  const sc = document.getElementById("scroller");
  const frame = () => new Promise((r) => requestAnimationFrame(r));
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const posts = async () => (await (await fetch("/stats")).json()).posts;
  const visible = () => {
    const r = sc.getBoundingClientRect();
    return [...sc.querySelectorAll(":scope > [data-i]")].filter((e) => {
      const b = e.getBoundingClientRect();
      return b.bottom > r.top && b.top < r.bottom;
    });
  };
  // Scroll by D px per frame for N frames. A "jump" is a frame where a node
  // that stayed rendered did not move by exactly the scroll delta.
  const run = async (d, n, decay = 1) => {
    let blank = 0, longest = 0, cur = 0, jumps = 0, worst = 0;
    for (let k = 0; k < n; k++) {
      const v = visible(), probe = v[0], before = probe && probe.getBoundingClientRect().top;
      const top0 = sc.scrollTop;
      sc.scrollBy(0, d);
      const moved = sc.scrollTop - top0;
      d *= decay;
      await frame();
      if (probe && probe.isConnected) {
        const dev = Math.abs(probe.getBoundingClientRect().top - (before - moved));
        if (dev > 1) { jumps++; worst = Math.max(worst, dev); }
      }
      if (visible().length === 0) { blank++; cur++; longest = Math.max(longest, cur); } else cur = 0;
    }
    await sleep(1500);
    return { frames: n, blank, longestBlank: longest, jumps, worstJumpPx: Math.round(worst),
             settledVisible: visible().length, scrollTop: Math.round(sc.scrollTop) };
  };
  const out = {};
  await sleep(1000);
  out["down 9000px/s"] = await run(150, 300);
  out["down fling 24000px/s decaying"] = await run(400, 200, 0.98);
  out["up 9000px/s"] = await run(-150, 600);
  out["up fling to the top"] = await run(-600, 300, 0.995);
  out["down again 3000px/s"] = await run(50, 300);
  // Scrollbar jumps to random places.
  const jumps = [];
  for (let k = 0; k < 15; k++) {
    sc.scrollTop = Math.random() * (sc.scrollHeight - sc.clientHeight);
    await sleep(700);
    jumps.push(visible().length);
  }
  out["scrollbar jumps: visible nodes after each"] = jumps.join(",");
  // At rest, nothing should be posted.
  const p0 = await posts(); await sleep(2000);
  out["posts while idle for 2 s"] = (await posts()) - p0;
  window.__check = out;
})();
"started"

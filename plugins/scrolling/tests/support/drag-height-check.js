// Browser check that a view's total scroll height stays the same while
// its scroll bar's thumb is dragged: Chrome on macOS drags the thumb on
// its compositor thread and drops a move whenever the scroller's length
// changed since the last one (ADR 15). Run it with agent_browser
// `eval --stdin` on a Tuna page whose selected view shows a long buffer
// (the demo's C-c g, *long*, or C-c G, *rows*). For each drag in
// window.__dragSteps (default: down from 0, 0.4 and 0.7 by 1/100 of the
// range, and up from 0.9 by two and a half view heights, which outruns
// the two view heights drawn above, so each move lands in the spacer
// above with drawn items still in view) it sets
// scrollTop 30 times, 50 ms apart, as a thumb drag does, and counts how
// often scrollHeight changed: after each move, on every animation frame,
// and after 2 s of rest. Starts in the background; read window.__drag
// once it is not null.
window.__drag = null;
(async () => {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const sc = document.querySelector("[data-view][data-selected] > .buffer");
  const upStep = -2.5 * sc.clientHeight / (sc.scrollHeight - sc.clientHeight);
  const drags = window.__dragSteps ?? [[0, 0.01], [0.4, 0.01], [0.7, 0.01], [0.9, upStep]];
  const results = [];
  for (const [start, step] of drags) {
    sc.scrollTop = start * (sc.scrollHeight - sc.clientHeight);
    await sleep(2000);
    const heights = [sc.scrollHeight];
    let last = sc.scrollHeight;
    let frameChanges = 0;
    let sampling = true;
    const sample = () => {
      if (sc.scrollHeight !== last) { frameChanges++; last = sc.scrollHeight; }
      if (sampling) requestAnimationFrame(sample);
    };
    requestAnimationFrame(sample);
    const range = sc.scrollHeight - sc.clientHeight;
    let top = sc.scrollTop;
    for (let i = 0; i < 30; i++) {
      top += step * range;
      sc.scrollTop = top;
      await sleep(50);
      heights.push(sc.scrollHeight);
    }
    await sleep(2000);
    heights.push(sc.scrollHeight);
    sampling = false;
    let changes = 0;
    for (let i = 1; i < heights.length; i++) if (heights[i] !== heights[i - 1]) changes++;
    results.push({ start, step: Math.round(step * 1e5) / 1e5, changes, frameChanges,
                   min: Math.min(...heights), max: Math.max(...heights) });
  }
  window.__drag = { buffer: sc.getAttribute("aria-label"), width: innerWidth,
                    changes: results.reduce((n, r) => n + r.changes + r.frameChanges, 0), results };
})();

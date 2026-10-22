// Browser check that the server's scroll state matches what the page
// shows after far jumps of the browser's scroll bar. Run it with
// agent_browser `eval --stdin` on a Tuna page whose selected view shows a
// long buffer (the demo's C-c g, *long*, or C-c G, *rows*). It sets
// scrollTop to each of 24 fractions of the scroll range, as a drag of the
// scroll bar does, leaves the view alone for 2.5 s, then compares the
// view's placement marker (the server's scroll item and its offset, which
// every screen carries) with where the page shows that item. Any
// difference means a screen moved what is drawn under the view after the
// page's last report, which nothing corrects until the next scroll: the
// browser's scroll anchoring failed to hold the item in view still. It
// also collects every scrollHeight seen after a jump. Starts in the
// background; read window.__stale once it is not null.
window.__stale = null;
(async () => {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const sc = document.querySelector("[data-view][data-selected] > .buffer");
  const fractions = [0.11, 0.23, 0.37, 0.52, 0.64, 0.71, 0.83, 0.47, 0.29, 0.06, 0.91, 0.58,
                     0.13, 0.27, 0.33, 0.49, 0.61, 0.77, 0.81, 0.42, 0.19, 0.08, 0.88, 0.55];
  const differences = [];
  const heights = new Set();
  for (const f of fractions) {
    sc.scrollTop = f * (sc.scrollHeight - sc.clientHeight);
    await sleep(2500);
    heights.add(sc.scrollHeight);
    const marker = sc.querySelector(".placement");
    const top = sc.getBoundingClientRect().top + sc.clientTop;
    const item = [...sc.querySelectorAll("[data-item]")]
      .find((e) => e.getAttribute("data-item") === marker?.dataset.target);
    differences.push(item ? Math.round((top - item.getBoundingClientRect().top - Number(marker.dataset.offset)) * 10) / 10
                          : "not drawn");
  }
  window.__stale = { buffer: sc.getAttribute("aria-label"), width: innerWidth,
                     stale: differences.filter((d) => d !== 0).length, differences,
                     scrollHeights: [...heights] };
})();

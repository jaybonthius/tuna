import { getPath } from "datastar";

// The terminal plugin's page script: it measures how many cells of each
// terminal fit in the view showing it, and tells the server whenever that
// changes, so the terminal can be sized to the smallest view showing it.
// A terminal's element (data-terminal) holds a hidden run of ten cells
// (.terminal-measure) that gives the cell size; the view's scroller is the
// .buffer around it; data-size is the size the server gave it. When a
// terminal is not the size measured here, which a server that restarted
// or a smaller view elsewhere explains, the same measurements are sent
// again at most once a second.

interface Measured {
  view: number;
  terminal: string;
  columns: number;
  rows: number;
  cellWidth: number;
  cellHeight: number;
}

let last = "";
let lastSent = 0;
let scheduled = false;
const observed = new WeakSet<Element>();
const resizes = new ResizeObserver(schedule);

function measure(element: HTMLElement): Measured | undefined {
  const scroller = element.closest<HTMLElement>(".buffer");
  const view = element.closest<HTMLElement>("[data-view]");
  const probe = element.querySelector<HTMLElement>(".terminal-measure");
  const id = element.dataset.terminal;
  if (!scroller || !view || !probe || !id) return undefined;
  if (!observed.has(scroller)) {
    observed.add(scroller);
    resizes.observe(scroller);
  }
  const cell = probe.getBoundingClientRect();
  const cellWidth = cell.width / 10;
  const cellHeight = cell.height;
  if (cellWidth <= 0 || cellHeight <= 0) return undefined;
  const style = getComputedStyle(scroller);
  const width = scroller.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
  const height = scroller.clientHeight - parseFloat(style.paddingTop) - parseFloat(style.paddingBottom);
  return {
    view: Number(view.dataset.view),
    terminal: id,
    columns: Math.max(1, Math.floor(width / cellWidth)),
    rows: Math.max(1, Math.floor(height / cellHeight)),
    cellWidth: Math.max(1, Math.round(cellWidth)),
    cellHeight: Math.max(1, Math.round(cellHeight)),
  };
}

function report(): void {
  scheduled = false;
  const measured: Measured[] = [];
  let differs = false;
  for (const element of document.querySelectorAll<HTMLElement>("[data-terminal]")) {
    const m = measure(element);
    if (!m) continue;
    measured.push(m);
    if (element.dataset.size !== `${m.columns}x${m.rows}`) differs = true;
  }
  const body = JSON.stringify(measured);
  const now = Date.now();
  if (body === last && !(differs && now - lastSent > 1000)) return;
  last = body;
  lastSent = now;
  void fetch("/plugin/terminals/size", {
    method: "POST",
    headers: { "Tuna-Tab": String(getPath("tab")) },
    body,
  }).catch(() => {
    last = "";
  });
}

function schedule(): void {
  if (scheduled) return;
  scheduled = true;
  requestAnimationFrame(report);
}

new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true });
window.addEventListener("resize", schedule);
schedule();

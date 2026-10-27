import { action, getPath } from "datastar";

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

// The theme's terminal colours, as the browser draws them, so the
// terminal can answer a program that asks (OSC 4, 10, 11, the colour
// scheme): the tokens --terminal-foreground, --terminal-background,
// --terminal-cursor-background and --terminal-color-0 to -255, each
// resolved to #rrggbb through a canvas. Sent at start and whenever the
// stylesheets or the system's light or dark setting change.

interface Colors {
  foreground: string | null;
  background: string | null;
  cursor: string | null;
  palette: (string | null)[];
}

let lastColors = "";
let canvasContext: CanvasRenderingContext2D | null = null;

function hex(color: string): string | null {
  if (canvasContext === null) {
    const canvas = document.createElement("canvas");
    canvas.width = canvas.height = 1;
    canvasContext = canvas.getContext("2d", { willReadFrequently: true });
  }
  const context = canvasContext;
  if (context === null || color === "" || color === "transparent") return null;
  context.clearRect(0, 0, 1, 1);
  context.fillStyle = "#000000";
  context.fillStyle = color;
  context.fillRect(0, 0, 1, 1);
  const [r, g, b, a] = context.getImageData(0, 0, 1, 1).data;
  if (a === 0) return null;
  return "#" + [r, g, b].map((n) => n.toString(16).padStart(2, "0")).join("");
}

function measureColors(): void {
  const terminal = document.querySelector<HTMLElement>("[data-terminal]");
  if (terminal === null) return;
  const probe = document.createElement("span");
  probe.hidden = true;
  terminal.appendChild(probe);
  const resolve = (token: string): string | null => {
    probe.style.color = `var(${token})`;
    return hex(getComputedStyle(probe).color);
  };
  const colors: Colors = {
    foreground: resolve("--terminal-foreground"),
    background: resolve("--terminal-background"),
    cursor: resolve("--terminal-cursor-background"),
    palette: Array.from({ length: 256 }, (_, i) => resolve(`--terminal-color-${i}`)),
  };
  probe.remove();
  const body = JSON.stringify(colors);
  if (body === lastColors) return;
  lastColors = body;
  void fetch("/plugin/terminals/colors", {
    method: "POST",
    headers: { "Tuna-Tab": String(getPath("tab")) },
    body,
  }).catch(() => {
    lastColors = "";
  });
}

let colorsScheduled = false;
function scheduleColors(): void {
  if (colorsScheduled) return;
  colorsScheduled = true;
  requestAnimationFrame(() => {
    colorsScheduled = false;
    measureColors();
  });
}

// A terminal appearing, or the stylesheets in the head changing.
new MutationObserver((records) => {
  if (records.some((r) => r.target === document.head || [...r.addedNodes].some(
    (n) => n instanceof Element && (n.matches("[data-terminal]") || n.querySelector("[data-terminal]") !== null)))) {
    scheduleColors();
  }
}).observe(document.documentElement, { childList: true, subtree: true });
// A stylesheet link finishing loading (load does not bubble, so capture).
document.addEventListener("load", (evt) => { if (evt.target instanceof HTMLLinkElement) scheduleColors(); }, true);
matchMedia("(prefers-color-scheme: dark)").addEventListener("change", scheduleColors);
scheduleColors();

// The mouse over a terminal's rows, as the server marks each terminal
// (data-mouse): "program" or "program-motion" while its program takes
// the mouse, the second when it wants every movement; "select" while a
// press selects text for copy mode; nothing otherwise. Program mode sends
// presses, releases, movements and the wheel to /plugin/terminals/mouse;
// select mode lets the browser select as the pointer drags, then sends
// what it selected (or where it was clicked) and drops the browser's
// selection, since the server shows its own. Either way the page's own
// pointer handling (tunaPointer) does not see these events. A click on a
// link opens it: a web address is a link the browser follows; any other
// goes to /plugin/terminals/link.

interface Place {
  row: number;      // the row's number in the terminal
  column: number;   // cells from the row's start, fractional
  y: number;        // the fraction of the row's height above the pointer
}

function post(name: string, facts: object): void {
  void fetch(`/plugin/terminals/${name}`, {
    method: "POST",
    headers: { "Tuna-Tab": String(getPath("tab")) },
    body: JSON.stringify(facts),
  }).catch(() => undefined);
}

function terminalOf(target: EventTarget | null): HTMLElement | null {
  return target instanceof Element ? target.closest<HTMLElement>("[data-terminal]") : null;
}

function viewOf(element: Element): HTMLElement | null {
  return element.closest<HTMLElement>("[data-view]");
}

function cellWidthOf(terminal: HTMLElement): number {
  const probe = terminal.querySelector<HTMLElement>(".terminal-measure");
  return probe ? probe.getBoundingClientRect().width / 10 : 0;
}

// The row of TERMINAL nearest the point X, Y and where in it the point is.
function placeAt(terminal: HTMLElement, x: number, y: number): Place | null {
  const rows = terminal.querySelectorAll<HTMLElement>(".terminal-row[data-row]");
  if (rows.length === 0) return null;
  let row = rows[0];
  for (const candidate of rows) {
    if (candidate.getBoundingClientRect().top <= y) row = candidate; else break;
  }
  const box = row.getBoundingClientRect();
  const width = cellWidthOf(terminal);
  return {
    row: Number(row.dataset.row),
    column: width > 0 ? Math.max(0, (x - box.left) / width) : 0,
    y: box.height > 0 ? Math.min(0.999, Math.max(0, (y - box.top) / box.height)) : 0,
  };
}

function mods(evt: MouseEvent): { alt: boolean; ctrl: boolean; meta: boolean; shift: boolean } {
  return { alt: evt.altKey, ctrl: evt.ctrlKey, meta: evt.metaKey, shift: evt.shiftKey };
}

const buttonNames = ["left", "middle", "right"] as const;

// Program mode. Movements go one per animation frame, the newest.
let held = 0;
let pendingMotion: object | null = null;
let wheelRest = 0;

function sendProgram(terminal: HTMLElement, kind: string, evt: MouseEvent, button: string | null,
                     count = 1): void {
  const place = placeAt(terminal, evt.clientX, evt.clientY);
  const view = viewOf(terminal);
  if (place === null || view === null) return;
  const facts = {
    terminal: terminal.dataset.terminal, view: Number(view.dataset.view), kind, button, count,
    buttons: evt.buttons, ...place, ...mods(evt),
  };
  if (kind !== "motion") { post("mouse", facts); return; }
  const first = pendingMotion === null;
  pendingMotion = facts;
  if (first) requestAnimationFrame(() => {
    const motion = pendingMotion;
    pendingMotion = null;
    if (motion !== null) post("mouse", motion);
  });
}

// Select mode: whether the view was selected when the press came.
let selectPress: { terminal: HTMLElement; wasSelected: boolean } | null = null;

// Where in its row the caret position NODE, OFFSET is: the row's number
// and the code points before it in the row.
function rowIndex(node: Node, offset: number): { row: number; index: number } | null {
  const element = node instanceof Element ? node : node.parentElement;
  const row = element?.closest<HTMLElement>(".terminal-row[data-row]");
  if (!row) return null;
  const range = document.createRange();
  range.setStart(row, 0);
  range.setEnd(node, offset);
  return { row: Number(row.dataset.row), index: [...range.toString()].length };
}

function finishSelect(evt: MouseEvent): void {
  const press = selectPress;
  selectPress = null;
  if (press === null) return;
  const terminal = press.terminal;
  const view = viewOf(terminal);
  const selection = getSelection();
  let start: { row: number; index: number } | null = null;
  let end: { row: number; index: number } | null = null;
  if (selection !== null && selection.rangeCount > 0 && terminal.contains(selection.anchorNode)) {
    const range = selection.getRangeAt(0);
    start = rowIndex(range.startContainer, range.startOffset);
    end = rowIndex(range.endContainer, range.endOffset);
  }
  if (start === null || end === null) {
    const caret = document.caretPositionFromPoint?.(evt.clientX, evt.clientY);
    const at = caret ? rowIndex(caret.offsetNode, caret.offset) : null;
    if (at === null) return;
    start = end = at;
  }
  if (view === null) return;
  post("select", {
    terminal: terminal.dataset.terminal, view: Number(view.dataset.view), start, end,
    clicks: Math.max(1, evt.detail), wasSelected: press.wasSelected,
  });
  selection?.removeAllRanges();
}

function intercept(evt: MouseEvent): void {
  const terminal = terminalOf(evt.target);
  const mode = terminal?.dataset.mouse ?? "";
  if (terminal === null || terminal === undefined || mode === "") return;
  const onLink = (evt.target as Element).closest("[data-terminal-link]") !== null;
  if (mode.startsWith("program")) {
    if (onLink && evt.button === 0 && (evt.type === "mousedown" || evt.type === "click")) return;
    switch (evt.type) {
      case "mousedown":
        held |= 1 << evt.button;
        sendProgram(terminal, "press", evt, buttonNames[evt.button] ?? null);
        break;
      case "mouseup":
        held &= ~(1 << evt.button);
        sendProgram(terminal, "release", evt, buttonNames[evt.button] ?? null);
        break;
      case "mousemove":
        if (evt.buttons !== 0 || mode === "program-motion") {
          const button = evt.buttons & 1 ? "left" : evt.buttons & 4 ? "middle" : evt.buttons & 2 ? "right" : null;
          sendProgram(terminal, "motion", evt, button);
        }
        return;   // the page's own handling of movement stays
    }
    evt.preventDefault();
    evt.stopPropagation();
    return;
  }
  // Select mode: the left button only, not on a link.
  if (onLink || (evt.button !== 0 && evt.type !== "mousemove")) return;
  switch (evt.type) {
    case "mousedown": {
      const view = viewOf(terminal);
      selectPress = { terminal, wasSelected: view?.hasAttribute("data-selected") ?? false };
      evt.stopPropagation();
      return;
    }
    case "mouseup":
      if (selectPress !== null) {
        evt.stopPropagation();
        // The browser finishes its selection after the event.
        setTimeout(() => finishSelect(evt), 0);
      }
      return;
    case "click":
      evt.stopPropagation();
      return;
  }
}

for (const type of ["mousedown", "mousemove", "mouseup", "click", "auxclick", "contextmenu"]) {
  document.addEventListener(type, (evt) => {
    const terminal = terminalOf(evt.target);
    if (type === "contextmenu" || type === "auxclick") {
      if (terminal?.dataset.mouse?.startsWith("program")) { evt.preventDefault(); evt.stopPropagation(); }
      return;
    }
    intercept(evt as MouseEvent);
  }, true);
}

// The wheel: to the program while it takes the mouse, a press of button
// four (up) or five (down) for each row's height of travel; otherwise the
// view scrolls as any view does.
document.addEventListener("wheel", (evt) => {
  const terminal = terminalOf(evt.target);
  if (!terminal?.dataset.mouse?.startsWith("program")) return;
  evt.preventDefault();
  evt.stopPropagation();
  const row = terminal.querySelector<HTMLElement>(".terminal-row[data-row]");
  const height = row?.getBoundingClientRect().height || 16;
  const pixels = evt.deltaMode === WheelEvent.DOM_DELTA_LINE ? evt.deltaY * height
    : evt.deltaMode === WheelEvent.DOM_DELTA_PAGE ? evt.deltaY * height * 24 : evt.deltaY;
  wheelRest += pixels;
  const rows = Math.trunc(wheelRest / height);
  if (rows === 0) return;
  wheelRest -= rows * height;
  sendProgram(terminal, "press", evt, rows < 0 ? "four" : "five", Math.abs(rows));
}, { capture: true, passive: false });

// A click on a link that is not a web address: the server opens it (a
// file at a line). Web addresses are links the browser follows itself.
document.addEventListener("click", (evt) => {
  const link = evt.target instanceof Element ? evt.target.closest<HTMLElement>("[data-terminal-link]") : null;
  const terminal = terminalOf(evt.target);
  if (link === null || terminal === null || link.tagName === "A" || evt.button !== 0) return;
  evt.preventDefault();
  evt.stopPropagation();
  post("link", { terminal: terminal.dataset.terminal, uri: link.dataset.terminalLink });
}, true);

// The server's instruction to open a web address in a new tab
// (terminalOpen), as a link in a terminal does when a key opened it.
action({
  name: "terminalOpen",
  apply(_: unknown, uri: unknown): void {
    if (typeof uri === "string" && /^https?:\/\//.test(uri)) window.open(uri, "_blank", "noopener,noreferrer");
  },
});

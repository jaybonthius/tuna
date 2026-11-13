import { send } from "tuna";

// Scrolling has come to rest when a view has not moved for restMs. Only
// a report at rest moves the view in the other clients, so a fling moves
// them once. The browser's scrollend fires after each step of a scroll
// made of several, such as each wheel notch, and Safari has had it only
// since 26.2.
const restMs = 200;

// What the browser rounds a line's edge to: a line this far past the
// view's bottom still counts as wholly in view.
const edgeTolerance = 0.5;

// Kept by element, so a view element the morph makes anew is placed
// again.
const views = new WeakMap();
const resting = new WeakMap();
let reports = 0;

function number(element, name) {
  const text = element?.getAttribute(name);
  const value = Number(text);
  return text != null && text !== "" && Number.isFinite(value) ? value : null;
}

function ownLines(view) {
  return Array.from(view.querySelectorAll(".line[data-line]"))
    .filter((line) => line.closest("[data-view]") === view);
}

function runKey(lines) {
  return `${lines[0]?.getAttribute("data-line")} ${lines[lines.length - 1]?.getAttribute("data-line")} ${lines.length}`;
}

function firstEndingBelow(lines, y) {
  let low = 0;
  let high = lines.length;
  while (low < high) {
    const middle = (low + high) >> 1;
    if (lines[middle].getBoundingClientRect().bottom > y) high = middle; else low = middle + 1;
  }
  return low;
}

// One report is on its way per view until a screen brings its number
// back: over a slow link, reports sent faster than screens return would
// queue up and describe the past. A report from a spacer owes another, so
// Tuna learns what the screen it drew there shows. Nothing here moves
// the view: the browser scrolls it, its scroll anchoring holds drawn
// lines still, and only a placement puts it somewhere.
function check(view, reason) {
  const state = views.get(view);
  if (state === undefined) return;
  if (state.sent !== null) {
    if (reason === "rest") { state.owed = true; state.rested = true; }
    return;
  }
  // A view the morph is removing measures all zeros.
  if (!view.isConnected || view.clientHeight === 0) return;
  if (number(view, "data-placement") !== state.placed) return;
  const id = number(view, "data-view");
  if (id === null) return;
  const want = (number(view, "data-drawn-screens") ?? 0) * view.clientHeight;
  const viewTop = view.getBoundingClientRect().top + view.clientTop;
  const viewBottom = viewTop + view.clientHeight;
  const lines = ownLines(view);
  const first = lines[0];
  const last = lines[lines.length - 1];
  const firstTop = first?.getBoundingClientRect().top ?? viewTop;
  const lastBottom = last?.getBoundingClientRect().bottom ?? viewTop;
  const above = Math.max(viewTop - firstTop, 0);
  const below = Math.max(lastBottom - viewBottom, 0);
  const run = runKey(lines);
  // Far more than asked for only counts when a line lies far enough past
  // the edge that drawing fewer leaves enough, and never twice for one
  // run: Tuna draws every line to an end when fewer than the drawn screens
  // would be left there, so asking again would bring the same run back.
  const due = reason !== "moved" || state.owed
    || view.clientWidth !== number(view, "data-measured-width")
    || view.clientHeight !== number(view, "data-measured-height")
    || (above < want / 2 && !view.hasAttribute("data-run-at-start"))
    || (below < want / 2 && !view.hasAttribute("data-run-at-end"))
    || (run !== state.reported
        && ((above > 2 * want && first !== undefined
             && viewTop - first.getBoundingClientRect().bottom > want / 2)
            || (below > 2 * want && last !== undefined
                && last.getBoundingClientRect().top - viewBottom > want / 2)));
  if (!due) return;
  const spacer = first !== undefined && firstTop - viewTop > edgeTolerance
      && view.querySelector(':scope > [data-spacer="above"]')
    ? "above"
    : last !== undefined && viewTop >= lastBottom && view.querySelector(':scope > [data-spacer="below"]')
      ? "below"
      : null;
  const topIndex = spacer === "above" ? 0
    : spacer === "below" ? lines.length - 1
    : Math.min(firstEndingBelow(lines, viewTop), lines.length - 1);
  const lastIndex = firstEndingBelow(lines, viewBottom + edgeTolerance) - 1;
  const lastShown = lines[lastIndex];
  const top = lines[topIndex];
  const measured = {
    type: "scroll",
    view: id,
    placement: state.placed,
    top: number(top, "data-line"),
    offset: top ? viewTop - top.getBoundingClientRect().top : 0,
    lastVisible: spacer === null
      ? number(lines[Math.max(lastIndex, topIndex)], "data-line")
      : lastShown !== undefined && lastShown.getBoundingClientRect().top >= viewTop - edgeTolerance
        ? number(lastShown, "data-line")
        : null,
    spacer,
    spacerDistance: spacer === "above" ? firstTop - viewTop : spacer === "below" ? viewTop - lastBottom : 0,
    before: Math.max(topIndex, 0),
    after: Math.max(lines.length - 1 - topIndex, 0),
    drawnHeight: Math.max(lastBottom - firstTop, 0),
    above,
    below,
    width: view.clientWidth,
    height: view.clientHeight,
    settled: reason === "rest" || state.rested,
  };
  state.owed = spacer !== null;
  state.reported = run;
  state.rested = false;
  if (unchanged(state, measured)) return;
  state.first ??= measured;
  state.last = measured;
  state.sent = ++reports;
  send({ ...measured, report: state.sent });
}

// Each report makes Tuna draw every client again, if only to bring its
// number back, so one that tells Tuna nothing new is not sent. At rest
// only the position is news, as lines drawn since only matter to a view
// still moving: the first report under a placement puts the view in step
// there, and only a report at rest moves the other clients to where a
// report made while scrolling left it.
const position = ["view", "placement", "top", "offset", "spacer", "spacerDistance", "width", "height"];

function unchanged(state, measured) {
  const last = state.last;
  if (last === undefined) return false;
  const keys = measured.settled ? position : Object.keys(measured).filter((key) => key !== "settled");
  if (keys.some((key) => last[key] !== measured[key])) return false;
  return !measured.settled || last.settled || last === state.first;
}

// The offset of a top placement is never all of its line: another client
// measured it, and the line may be shorter here.
function place(view, placement) {
  const target = number(view, "data-place-line");
  const line = target === null ? undefined
    : ownLines(view).find((element) => number(element, "data-line") === target);
  if (line !== undefined) {
    const box = line.getBoundingClientRect();
    const top = box.top - (view.getBoundingClientRect().top + view.clientTop) + view.scrollTop;
    switch (view.getAttribute("data-place-align")) {
      case "center": view.scrollTop = top + box.height / 2 - view.clientHeight / 2; break;
      case "bottom": view.scrollTop = top + box.height - view.clientHeight; break;
      default:
        view.scrollTop = top + Math.min(number(view, "data-place-offset") ?? 0, Math.max(box.height - 1, 0));
    }
  }
  views.set(view, { placed: placement, owed: true, rested: false, reported: null, sent: null });
  check(view, "moved");
}

function screenArrived() {
  for (const view of document.querySelectorAll("[data-view][data-placement]")) {
    const placement = number(view, "data-placement");
    const state = views.get(view);
    if (placement === null) continue;
    if (state === undefined || state.placed !== placement) {
      place(view, placement);
    } else if (state.sent !== null && number(view, "data-reported") === state.sent) {
      state.sent = null;
      check(view, "moved");
    }
  }
}

let scheduled = false;
new MutationObserver(() => {
  if (scheduled) return;
  scheduled = true;
  requestAnimationFrame(() => {
    scheduled = false;
    screenArrived();
  });
}).observe(document.documentElement, {
  subtree: true,
  childList: true,
  attributes: true,
  attributeFilter: ["data-placement", "data-reported"],
});

document.addEventListener("scroll", (event) => {
  const view = event.target;
  if (!(view instanceof Element) || !view.hasAttribute("data-view")) return;
  check(view, "moved");
  clearTimeout(resting.get(view));
  resting.set(view, setTimeout(() => check(view, "rest"), restMs));
}, { capture: true, passive: true });

screenArrived();

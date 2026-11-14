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
      if (!sendMove(view)) check(view, "moved");
    }
  }
}

const scrollers = new WeakMap();
const scrollerResting = new WeakMap();

// What a browser rounds an edge to.
const itemTolerance = 1;

function rowAxis(scroller) {
  return scroller.getAttribute("data-axis") !== "column";
}

function scrollPosition(scroller) {
  return rowAxis(scroller) ? scroller.scrollLeft : scroller.scrollTop;
}

function setScrollPosition(scroller, position) {
  if (rowAxis(scroller)) scroller.scrollLeft = position; else scroller.scrollTop = position;
}

function scrollerLength(scroller) {
  return rowAxis(scroller) ? scroller.clientWidth : scroller.clientHeight;
}

function items(scroller) {
  return Array.from(scroller.children).filter((child) => child.hasAttribute("data-item"));
}

function itemNamed(scroller, name) {
  return name === null ? undefined : items(scroller).find((item) => number(item, "data-item") === name);
}

function edges(scroller, item) {
  const box = scroller.getBoundingClientRect();
  const itemBox = item.getBoundingClientRect();
  const at = scrollPosition(scroller);
  return rowAxis(scroller)
    ? [itemBox.left - box.left - scroller.clientLeft + at, itemBox.right - box.left - scroller.clientLeft + at]
    : [itemBox.top - box.top - scroller.clientTop + at, itemBox.bottom - box.top - scroller.clientTop + at];
}

function wholly(scroller, item, at) {
  const [start, end] = edges(scroller, item);
  return start >= at - itemTolerance && end <= at + scrollerLength(scroller) + itemTolerance;
}

// An item longer than the scroller shows its start, as Niri shows a
// column wider than the screen.
function nearest(scroller, item, at) {
  const [start, end] = edges(scroller, item);
  const length = scrollerLength(scroller);
  if (start >= at - itemTolerance && end <= at + length + itemTolerance) return at;
  if (start < at || end - start > length) return start;
  return end - length;
}

function inView(scroller) {
  const at = scrollPosition(scroller);
  const length = scrollerLength(scroller);
  return items(scroller)
    .filter((item) => {
      const [start, end] = edges(scroller, item);
      return end > at + itemTolerance && start < at + length - itemTolerance;
    })
    .map((item) => number(item, "data-item"));
}

function whollyInView(scroller) {
  const at = scrollPosition(scroller);
  return items(scroller)
    .filter((item) => wholly(scroller, item, at))
    .map((item) => number(item, "data-item"));
}

function placeScroller(scroller, placement) {
  const item = itemNamed(scroller, number(scroller, "data-place-item"));
  const focus = itemNamed(scroller, number(scroller, "data-place-focus"));
  let at = scrollPosition(scroller);
  if (item !== undefined) {
    const [start, end] = edges(scroller, item);
    const length = scrollerLength(scroller);
    switch (scroller.getAttribute("data-place-align")) {
      case "start": at = start; break;
      case "end": at = end - length; break;
      case "center": at = (start + end) / 2 - length / 2; break;
      default: at = nearest(scroller, item, at);
    }
  }
  if (focus !== undefined) at = nearest(scroller, focus, at);
  setScrollPosition(scroller, at);
  scrollers.set(scroller, {
    placed: placement, at: scrollPosition(scroller), gesture: false,
    sent: null, owed: true, reported: null,
  });
  checkScroller(scroller, false);
}

function rest(scroller, state) {
  const at = scrollPosition(scroller);
  const length = scrollerLength(scroller);
  const all = items(scroller);
  let best = null;
  for (const item of all) {
    const [start, end] = edges(scroller, item);
    const candidates = getComputedStyle(item).scrollSnapAlign.includes("center")
      ? [["center", (start + end) / 2 - at - length / 2]]
      : [["start", start - at], ["end", end - at - length]];
    for (const [align, distance] of candidates) {
      if (best === null || Math.abs(distance) < Math.abs(best.distance)) best = { item, align, distance };
    }
  }
  if (best === null) return null;
  let index = all.indexOf(best.item);
  // The furthest item wholly in view in the direction the hand moved, as
  // Niri's view_offset_gesture_end chooses.
  const step = at >= state.at ? 1 : -1;
  if (!wholly(scroller, all[index], at)) {
    const next = all[index + step];
    if (next !== undefined && wholly(scroller, next, at)) index += step;
  }
  while (all[index + step] !== undefined && wholly(scroller, all[index + step], at)) index += step;
  return {
    item: number(best.item, "data-item"),
    align: best.align,
    focus: number(all[index], "data-item"),
  };
}

// As for a view, one report is on its way per scroller until a screen
// brings its number back.
function checkScroller(scroller, resting) {
  const state = scrollers.get(scroller);
  if (state === undefined) return;
  if (state.sent !== null) {
    if (resting) state.owed = "rest";
    else if (state.owed !== "rest") state.owed = true;
    return;
  }
  if (!scroller.isConnected || scrollerLength(scroller) === 0) return;
  if (number(scroller, "data-placement") !== state.placed) return;
  const id = number(scroller, "data-scroller");
  if (id === null) return;
  const shown = inView(scroller);
  const whole = whollyInView(scroller);
  const key = `${shown.join(" ")} | ${whole.join(" ")}`;
  const moved = Math.abs(scrollPosition(scroller) - state.at) > itemTolerance;
  if (resting && !moved) state.gesture = false;
  const settled = (resting || state.owed === "rest") && state.gesture && moved;
  if (!settled && !state.owed && key === state.reported) return;
  const report = { type: "scroller", scroller: id, placement: state.placed, items: shown, whole, settled };
  if (settled) {
    const place = rest(scroller, state);
    if (place === null) return;
    Object.assign(report, place);
    state.at = scrollPosition(scroller);
    state.gesture = false;
  }
  state.owed = false;
  state.reported = key;
  state.sent = ++reports;
  send({ ...report, report: state.sent });
}

function scrollersArrived() {
  for (const scroller of document.querySelectorAll("[data-scroller][data-placement]")) {
    const placement = number(scroller, "data-placement");
    const state = scrollers.get(scroller);
    if (state === undefined || state.placed !== placement) {
      placeScroller(scroller, placement);
    } else if (state.sent !== null && number(scroller, "data-reported") === state.sent) {
      state.sent = null;
      checkScroller(scroller, false);
    }
  }
}

// Only a scroll the hand began moves the focus: a placement, or a
// browser keeping a snap position as the page changes, scrolls too. A
// hand's scroll starts within handMs of its wheel, touch or press.
const handMs = 500;
let handAt = -Infinity;

for (const type of ["wheel", "touchstart", "pointerdown"]) {
  document.addEventListener(type, () => { handAt = performance.now(); }, { capture: true, passive: true });
}

document.addEventListener("scroll", (event) => {
  const scroller = event.target;
  if (!(scroller instanceof Element) || !scroller.hasAttribute("data-scroller")) return;
  const state = scrollers.get(scroller);
  if (state !== undefined && performance.now() - handAt < handMs) state.gesture = true;
  checkScroller(scroller, false);
  clearTimeout(scrollerResting.get(scroller));
  scrollerResting.set(scroller, setTimeout(() => checkScroller(scroller, true), restMs));
}, { capture: true, passive: true });

// The server draws each line's piece of the region as one box behind
// its text, which cannot follow a piece that wraps onto several visual
// lines, so such a piece falls back to an inline background.
function markWrappedRegions() {
  for (const region of document.querySelectorAll(".view .region")) {
    region.classList.toggle("wrapped", region.getClientRects().length > 1);
  }
}

let scheduled = false;
new MutationObserver(() => {
  if (scheduled) return;
  scheduled = true;
  requestAnimationFrame(() => {
    scheduled = false;
    screenArrived();
    scrollersArrived();
    markWrappedRegions();
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
scrollersArrived();
markWrappedRegions();

const dragThreshold = 3;
let press = null;
let cancelClick = false;

function caretAt(x, y) {
  if (typeof document.caretPositionFromPoint === "function") {
    const caret = document.caretPositionFromPoint(x, y);
    return caret && { node: caret.offsetNode, offset: caret.offset };
  }
  if (typeof document.caretRangeFromPoint === "function") {
    const range = document.caretRangeFromPoint(x, y);
    return range && { node: range.startContainer, offset: range.startOffset };
  }
  return null;
}

function elementOf(node) {
  return node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
}

function markedAncestor(element, view, token) {
  for (let e = element; e !== null && e !== view; e = e.parentElement) {
    if (e.hasAttribute("data-to")) return e;
    if (!token && (e.hasAttribute("data-at") || e.hasAttribute("data-line"))) return e;
  }
  return null;
}

function codePoints(text) {
  let n = 0;
  for (const _ of text) n++;
  return n;
}

// Tuna draws marks only where a line's characters stop being the
// buffer's next tokens: past an element that stands for tokens, the
// count starts again after them.
function placeIn(marked, node, offset) {
  if (marked.hasAttribute("data-to")) return { token: number(marked, "data-at") };
  let at = number(marked, "data-at");
  let count = 0;
  let done = false;
  const visit = (n) => {
    if (n === node) {
      if (n.nodeType === Node.TEXT_NODE) count += codePoints(n.data.slice(0, offset));
      else for (let i = 0; i < offset && i < n.childNodes.length && !done; i++) visit(n.childNodes[i]);
      done = true;
    } else if (n.nodeType === Node.TEXT_NODE) {
      count += codePoints(n.data);
    } else if (n.nodeType === Node.ELEMENT_NODE) {
      if (n !== marked && n.hasAttribute("data-to")) {
        at = number(n, "data-to");
        count = 0;
      } else {
        for (const child of n.childNodes) {
          visit(child);
          if (done) return;
        }
      }
    }
  };
  visit(marked);
  return at !== null ? { at, count } : { line: number(marked, "data-line"), count };
}

function lineAbove(view, y) {
  const lines = ownLines(view);
  const i = firstEndingBelow(lines, y);
  if (i < lines.length && lines[i].getBoundingClientRect().top <= y) return lines[i];
  return i > 0 ? lines[i - 1] : null;
}

function placeOf(view, target, x, y) {
  const caret = caretAt(x, y);
  const caretElement = caret && elementOf(caret.node);
  const inView = caretElement !== null && caretElement !== undefined
    && caretElement.closest("[data-view]") === view;
  const token = target instanceof Element ? markedAncestor(target, view, true) : null;
  if (token !== null && !(inView && token.contains(caretElement))) return placeIn(token);
  if (inView) {
    const marked = markedAncestor(caretElement, view, false);
    const line = caretElement.closest(".line");
    if (marked !== null && !(line !== null && view.contains(line) && y > line.getBoundingClientRect().bottom)) {
      return placeIn(marked, caret.node, caret.offset);
    }
  }
  const line = lineAbove(view, y);
  return line === null ? null : placeIn(line, line, line.childNodes.length);
}

function modifierNames(event) {
  const names = [];
  if (event.ctrlKey) names.push("control");
  if (event.altKey) names.push("alt");
  if (event.shiftKey) names.push("shift");
  if (event.metaKey) names.push("super");
  return names;
}

function sendMouse(view, action, place, extra) {
  const version = number(view, "data-version");
  const showing = number(view, "data-showing");
  const id = number(view, "data-view");
  if (version === null || showing === null || id === null) return;
  send({ type: "mouse", action, button: 1, view: id, version, showing, ...place, ...extra });
}

function sendMove(view) {
  const p = press;
  if (p === null || p.view !== view || p.pending === null) return false;
  const state = views.get(view);
  if (state === undefined || state.sent !== null) return false;
  const { x, y, target } = p.pending;
  p.pending = null;
  if (!(target instanceof Element) || target.closest("[data-view]") !== view) return false;
  const place = placeOf(view, target, x, y);
  if (place === null) return false;
  state.sent = ++reports;
  sendMouse(view, "move", place, { modifiers: [], report: state.sent });
  return true;
}

function release(event) {
  const p = press;
  press = null;
  cancelClick = true;
  const inView = event.target instanceof Element && event.target.closest("[data-view]") === p.view;
  const place = inView ? placeOf(p.view, event.target, event.clientX, event.clientY) : null;
  sendMouse(p.view, p.dragging ? "drag" : "click", place ?? {},
    { clicks: p.clicks, modifiers: modifierNames(event) });
}

// The right button stays the browser's, and a press on a view's scroll
// bar scrolls it. Taking the press keeps the browser from selecting text
// and the keyboard focus where it is.
document.addEventListener("mousedown", (event) => {
  cancelClick = false;
  if (event.button !== 0 || !(event.target instanceof Element)) return;
  const view = event.target.closest("[data-view]");
  if (view === null) return;
  if (view.hasAttribute("data-placement")) {
    const box = view.getBoundingClientRect();
    if (event.clientX - box.left - view.clientLeft >= view.clientWidth
        || event.clientY - box.top - view.clientTop >= view.clientHeight) return;
  }
  event.preventDefault();
  const clicks = Math.min(Math.max(event.detail, 1), 3);
  press = { view, x: event.clientX, y: event.clientY, clicks, dragging: false, pending: null };
  sendMouse(view, "down", placeOf(view, event.target, event.clientX, event.clientY) ?? {},
    { clicks, modifiers: modifierNames(event) });
}, true);

// A release outside the window sends no mouseup, so a move with the
// button up ends the press.
window.addEventListener("mousemove", (event) => {
  const p = press;
  if (p === null) return;
  if ((event.buttons & 1) === 0) {
    release(event);
    return;
  }
  if (!p.dragging && Math.hypot(event.clientX - p.x, event.clientY - p.y) <= dragThreshold) return;
  p.dragging = true;
  p.pending = { x: event.clientX, y: event.clientY, target: event.target };
  sendMove(p.view);
}, { passive: true });

window.addEventListener("mouseup", (event) => {
  if (event.button === 0 && press !== null) release(event);
}, true);

window.addEventListener("click", (event) => {
  if (!cancelClick || event.button !== 0) return;
  cancelClick = false;
  event.preventDefault();
  event.stopPropagation();
}, true);

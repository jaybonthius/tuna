import { send } from "tuna";

const { number, box, items: viewItems, place, lineHeight } = window.tunaViews;

// Scrolling has come to rest when a view has not moved for restMs. Only
// a report at rest moves the view in the other clients, so a fling moves
// them once. The browser's scrollend fires after each step of a scroll
// made of several, such as each wheel notch, and Safari has had it only
// since 26.2.
const restMs = 200;

// What the browser rounds an edge to.
const edgeTolerance = 0.5;

// Kept by element, so a view element the morph makes anew is placed
// again.
const views = new WeakMap();
let reports = 0;

function ownLines(view) {
  return Array.from(view.querySelectorAll(".line[data-line]"))
    .filter((line) => line.closest("[data-view]") === view);
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

function mark(item) {
  const at = number(item, "data-at");
  return at !== null ? { at } : { line: number(item, "data-line") };
}

// A browser's own measure of a character, for the server's estimate of
// how many fit a row of wrapped text.
const canvas = document.createElement("canvas").getContext("2d");

function charWidth(view) {
  canvas.font = getComputedStyle(view).font;
  return canvas.measureText("0".repeat(10)).width / 10 || 8;
}

// The view's padding holds no text, so the size reported is its content
// box, where rows wrap.
function contentSize(view) {
  const style = getComputedStyle(view);
  const inline = parseFloat(style.paddingInlineStart) + parseFloat(style.paddingInlineEnd);
  const block = parseFloat(style.paddingBlockStart) + parseFloat(style.paddingBlockEnd);
  return {
    width: Math.max(0, Math.floor(view.clientWidth - inline)),
    height: Math.max(0, Math.floor(view.clientHeight - block)),
  };
}

// An item taller than the view that crosses its bottom ends there with
// its end.
function placesInView(view, boxes, all, viewTop, viewBottom) {
  const height = view.clientHeight;
  const lh = lineHeight(view);
  const margin = Math.min((number(view, "data-scroll-margin") ?? 0) * lh, height / 4);
  const x = view.getBoundingClientRect().left + view.clientLeft + 2;
  const rowY = (i, y, down) => {
    if (i < 0 || !all[i].classList.contains("line")) return y;
    const rows = (y - boxes[i].top) / lh;
    return boxes[i].top + (down ? Math.ceil(rows - 0.01) : Math.floor(rows + 0.01)) * lh + (down ? lh / 2 : -lh / 2);
  };
  const at = (y) => {
    const target = document.elementFromPoint(x, y);
    return target && view.contains(target) ? placeOf(view, target, x, y) : null;
  };
  // A whole item cut at an edge has no place wholly in view unless it is
  // taller than the room, so the place is in the item next to it.
  const room = height - 2 * margin;
  const cut = (i, top) => all[i].classList.contains("whole") && boxes[i].height <= room
    && (top ? boxes[i].top < viewTop + margin - edgeTolerance : boxes[i].bottom > viewBottom - margin + edgeTolerance);
  let first = boxes.findIndex((b) => b.bottom > viewTop + margin + edgeTolerance);
  if (first >= 0 && cut(first, true) && first + 1 < boxes.length) first += 1;
  let last = -1;
  for (let i = 0; i < boxes.length; i++) if (boxes[i].top < viewBottom - margin - edgeTolerance) last = i;
  if (last >= 0 && cut(last, false) && last > 0) last -= 1;
  const start = first < 0 ? null
    : at(Math.min(rowY(first, Math.max(viewTop + margin, boxes[first].top + 1), true), viewBottom - 1));
  let end = last < 0 ? null
    : at(Math.max(rowY(last, Math.min(viewBottom - margin, boxes[last].bottom - 1), false), viewTop + 1));
  if (last >= 0 && all[last].classList.contains("whole")) {
    const to = number(all[last], "data-to");
    if (to !== null) end = { at: to, count: 0 };
  }
  return { start, end };
}

// An item drawn as nothing, as an empty segment hidden by its style,
// has no box and is left out.
function measure(view) {
  const drawn = viewItems(view).map((item) => [item, box(item)]).filter(([item, b]) => b !== null);
  const all = drawn.map(([item]) => item);
  const viewTop = view.getBoundingClientRect().top + view.clientTop;
  const viewBottom = viewTop + view.clientHeight;
  const boxes = drawn.map(([item, b]) => ({ top: b.top, bottom: b.bottom, height: b.height }));
  const advances = boxes.map((b, i) => (i + 1 < boxes.length ? boxes[i + 1].top - b.top : b.height));
  const firstTop = boxes[0]?.top ?? viewTop;
  const lastBottom = boxes.length ? boxes[boxes.length - 1].bottom : viewTop;
  const spacer = boxes.length && firstTop - viewTop > edgeTolerance && view.querySelector(':scope > [data-spacer="above"]')
    ? "above"
    : boxes.length && viewTop >= lastBottom && view.querySelector(':scope > [data-spacer="below"]') ? "below" : null;
  const topIndex = spacer === null ? boxes.findIndex((b) => b.bottom > viewTop) : -1;
  const top = topIndex >= 0 ? all[topIndex] : null;
  return {
    all, boxes, viewTop, viewBottom, spacer,
    top: top ? mark(top) : null,
    offset: top ? viewTop - boxes[topIndex].top : 0,
    itemHeight: top ? boxes[topIndex].height : 0,
    spacerDistance: spacer === "above" ? firstTop - viewTop : spacer === "below" ? viewTop - lastBottom : 0,
    above: Math.max(viewTop - firstTop, 0),
    below: Math.max(lastBottom - viewBottom, 0),
    items: all.map((item, i) => [mark(item), Math.max(advances[i], 0)]),
    run: all.length ? `${all[0].id} ${all[all.length - 1].id} ${all.length}` : "",
  };
}

// One report is on its way per view until a screen brings its number
// back: over a slow link, reports sent faster than screens return would
// queue up and describe the past. A report from a spacer owes another,
// so Tuna learns what the screen it drew there shows. Nothing here moves
// the view: the browser scrolls it, its scroll anchoring holds what is
// in view still, and only a placement puts it somewhere.
function check(view, reason) {
  const state = views.get(view);
  if (state === undefined) return;
  if (reason === "resized") state.resized = true;
  const resting = reason === "rest" || reason === "flush";
  if (state.sent !== null && reason !== "flush") {
    if (resting) { state.owed = true; state.rested = true; }
    return;
  }
  // A view the morph is removing measures all zeros.
  if (!view.isConnected || view.clientHeight === 0) return;
  if (number(view, "data-placement") !== state.placed) return;
  const id = number(view, "data-view");
  if (id === null) return;
  const m = measure(view);
  const want = (number(view, "data-drawn-screens") ?? 0) * view.clientHeight;
  // Far more than asked for only counts when an item lies wholly past
  // twice it, and never twice for one run: Tuna draws every item to an
  // end when fewer than the drawn screens would be left there, so asking
  // again would bring the same run back.
  const first = m.boxes[0];
  const last = m.boxes[m.boxes.length - 1];
  const due = resting || state.owed || state.resized
    || (m.above < want / 2 && !view.hasAttribute("data-run-at-start"))
    || (m.below < want / 2 && !view.hasAttribute("data-run-at-end"))
    || (m.run !== state.reported
        && ((first !== undefined && first.bottom < m.viewTop - 2 * want)
            || (last !== undefined && last.top > m.viewBottom + 2 * want)));
  if (!due) return;
  const { start, end } = placesInView(view, m.boxes, m.all, m.viewTop, m.viewBottom);
  const { width, height } = contentSize(view);
  const report = {
    type: "scroll",
    view: id,
    placement: state.placed,
    version: number(view, "data-version"),
    top: m.top,
    offset: m.offset,
    itemHeight: m.itemHeight,
    left: view.classList.contains("nowrap") ? view.scrollLeft : 0,
    start,
    end,
    spacer: m.spacer,
    spacerDistance: m.spacerDistance,
    below: m.below,
    items: m.items,
    lineHeight: lineHeight(view),
    charWidth: charWidth(view),
    width,
    height,
    settled: resting || state.rested,
    hand: state.hand,
    runAtEnd: view.hasAttribute("data-run-at-end"),
  };
  state.owed = m.spacer !== null;
  state.resized = false;
  state.reported = m.run;
  state.rested = false;
  if (unchanged(state, report)) return;
  if (report.settled) state.hand = false;
  state.first ??= report;
  state.last = report;
  state.sent = ++reports;
  send({ ...report, report: state.sent });
}

// Each report makes Tuna draw every client again, if only to bring its
// number back, so one that tells Tuna nothing new is not sent. At rest
// only the position is news, as items measured since only matter to a
// view still moving: the first report under a placement puts the view in
// step there, and only a report at rest moves the other clients to where
// a report made while scrolling left it.
const position = ["view", "placement", "version", "top", "offset", "left", "spacer", "spacerDistance", "width", "height"];

// The browser holding its anchor as items above change size moves the
// view by fractions of a pixel, which is no news.
function same(a, b) {
  return typeof a === "number" && typeof b === "number" ? Math.abs(a - b) < 1 : JSON.stringify(a) === JSON.stringify(b);
}

function unchanged(state, report) {
  const last = state.last;
  if (last === undefined) return false;
  const keys = report.settled ? position : Object.keys(report).filter((key) => key !== "settled" && key !== "hand");
  if (keys.some((key) => !same(last[key], report[key]))) return false;
  return !report.settled || last.settled || last === state.first;
}

// Items change size without an edit, as an image decodes, fonts load or
// a theme changes, and the server learns their size only from a report.
const itemOwners = new WeakMap();
const itemSizes = new ResizeObserver((entries) => {
  const seen = new Set();
  for (const entry of entries) {
    if (!entry.target.isConnected) {
      itemSizes.unobserve(entry.target);
      continue;
    }
    const view = itemOwners.get(entry.target);
    if (view === undefined || seen.has(view)) continue;
    seen.add(view);
    check(view, "resized");
    awaitRest(view);
  }
});

const viewSizes = new ResizeObserver((entries) => {
  for (const entry of entries) {
    if (entry.target.isConnected) check(entry.target, "resized");
    else viewSizes.unobserve(entry.target);
  }
});

// An observer may hold its targets strongly, so items that leave the
// view are let go; a removed target is let go when the observer reports
// its size going to zero.
function observeItems(view, state) {
  const observed = new Set();
  for (const item of viewItems(view)) {
    const targets = item.classList.contains("whole") ? Array.from(item.children) : [item];
    for (const target of targets) {
      observed.add(target);
      if (state.observed.delete(target)) continue;
      itemOwners.set(target, view);
      itemSizes.observe(target);
    }
  }
  for (const target of state.observed) itemSizes.unobserve(target);
  state.observed = observed;
}

function newState(placement) {
  return { placed: placement, owed: true, rested: false, resized: false, reported: null, sent: null, hand: false,
           timer: null, at: 0, left: 0, placing: null, observed: new Set() };
}

function placed(view, state, fresh) {
  const moved = place(view, fresh);
  state.at = view.scrollTop;
  state.left = view.scrollLeft;
  state.placing = moved ? view.scrollTop : null;
  return moved;
}

// A report is owed after a placement only if it moved the view or the
// element is new, so following point when it is in view costs nothing.
function screenArrived() {
  for (const view of document.querySelectorAll(".view[data-placement]")) {
    const placement = number(view, "data-placement");
    if (placement === null) continue;
    let state = views.get(view);
    if (state === undefined) {
      state = newState(placement);
      views.set(view, state);
      if (view.tunaPlaced !== placement) placed(view, state, true);
      state.at = view.scrollTop;
      state.left = view.scrollLeft;
      viewSizes.observe(view);
      observeItems(view, state);
      check(view, "placed");
    } else if (state.placed !== placement) {
      state.placed = placement;
      state.sent = null;
      state.hand = false;
      state.owed = placed(view, state, false);
      observeItems(view, state);
      check(view, "placed");
    } else {
      observeItems(view, state);
      if (state.sent !== null && number(view, "data-reported") === state.sent) {
        state.sent = null;
        if (!sendMove(view)) check(view, "moved");
      }
    }
  }
}

function awaitRest(view) {
  const state = views.get(view);
  if (state === undefined) return;
  clearTimeout(state.timer);
  state.timer = setTimeout(() => {
    state.timer = null;
    if (pressed === view) return;
    check(view, "rest");
  }, restMs);
}

// Rest waits while a pointer is down in the view, so a scroll bar thumb
// held still mid-drag does not change the total height under it.
let pressed = null;

document.addEventListener("pointerup", () => {
  const view = pressed;
  pressed = null;
  if (view !== null) awaitRest(view);
}, { capture: true, passive: true });

document.addEventListener("pointercancel", () => { pressed = null; }, { capture: true, passive: true });

// A key or click may make the view element anew, as a tab switch does,
// and the new element is placed where the last report left it, so a
// scroll waiting for rest is reported first, even past one in flight,
// whose screen the element may not live to see.
function flush(event) {
  for (const view of document.querySelectorAll(".view[data-placement]")) {
    const state = views.get(view);
    if (state !== undefined && state.timer !== null) {
      clearTimeout(state.timer);
      state.timer = null;
      check(view, "flush");
    }
  }
  if (event.type === "pointerdown" && event.target instanceof Element) {
    const view = event.target.closest(".view[data-placement]");
    if (view !== null) pressed = view;
  }
}

document.addEventListener("keydown", flush, { capture: true });
document.addEventListener("pointerdown", flush, { capture: true, passive: true });

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

// Only a scroll the hand began moves the focus or, at rest, the view in
// the other clients: a placement, or a browser holding its scroll anchor
// or a snap position as the page changes, scrolls too. A hand's scroll
// starts within handMs of its wheel, touch or press.
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

// Datastar moves a kept element with insertBefore where the browser has
// no moveBefore, which resets its scroll offsets; the element's own are
// restored before the frame paints.
function restoreMoved(records) {
  for (const record of records) {
    for (const node of record.addedNodes) {
      if (!(node instanceof Element)) continue;
      const found = node.matches(".view[data-placement]") ? [node] : node.querySelectorAll(".view[data-placement]");
      for (const view of found) {
        const state = views.get(view);
        if (state !== undefined && (Math.abs(view.scrollTop - state.at) > edgeTolerance
                                    || Math.abs(view.scrollLeft - state.left) > edgeTolerance)) {
          view.scrollTop = state.at;
          view.scrollLeft = state.left;
        }
      }
    }
  }
}

let scheduled = false;
new MutationObserver((records) => {
  restoreMoved(records);
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
  if (!(view instanceof Element) || !view.hasAttribute("data-placement")) return;
  const state = views.get(view);
  if (state === undefined) return;
  if (state.placing !== null && Math.abs(view.scrollTop - state.placing) <= edgeTolerance) {
    state.placing = null;
  } else if (performance.now() - handAt < handMs) {
    state.hand = true;
  }
  state.at = view.scrollTop;
  state.left = view.scrollLeft;
  check(view, "moved");
  awaitRest(view);
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

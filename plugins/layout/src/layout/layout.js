import { define } from "tuna";
import { dragThreshold } from "views";

// Tuna asks about a press a round trip after it, so the page records
// each press on an edge a container kind drags, and the pointer's moves
// and release meanwhile are not lost. Not every press asks: a double
// click's second press does not, nor a press on an edge that cannot
// move, whose element a later screen may give to another edge. So a
// question is matched to the newest press on its edge with as many
// clicks, and the presses before it are dropped.
let presses = [];
const edges = [];
let pointer = { type: "mouse", id: null };
let drag = null;
let kept = null;

export function dragEdges(selector) {
  edges.push(selector);
}

document.addEventListener("pointerdown", (event) => {
  pointer = { type: event.pointerType, id: event.pointerId };
}, true);

document.addEventListener("mousedown", (event) => {
  if (event.button !== 0 || pointer.type === "touch" || edges.length === 0 || !(event.target instanceof Element)) return;
  const edge = event.target.closest(edges.join(","));
  if (edge === null) return;
  presses.push({ edge, clicks: event.detail, pointerId: pointer.id, x0: event.clientX, y0: event.clientY,
                 x: event.clientX, y: event.clientY, moved: false, down: true });
}, true);

// A press asked about leaves the list, as the drag's.
function pressOf(pointerId) {
  if (drag !== null && drag.press.down && drag.press.pointerId === pointerId) return drag.press;
  return presses.find((press) => press.down && press.pointerId === pointerId);
}

// Views takes a release within the threshold for a click, so a drag that
// stores nothing below it leaves no edit for that click to find stale.
function moveTo(press, event) {
  press.x = event.clientX;
  press.y = event.clientY;
  if (Math.hypot(press.x - press.x0, press.y - press.y0) > dragThreshold) press.moved = true;
}

function released(event) {
  const press = pressOf(event.pointerId);
  if (press === undefined) return;
  moveTo(press, event);
  press.down = false;
  if (drag !== null && drag.press === press) {
    follow(drag);
    finish(drag);
  }
}

window.addEventListener("pointermove", (event) => {
  const press = pressOf(event.pointerId);
  if (press === undefined) return;
  if ((event.buttons & 1) === 0) {
    released(event);
    return;
  }
  moveTo(press, event);
  if (drag !== null && drag.press === press) follow(drag);
}, { passive: true });

window.addEventListener("pointerup", released, true);
window.addEventListener("pointercancel", released, true);
window.addEventListener("blur", () => {
  for (const press of presses) press.down = false;
  if (drag !== null) finish(drag);
});

export function pressFor(question) {
  const i = presses.findLastIndex((press) => press.clicks === question.clicks && press.edge.isConnected
                                            && press.edge.getAttribute("data-at") === String(question.at));
  if (i < 0) return null;
  const press = presses[i];
  presses = presses.slice(i + 1);
  return press;
}

// The length of the content box, which the sizes Tuna draws set; a
// part after the first has a rule along its edge.
export function lengthOf(element, axis) {
  const box = element.getBoundingClientRect();
  const style = getComputedStyle(element);
  return axis === "row"
    ? box.width - parseFloat(style.borderLeftWidth) - parseFloat(style.borderRightWidth)
    : box.height - parseFloat(style.borderTopWidth) - parseFloat(style.borderBottomWidth);
}

export function cellOf(element, axis) {
  return parseFloat(getComputedStyle(element).getPropertyValue(axis === "row" ? "--layout-cell-width" : "--layout-cell-height"));
}

function written(d, part) {
  const length = d.lengths.get(part);
  return length === undefined ? null : d.value(length);
}

function write(d) {
  for (const part of d.parts) {
    const value = written(d, part) ?? part.drawn;
    if (part.element.style.getPropertyValue(d.property).trim() !== value) part.element.style.setProperty(d.property, value);
  }
}

function follow(d) {
  const { press } = d;
  if (!press.moved) return;
  d.lengths = d.lengthsAt(press.x - press.x0, press.y - press.y0);
  write(d);
}

function connected(d) {
  return d.press.edge.isConnected && d.parts.every((part) => part.element.isConnected);
}

function putBack(d) {
  d.observer.disconnect();
  if (d.press.edge.hasPointerCapture(d.press.pointerId)) d.press.edge.releasePointerCapture(d.press.pointerId);
  d.holding(false);
  for (const part of d.parts) {
    const value = written(d, part);
    if (value !== null && part.element.style.getPropertyValue(d.property).trim() === value) {
      part.element.style.setProperty(d.property, part.drawn);
    }
  }
}

function finish(d) {
  drag = null;
  d.holding(false);
  const changes = d.parts.filter((part) => d.lengths.has(part) && d.lengths.get(part) !== part.length)
                         .map((part) => ({ index: part.index, old: part.length, new: d.lengths.get(part) }));
  if (changes.length === 0) {
    putBack(d);
    d.answer([]);
    return;
  }
  kept = d;
  d.answer(changes);
}

// A screen drawn before Tuna stores the lengths brings the values drawn
// before the drag, so the lengths are written again until a screen
// brings the stored ones; every part changed gets a new value then. What
// a screen brings is kept, so a refusal puts back the newest values.
function patched(d) {
  if (!connected(d)) {
    d.observer.disconnect();
    if (drag === d) {
      drag = null;
      d.holding(false);
      d.answer(null);
    } else if (kept === d) {
      kept = null;
    }
    return;
  }
  for (const part of d.parts) {
    const value = part.element.style.getPropertyValue(d.property).trim();
    if (value !== written(d, part)) part.drawn = value;
  }
  if (kept === d && d.parts.some((part) => d.lengths.has(part) && part.drawn !== part.before)) {
    kept = null;
    d.observer.disconnect();
    return;
  }
  if (drag === d) d.holding(true);
  write(d);
}

export function followEdge(press, { parts, property, value, lengthsAt, holding = () => {} }) {
  return new Promise((answer) => {
    for (const part of parts) {
      part.before = part.element.style.getPropertyValue(property).trim();
      part.drawn = part.before;
    }
    const d = { press, parts, property, value, lengthsAt, holding, answer, lengths: new Map(), observer: null };
    d.observer = new MutationObserver(() => patched(d));
    d.observer.observe(press.edge.parentElement.parentElement, { childList: true, attributes: true, attributeFilter: ["style"] });
    for (const part of parts) d.observer.observe(part.element, { childList: true, attributes: true, attributeFilter: ["style"] });
    drag = d;
    holding(true);
    follow(d);
    if (press.down) press.edge.setPointerCapture(press.pointerId);
    else finish(d);
  });
}

define("layout-drag-restore", () => {
  for (const d of [drag, kept]) {
    if (d === null) continue;
    putBack(d);
    if (d === drag) d.answer(null);
  }
  drag = null;
  kept = null;
});

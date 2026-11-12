import { send } from "tuna";

// Scrolling has come to rest when a view has not moved for restMs. The
// browser's scrollend fires after each step of a scroll made of several,
// such as each wheel notch, and Safari has had it only since 26.2.
const restMs = 200;

// What the browser rounds a line's edge to: a line this far past the
// view's bottom still counts as wholly in view.
const edgeTolerance = 0.5;

const applied = new Map();
const resting = new WeakMap();

function number(element, name) {
  const value = Number(element?.getAttribute(name));
  return element?.hasAttribute(name) && Number.isFinite(value) ? value : null;
}

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

// Lines past the drawn ones are counted across the spacer at the lines'
// average height, from the drawn line nearest the edge, so no estimate
// of everything above adds up.
function report(view) {
  const id = number(view, "data-view");
  const lines = ownLines(view);
  if (id === null || lines.length === 0 || view.clientHeight === 0) return;
  const viewTop = view.getBoundingClientRect().top + view.clientTop;
  const viewBottom = viewTop + view.clientHeight;
  const firstBox = lines[0].getBoundingClientRect();
  const lastBox = lines[lines.length - 1].getBoundingClientRect();
  const height = Math.max((lastBox.bottom - firstBox.top) / lines.length, 1);
  let top;
  let offset;
  let last;
  if (firstBox.top - viewTop > edgeTolerance) {
    const distance = firstBox.top - viewTop;
    const steps = Math.ceil(distance / height);
    top = number(lines[0], "data-line") - steps;
    offset = steps * height - distance;
  } else if (lastBox.bottom <= viewTop) {
    const distance = viewTop - lastBox.bottom;
    const steps = Math.floor(distance / height);
    top = number(lines[lines.length - 1], "data-line") + 1 + steps;
    offset = distance - steps * height;
  } else {
    const line = lines[Math.min(firstEndingBelow(lines, viewTop), lines.length - 1)];
    top = number(line, "data-line");
    offset = viewTop - line.getBoundingClientRect().top;
  }
  const lastIndex = firstEndingBelow(lines, viewBottom + edgeTolerance) - 1;
  const lastLine = lines[lastIndex];
  if (!lastLine || lastLine.getBoundingClientRect().top < viewTop - edgeTolerance) {
    last = top + Math.max(Math.floor(view.clientHeight / height) - 1, 0);
  } else if (lastIndex === lines.length - 1) {
    last = number(lastLine, "data-line") + Math.floor((viewBottom - lastBox.bottom) / height);
  } else {
    last = number(lastLine, "data-line");
  }
  top = Math.max(Math.round(top), 1);
  send({
    type: "scroll",
    view: id,
    placement: applied.get(id) ?? 0,
    top,
    offset,
    last: Math.max(Math.round(last), top),
    height,
  });
}

function place(view) {
  const id = number(view, "data-view");
  const placement = number(view, "data-placement");
  if (id === null || placement === null || (applied.get(id) ?? 0) >= placement) return;
  applied.set(id, placement);
  const line = number(view, "data-place-line");
  const lines = ownLines(view);
  if (line !== null && lines.length > 0) {
    const target = lines.find((element) => number(element, "data-line") >= line);
    const first = lines[0].getBoundingClientRect();
    const height = (lines[lines.length - 1].getBoundingClientRect().bottom - first.top) / lines.length;
    const box = target && number(target, "data-line") === line
      ? target.getBoundingClientRect()
      : { top: first.top + (line - number(lines[0], "data-line")) * height, height };
    const viewTop = view.getBoundingClientRect().top + view.clientTop;
    let delta = box.top - viewTop;
    switch (view.getAttribute("data-place-align")) {
      case "center": delta -= (view.clientHeight - box.height) / 2; break;
      case "bottom": delta -= view.clientHeight - box.height; break;
      default: delta += number(view, "data-place-offset") ?? 0;
    }
    view.scrollTop += delta;
  }
  requestAnimationFrame(() => report(view));
}

function placeAll() {
  for (const view of document.querySelectorAll("[data-view][data-placement]")) place(view);
}

let scheduled = false;
new MutationObserver(() => {
  if (scheduled) return;
  scheduled = true;
  requestAnimationFrame(() => {
    scheduled = false;
    placeAll();
  });
}).observe(document.documentElement, {
  subtree: true,
  childList: true,
  attributes: true,
  attributeFilter: ["data-placement"],
});

document.addEventListener("scroll", (event) => {
  const view = event.target;
  if (!(view instanceof Element) || !view.hasAttribute("data-view")) return;
  clearTimeout(resting.get(view));
  resting.set(view, setTimeout(() => report(view), restMs));
}, { capture: true, passive: true });

placeAll();

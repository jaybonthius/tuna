import { action } from "datastar";
import { send } from "./input-sender";

// What the browser measured of a view's scroller, never what it means
// (ADR 7): the server's scroll state comes from this report, and every
// pixel in it is measured. Items are named by the tokens the renderer
// writes on their elements (data-item).
type ScrollFacts = Readonly<{
  type: "scroll";
  revision: number;            // the screen measured
  view: number;
  node: number;                // the node the scroller draws from
  placement: number;           // the last placement applied to the scroller
  top: string | null;          // the item at the top edge, or next to the spacer it is in
  offset: number;              // px of it above the edge
  lastVisible: string | null;  // the last item wholly in view
  spacer: "above" | "below" | null;  // the spacer the top edge is in
  spacerDistance: number;      // px from the drawn item next to it to the edge
  before: number;              // items drawn before the top item
  after: number;               // items drawn after it
  drawnHeight: number;         // px from the first drawn item's top to the last one's bottom
  above: number;               // px of them above the view
  below: number;               // px of them below the view
  width: number;               // the view's size, px
  height: number;
}>;

// What the page holds still through the next screen after a report (see
// tunaScroll): the item at the top edge, or, when that edge was in a
// spacer, the item the server counted across it, which the next screen's
// placement marker names: BLANK when no drawn item was in view, and the
// marker's target and offset when the page reported, to tell the answer
// from a screen sent before it.
type Held =
  | { kind: "item"; token: string; offset: number; scrollTop: number }
  | { kind: "spacer"; blank: boolean; target: string | null; offset: string | null; scrollTop: number };

// What the page keeps of each scroller, all of it presentation: the last
// placement it applied, whether it owes the server a report, and what it
// holds still through the next screen.
type ScrollerState = { placed: number; owed: boolean; held?: Held };
const scrollers = new WeakMap<Element, ScrollerState>();

// A non-negative integer attribute's value, or null.
function count(element: Element | null | undefined, name: string): number | null {
  const text = element?.getAttribute(name);
  return text != null && /^[0-9]+$/.test(text) && Number.isSafeInteger(Number(text)) ? Number(text) : null;
}

// A number attribute's value, or 0.
function pixels(element: Element, name: string): number {
  const value = Number(element.getAttribute(name));
  return Number.isFinite(value) ? value : 0;
}

// The index of the first of ITEMS, in document order and so stacked
// down the page, whose bottom is below Y; ITEMS.length if none is.
function firstEndingBelow(items: ArrayLike<Element>, y: number): number {
  let low = 0;
  let high = items.length;
  while (low < high) {
    const middle = (low + high) >> 1;
    if (items[middle].getBoundingClientRect().bottom > y) high = middle; else low = middle + 1;
  }
  return low;
}

// How many px of an item may lie beyond the view's edge for it still to
// count as wholly in view: what the browser rounds to a device pixel.
const edgeTolerance = 0.5;

// SCROLLER's drawn item whose token is TOKEN.
function drawnItem(scroller: Element, token: string): Element | undefined {
  return Array.from(scroller.querySelectorAll("[data-item]")).find((e) => e.getAttribute("data-item") === token);
}

// SCROLLER's spacer on SIDE of the drawn items, if it has one.
function spacerOn(scroller: Element, side: "above" | "below"): Element | undefined {
  return Array.from(scroller.querySelectorAll(".spacer")).find((e) => e.getAttribute("data-spacer") === side);
}

// Scroll SCROLLER so that ITEM's top is OFFSET px above its top edge.
function putAtTop(scroller: Element, item: Element, offset: number): void {
  const viewTop = scroller.getBoundingClientRect().top + scroller.clientTop;
  const moved = item.getBoundingClientRect().top - (viewTop - offset);
  if (Math.abs(moved) >= 0.5) scroller.scrollTop += moved;
}

// After the screen that answers a report, if SCROLLER has not moved
// since it reported: put the item HELD names back where it was, when the
// screen moved it and the browser's scroll anchoring did not; or, after
// a report from a spacer with nothing drawn in view, put the item the
// server counted across the spacer at the top, at the offset it counted.
// A view that moved on is left as the browser has it; its next report
// says where it is.
function holdStill(scroller: Element, held: Held): void {
  if (scroller.scrollTop !== held.scrollTop) return;
  if (held.kind === "item") {
    const item = drawnItem(scroller, held.token);
    if (item !== undefined) putAtTop(scroller, item, held.offset);
    return;
  }
  const marker = scroller.querySelector(".placement");
  const target = marker?.getAttribute("data-target") ?? null;
  const offset = marker?.getAttribute("data-offset") ?? null;
  if (!held.blank || marker == null || target === null
      || (target === held.target && offset === held.offset)) return;
  const item = drawnItem(scroller, target);
  if (item !== undefined) putAtTop(scroller, item, pixels(marker, "data-offset"));
}

// The renderer calls this from a view's scroller (the element with
// data-effect and data-on:scrollend): with REASON "moved" on every scroll
// and whenever a screen puts the data-effect back, and "rest" when
// scrolling ends; and from a spacer inside it, with "spacer", when the
// spacer comes into view. It reports when what is drawn runs short or
// long on either side against the drawn-screens view heights the server
// asks for, when the view's size is not the one the server last heard,
// when scrolling ends, when a spacer is in view, and after a placement. A
// report removes the scroller's data-effect, and none is sent while it is
// missing, so one report is on its way until the next screen puts it
// back: over a slow link, reports sent faster than screens return would
// queue up and describe the past. A scrolling end that could not go then
// is owed, and goes with the next screen; a spacer that could not is
// observed again by the next screen. When the top edge is in a spacer,
// the report names the drawn item next to it and how far the edge is from
// it, and the server counts the item there. The browser's scroll
// anchoring keeps what is in view still when a screen draws more above
// it, but not always: Chrome leaves the view where it is while the first
// item drawn is in view. So a report holds what it found at the top
// still through the next screen when the scroller has not moved since
// (holdStill). A new placement marker is the placement's to apply first
// (tunaPlace).
action({
  name: "tunaScroll",
  apply({ el: from }: { el: HTMLElement }, reason: "moved" | "rest" | "spacer"): void {
    const el = from.closest("[data-scroll-root]") as HTMLElement | null;
    const state = el === null ? undefined : scrollers.get(el);
    if (el === null || state === undefined) return;  // tunaPlace runs first, then reports
    if (!el.hasAttribute("data-effect")) {
      if (reason === "rest") state.owed = true;
      return;
    }
    if (count(el.querySelector(".placement"), "data-placement") !== state.placed) return;
    if (state.held !== undefined) {
      holdStill(el, state.held);
      state.held = undefined;
    }
    const want = pixels(el, "data-drawn-screens") * el.clientHeight;
    const box = el.getBoundingClientRect();
    const viewTop = box.top + el.clientTop;
    const viewBottom = viewTop + el.clientHeight;
    const items = el.querySelectorAll("[data-item]");
    const first = items[0];
    const last = items[items.length - 1];
    const firstTop = first?.getBoundingClientRect().top ?? viewTop;
    const lastBottom = last?.getBoundingClientRect().bottom ?? viewTop;
    const above = Math.max(viewTop - firstTop, 0);
    const below = Math.max(lastBottom - viewBottom, 0);
    const due = reason !== "moved" || state.owed
      || el.clientWidth !== count(el, "data-measured-width")
      || el.clientHeight !== count(el, "data-measured-height")
      || (above < want / 2 && !el.hasAttribute("data-run-at-start"))
      || (below < want / 2 && !el.hasAttribute("data-run-at-end"))
      // Far more than asked for: only when an item lies far enough beyond
      // the edge that drawing fewer leaves enough.
      || (above > 2 * want && first !== undefined
          && viewTop - first.getBoundingClientRect().bottom > want / 2)
      || (below > 2 * want && last !== undefined
          && last.getBoundingClientRect().top - viewBottom > want / 2);
    const revision = count(document.getElementById("screen"), "data-revision");
    const view = count(el.closest("[data-view]"), "data-view");
    const node = count(el, "data-scroll-root");
    if (!due || revision === null || view === null || node === null) return;
    // The top edge is in a spacer when it is beyond the drawn items and a
    // spacer is there.
    const spacer = first !== undefined && firstTop - viewTop > edgeTolerance && spacerOn(el, "above") ? "above"
      : last !== undefined && viewTop >= lastBottom && spacerOn(el, "below") ? "below"
      : null;
    const topIndex = spacer === "above" ? 0
      : spacer === "below" ? items.length - 1
      : Math.min(firstEndingBelow(items, viewTop), items.length - 1);
    const lastIndex = firstEndingBelow(items, viewBottom + edgeTolerance) - 1;
    const lastShown = items[lastIndex];
    const top = items[topIndex];
    const token = top?.getAttribute("data-item") ?? null;
    const offset = top ? viewTop - top.getBoundingClientRect().top : 0;
    el.removeAttribute("data-effect");
    state.owed = false;
    if (spacer !== null) {
      const marker = el.querySelector(".placement");
      state.held = {
        kind: "spacer",
        blank: firstTop >= viewBottom || lastBottom <= viewTop,
        target: marker?.getAttribute("data-target") ?? null,
        offset: marker?.getAttribute("data-offset") ?? null,
        scrollTop: el.scrollTop,
      };
    } else {
      state.held = token === null ? undefined : { kind: "item", token, offset, scrollTop: el.scrollTop };
    }
    send<ScrollFacts>({
      type: "scroll",
      revision,
      view,
      node,
      placement: state.placed,
      top: token,
      offset,
      lastVisible: spacer === null
        ? items[Math.max(lastIndex, topIndex)]?.getAttribute("data-item") ?? null
        : lastShown !== undefined && lastShown.getBoundingClientRect().top >= viewTop - edgeTolerance
          ? lastShown.getAttribute("data-item")
          : null,
      spacer,
      spacerDistance: spacer === "above" ? firstTop - viewTop : spacer === "below" ? viewTop - lastBottom : 0,
      before: Math.max(topIndex, 0),
      after: Math.max(items.length - 1 - topIndex, 0),
      drawnHeight: Math.max(lastBottom - firstTop, 0),
      above,
      below,
      width: el.clientWidth,
      height: el.clientHeight,
    });
  },
});

// The renderer calls this from a view's placement marker (data-init) when
// the marker is new: on a new placement, and on a freshly loaded page. It
// scrolls the marker's scroller so that the item the marker names is at
// the top (data-offset px of it above the edge), centre or bottom
// (data-align), or, when it names none, to the scroller's start; then has
// the scroller report where it is.
action({
  name: "tunaPlace",
  apply({ el }: { el: HTMLElement }): void {
    const scroller = el.parentElement;
    const number = count(el, "data-placement");
    if (scroller === null || number === null) return;
    const target = el.getAttribute("data-target");
    const item = target === null ? undefined : drawnItem(scroller, target);
    if (target === null) {
      scroller.scrollTop = 0;
    } else if (item !== undefined) {
      const box = item.getBoundingClientRect();
      const top = box.top - (scroller.getBoundingClientRect().top + scroller.clientTop) + scroller.scrollTop;
      switch (el.getAttribute("data-align")) {
        case "center": scroller.scrollTop = top + box.height / 2 - scroller.clientHeight / 2; break;
        case "bottom": scroller.scrollTop = top + box.height - scroller.clientHeight; break;
        default: scroller.scrollTop = top + pixels(el, "data-offset");
      }
    }
    const state = scrollers.get(scroller);
    if (state === undefined) scrollers.set(scroller, { placed: number, owed: true });
    else Object.assign(state, { placed: number, owed: true, held: undefined });
    // Run the scroller's report trigger, which reports what is owed.
    scroller.dispatchEvent(new Event("scroll"));
  },
});

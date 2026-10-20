import { action } from "datastar";
import { send } from "./input-sender";
import { placementApplied } from "./tuna-scroll-bar";

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
  top: string | null;          // the item at the top edge
  offset: number;              // px of it above the edge
  lastVisible: string | null;  // the last item in view
  before: number;              // items drawn before the top item
  after: number;               // items drawn after it
  above: number;               // px drawn above the view
  below: number;               // px drawn below the view
  width: number;               // the view's size, px
  height: number;
}>;

// What the page keeps of each scroller, all of it presentation: the last
// placement it applied, whether it owes the server a report, and when it
// last moved (for the scroll bar shown while scrolling).
type ScrollerState = { placed: number; owed: boolean; scrollTop: number; still?: ReturnType<typeof setTimeout> };
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

// The index of the last of ITEMS whose top is above Y; -1 if none is.
function lastStartingAbove(items: ArrayLike<Element>, y: number): number {
  let low = -1;
  let high = items.length - 1;
  while (low < high) {
    const middle = (low + high + 1) >> 1;
    if (items[middle].getBoundingClientRect().top < y) low = middle; else high = middle - 1;
  }
  return low;
}

// Show SCROLLER's scroll bar while it moves (a class the renderer's
// stylesheet shows the bar by on a touch screen), and hide it again once
// it has been still for a moment.
function showMoving(scroller: Element, state: ScrollerState): void {
  const bar = scroller.parentElement?.querySelector(".scroll-bar");
  if (!bar || scroller.scrollTop === state.scrollTop) return;
  state.scrollTop = scroller.scrollTop;
  bar.classList.add("scrolling");
  clearTimeout(state.still);
  state.still = setTimeout(() => { bar.classList.remove("scrolling"); }, 800);
}

// The renderer calls this from a view's scroller (the element with
// data-effect and data-on:scrollend): with REASON "moved" on every scroll
// and whenever a screen puts the data-effect back, and "rest" when
// scrolling ends. It reports when what is drawn runs short or long on
// either side against the drawn-above and drawn-below px the server asks
// for, when the view's size is not the one the server last heard, when
// scrolling ends, and after a placement. A report removes the scroller's
// data-effect, and none is sent while it is missing, so one report is on
// its way until the next screen puts it back: over a slow link, reports
// sent faster than screens return would queue up and describe the past.
// A report that could not go then is owed, and goes with the next screen.
action({
  name: "tunaScroll",
  apply({ el }: { el: HTMLElement }, reason: "moved" | "rest"): void {
    const state = scrollers.get(el);
    if (state === undefined) return;  // tunaPlace runs first, then reports
    showMoving(el, state);
    if (!el.hasAttribute("data-effect")) {
      if (reason === "rest") state.owed = true;
      return;
    }
    const wantAbove = pixels(el, "data-drawn-above");
    const wantBelow = pixels(el, "data-drawn-below");
    const above = el.scrollTop;
    const below = el.scrollHeight - el.scrollTop - el.clientHeight;
    const box = el.getBoundingClientRect();
    const viewTop = box.top + el.clientTop;
    const viewBottom = viewTop + el.clientHeight;
    const items = el.querySelectorAll("[data-item]");
    const first = items[0];
    const last = items[items.length - 1];
    const due = reason === "rest" || state.owed
      || el.clientWidth !== count(el, "data-measured-width")
      || el.clientHeight !== count(el, "data-measured-height")
      || (above < wantAbove / 2 && !el.hasAttribute("data-run-at-start"))
      || (below < wantBelow / 2 && !el.hasAttribute("data-run-at-end"))
      // Far more than asked for: only when an item lies far enough beyond
      // the edge that drawing fewer leaves enough.
      || (above > 2 * wantAbove && first !== undefined
          && viewTop - first.getBoundingClientRect().bottom > wantAbove / 2)
      || (below > 2 * wantBelow && last !== undefined
          && last.getBoundingClientRect().top - viewBottom > wantBelow / 2);
    const revision = count(document.getElementById("screen"), "data-revision");
    const view = count(el.closest("[data-view]"), "data-view");
    const node = count(el, "data-scroll-root");
    if (!due || revision === null || view === null || node === null) return;
    const topIndex = Math.min(firstEndingBelow(items, viewTop), items.length - 1);
    const lastIndex = Math.max(lastStartingAbove(items, viewBottom), topIndex);
    const top = items[topIndex];
    el.removeAttribute("data-effect");
    state.owed = false;
    void send<ScrollFacts>({
      type: "scroll",
      revision,
      view,
      node,
      placement: state.placed,
      top: top?.getAttribute("data-item") ?? null,
      offset: top ? viewTop - top.getBoundingClientRect().top : 0,
      lastVisible: items[lastIndex]?.getAttribute("data-item") ?? null,
      before: Math.max(topIndex, 0),
      after: Math.max(items.length - 1 - topIndex, 0),
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
// (data-align), then has the scroller report where it is.
action({
  name: "tunaPlace",
  apply({ el }: { el: HTMLElement }): void {
    const scroller = el.parentElement;
    const number = count(el, "data-placement");
    if (scroller === null || number === null) return;
    const target = el.getAttribute("data-target");
    const item = target === null ? undefined
      : Array.from(scroller.querySelectorAll("[data-item]")).find((e) => e.getAttribute("data-item") === target);
    if (item !== undefined) {
      const box = item.getBoundingClientRect();
      const top = box.top - (scroller.getBoundingClientRect().top + scroller.clientTop) + scroller.scrollTop;
      switch (el.getAttribute("data-align")) {
        case "center": scroller.scrollTop = top + box.height / 2 - scroller.clientHeight / 2; break;
        case "bottom": scroller.scrollTop = top + box.height - scroller.clientHeight; break;
        default: scroller.scrollTop = top + pixels(el, "data-offset");
      }
    }
    const state = scrollers.get(scroller);
    if (state === undefined) scrollers.set(scroller, { placed: number, owed: true, scrollTop: scroller.scrollTop });
    else Object.assign(state, { placed: number, owed: true, scrollTop: scroller.scrollTop });
    placementApplied(scroller);
    // Run the scroller's report trigger, which reports what is owed.
    scroller.dispatchEvent(new Event("scroll"));
  },
});

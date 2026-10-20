import { action } from "datastar";
import { send } from "./input-sender";

// What the browser sees after a view scrolled, never where it should be:
// the server places the view's anchor from this report (ADR 7). Lines
// count from 1 in the view's windowed text; pixel positions are measured
// down from the top of that text's element.
type ScrollFacts = Readonly<{
  type: "scroll";
  revision: number;      // the screen the report was computed on
  view: number;
  node: number;          // the windowed text node
  top: number | null;    // the line at the view's top
  offset: number;        // px of that line above the view's top
  last: number | null;   // the last line in view
  at: number;            // the view's top
  drawnStart: number;    // the top of the first line drawn
  drawnEnd: number;      // the bottom of the last line drawn
  drawnFirst: number;
  drawnLast: number;
  height: number;        // the view's height
  request: number;       // the last scroll request applied
}>;

// A non-negative integer attribute's value, or null.
function count(element: Element | null | undefined, name: string): number | null {
  const text = element?.getAttribute(name);
  return text != null && /^[0-9]+$/.test(text) && Number.isSafeInteger(Number(text)) ? Number(text) : null;
}

// ELEMENT if it is a line, otherwise its sibling NEXT of it: the text's
// first or last line when ELEMENT is the spacer at that end.
function lineOrSibling(element: Element | null | undefined, next: "nextElementSibling" | "previousElementSibling")
  : Element | null {
  if (element == null) return null;
  return element.hasAttribute("data-line") ? element : element[next];
}

// The line of TEXT at viewport point (X, Y), or null.
function lineAt(text: Element, x: number, y: number): Element | null {
  const line = document.elementFromPoint(x, y)?.closest("[data-line]") ?? null;
  return line !== null && text.contains(line) ? line : null;
}

// The renderer calls this from the scroller of a view (the element with
// data-effect and data-on:scrollend): with REASON "moved" on every scroll
// and after each screen that changes the window, and "rest" when scrolling
// ends. A "moved" report is sent only when the line at the top has left
// LOW..HIGH, the top is in a spacer, or the view's height is not the
// HEIGHT the server drew for. Either report removes the scroller's
// data-effect, and none is sent while it is missing, so one report is on its
// way until the next screen puts it back: over a slow link, reports sent
// faster than screens return would queue up and describe the past.
action({
  name: "tunaScroll",
  apply({ el }: { el: HTMLElement }, reason: "moved" | "rest", low: number, high: number,
        height: number, request: number): void {
    const text = el.querySelector("[data-window]");
    const first = lineOrSibling(text?.firstElementChild, "nextElementSibling");
    const lastDrawn = lineOrSibling(text?.lastElementChild, "previousElementSibling");
    const revision = count(document.getElementById("screen"), "data-revision");
    const view = count(el.closest("[data-view]"), "data-view");
    const node = count(text, "data-node");
    const drawnFirst = count(first, "data-line");
    const drawnLast = count(lastDrawn, "data-line");
    if (!text || !first || !lastDrawn || revision === null || view === null || node === null
        || drawnFirst === null || drawnLast === null) return;
    const box = el.getBoundingClientRect();
    const viewTop = box.top + el.clientTop;
    const textTop = text.getBoundingClientRect().top;
    const x = box.left + box.width / 2;
    const top = lineAt(text, x, viewTop + 1);
    const bottom = lineAt(text, x, viewTop + el.clientHeight - 1);
    const at = viewTop - textTop;
    const drawnStart = first.getBoundingClientRect().top - textTop;
    const drawnEnd = lastDrawn.getBoundingClientRect().bottom - textTop;
    const topLine = count(top, "data-line");
    if (!el.hasAttribute("data-effect")) return;
    if (reason === "moved") {
      const outside = topLine !== null
        ? topLine < low || topLine > high
        : (at < drawnStart && first.previousElementSibling !== null)
          || (at >= drawnEnd && lastDrawn.nextElementSibling !== null);
      if (!outside && el.clientHeight === height) return;
    }
    el.removeAttribute("data-effect");
    send<ScrollFacts>({
      type: "scroll",
      revision,
      view,
      node,
      top: topLine,
      offset: top ? viewTop - top.getBoundingClientRect().top : 0,
      last: count(bottom, "data-line"),
      at,
      drawnStart,
      drawnEnd,
      drawnFirst,
      drawnLast,
      height: el.clientHeight,
      request,
    });
  },
});

import { action } from "datastar";
import { send } from "./input-sender";

// A drag of a view's scroll bar handle, or a click on its track, as the
// browser saw it (ADR 7): the server looks it up in its keymaps
// ("<vertical-scroll-bar> <drag-mouse-1>") and places items itself.
type ScrollBarFacts = Readonly<{
  type: "scroll-bar";
  revision: number;   // the screen the bar was on
  view: number;
  node: number;       // the node the view's scroller draws from
  part: "handle" | "above-handle" | "below-handle";
  fraction: number;   // how far down the track, from 0 to 1
}>;

// The custom property the renderer's stylesheet places a dragged handle
// by, on the bar, which keeps its style through morphs. Presentation only:
// the handle follows the pointer while the server places items.
const dragStart = "--scroll-bar-drag-start";

// Bars whose handle is being dragged.
const dragging = new WeakSet<Element>();

// A non-negative integer attribute's value, or null.
function count(element: Element | null | undefined, name: string): number | null {
  const text = element?.getAttribute(name);
  return text != null && /^[0-9]+$/.test(text) && Number.isSafeInteger(Number(text)) ? Number(text) : null;
}

function clamp(value: number, low: number, high: number): number {
  return Math.min(Math.max(value, low), high);
}

// Send PART and FRACTION for BAR's view; the promise settles once the
// server answered.
function sendFor(bar: Element, part: ScrollBarFacts["part"], fraction: number): Promise<void> {
  const revision = count(document.getElementById("screen"), "data-revision");
  const view = count(bar.closest("[data-view]"), "data-view");
  const node = count(bar.parentElement?.querySelector("[data-scroll-root]"), "data-scroll-root");
  if (revision === null || view === null || node === null) return Promise.resolve();
  return send<ScrollBarFacts>({ type: "scroll-bar", revision, view, node, part, fraction });
}

// End BAR's drag preview, unless its handle is being dragged.
function endPreview(bar: Element): void {
  if (!dragging.has(bar)) (bar as HTMLElement).style.removeProperty(dragStart);
}

// Called when SCROLLER applied a placement (tunaPlace): the screen that
// placed it puts the handle where the drag left it.
export function placementApplied(scroller: Element): void {
  const bar = scroller.parentElement?.querySelector(".scroll-bar");
  if (bar) endPreview(bar);
}

// Drag HANDLE from EVT: its top follows the pointer, and the fraction of
// the track it is at goes to the server, newest only, one at a time.
function drag(handle: HTMLElement, evt: PointerEvent): void {
  const bar = handle.parentElement;
  if (bar === null || evt.button !== 0) return;
  evt.preventDefault();
  handle.setPointerCapture(evt.pointerId);
  dragging.add(bar);
  const grab = evt.clientY - handle.getBoundingClientRect().top;
  let pending: number | null = null;
  let sent: number | null = null;
  let inFlight = false;
  const flush = (): void => {
    if (inFlight || pending === null || pending === sent) return;
    const fraction = pending;
    pending = null;
    sent = fraction;
    inFlight = true;
    void sendFor(bar, "handle", fraction).then(() => { inFlight = false; flush(); });
  };
  const move = (e: PointerEvent): void => {
    const track = bar.getBoundingClientRect();
    const size = handle.getBoundingClientRect().height;
    const top = clamp(e.clientY - grab - track.top, 0, Math.max(track.height - size, 0));
    bar.style.setProperty(dragStart, `${top}px`);
    pending = track.height > 0 ? top / track.height : 0;
    flush();
  };
  const end = (): void => {
    handle.removeEventListener("pointermove", move);
    handle.removeEventListener("pointerup", end);
    handle.removeEventListener("pointercancel", end);
    dragging.delete(bar);
    // The placement the drag asked for ends the preview; this, should it
    // not come (the handle was let go where it was).
    setTimeout(() => { endPreview(bar); }, 1000);
  };
  handle.addEventListener("pointermove", move);
  handle.addEventListener("pointerup", end);
  handle.addEventListener("pointercancel", end);
}

// The renderer calls this from a view's scroll bar handle on pointerdown,
// to drag it, and from the bar on click, to page toward the click. A
// click on the bar is the bar's alone: it does not also click the view.
action({
  name: "tunaScrollBar",
  apply({ el, evt }: { el: HTMLElement; evt?: Event }): void {
    if (evt?.type === "pointerdown") {
      drag(el, evt as PointerEvent);
      return;
    }
    if (evt?.type !== "click") return;
    evt.stopPropagation();
    const click = evt as MouseEvent;
    const handle = el.querySelector(".scroll-bar-handle");
    if (handle === null || handle.contains(click.target as Node)) return;
    const track = el.getBoundingClientRect();
    void sendFor(el, click.clientY < handle.getBoundingClientRect().top ? "above-handle" : "below-handle",
                 track.height > 0 ? clamp((click.clientY - track.top) / track.height, 0, 1) : 0);
  },
});

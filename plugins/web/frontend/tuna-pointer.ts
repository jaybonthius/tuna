import { action } from "datastar";
import { send } from "./input-sender";

// What the browser saw, never what it means: the server looks the click
// up in its keymaps (ADR 7, ADR 8). A click is sent on release, as the
// browser's click (left) and auxclick (middle, right) events. A click in
// or beside a line of text also names the line and the column nearest
// it; the server moves that through edits made since the screen was drawn.
//
// Pressing the left button in text is sent too (kind "down"), and then,
// once the pointer has moved more than dragFuzz px, each place it moves
// to while the button is held ("movement"), and the release ("drag"); a
// release before that is the click. The browser's own selection is not
// started, so the server's is the only one. Movements go one at a time:
// the next waits until a new screen has been applied, and goes with the
// newest place, so over a slow link movements never queue up.
type PointerFacts = Readonly<{
  type: "pointer";
  kind: "click" | "down" | "movement" | "drag";
  revision: number;   // the screen the event was computed on
  button: 0 | 1 | 2;  // left, middle, right
  clicks: number;     // presses in a row: 2 for a double click or its second press
  modifiers: Readonly<{ alt: boolean; ctrl: boolean; meta: boolean; shift: boolean }>;
  target: string;     // the nearest data-part, such as "tab-line:30"
  node: number | null; // the nearest data-node inside that part
  line: LineFacts | null; // the line of text clicked, inside that part
}>;

// How far, in px, the pointer may move from where it was pressed before
// the press becomes a drag (Emacs's double-click-fuzz).
const dragFuzz = 3;

// A left press in text that the page sent, until its release: where it
// was, the part it was in, the screen the movement on its way was
// computed on (null when none is), and the newest place the pointer
// moved to that is not yet sent (null when none is).
type Press = {
  part: Element;
  target: string;
  node: number | null;
  clicks: number;
  x: number;
  y: number;
  dragging: boolean;
  waiting: number | null;
  pending: { x: number; y: number } | null;
};
let press: Press | null = null;

// Whether the next left click is the release of a press already sent.
let released = false;

// Watches the screen's revision while a press is held, so a movement
// waiting for a new screen goes as soon as one is applied.
let screenWatch: MutationObserver | null = null;

// A line of a text node: its data-item token, the text's
// data-chars-revision, and the column, in code points from the line's
// start, of the caret position nearest the click.
type LineFacts = Readonly<{
  item: string;
  charsRevision: number;
  column: number;
}>;

function partOf(target: EventTarget | null): Element | null {
  return target instanceof Element ? target.closest("[data-part]") : null;
}

// Pressing keeps keyboard focus where it is and starts no text selection
// on chrome (a part outside any buffer node) and on whatever the server
// marked clickable, such as a button node, which would otherwise take
// focus. Inside other nodes the browser keeps its own behavior, except
// that a left press in text is the server's (inText).
function keepsFocus(target: EventTarget | null): boolean {
  if (partOf(target) === null) return false;
  const element = target as Element;
  return element.closest("[data-node]") === null || element.closest("[data-clickable]") !== null;
}

// A non-negative integer attribute's value, or null.
function count(element: Element | null | undefined, name: string): number | null {
  const text = element?.getAttribute(name);
  return text != null && /^[0-9]+$/.test(text) && Number.isSafeInteger(Number(text)) ? Number(text) : null;
}

function screenRevision(): number | null {
  return count(document.getElementById("screen"), "data-revision");
}

function nodeIn(part: Element, target: Element): number | null {
  const node = target.closest("[data-node]");
  return node !== null && part.contains(node) ? count(node, "data-node") : null;
}

// The caret position nearest the point X, Y: caretPositionFromPoint, or
// caretRangeFromPoint where only that exists.
function caretAt(x: number, y: number): { node: Node; offset: number } | null {
  if (typeof document.caretPositionFromPoint === "function") {
    const position = document.caretPositionFromPoint(x, y);
    return position && { node: position.offsetNode, offset: position.offset };
  }
  if (typeof document.caretRangeFromPoint === "function") {
    const range = document.caretRangeFromPoint(x, y);
    return range && { node: range.startContainer, offset: range.startOffset };
  }
  return null;
}

// The text node element TARGET is in, inside a part, unless it is in
// something the server marked clickable.
function inText(target: EventTarget | null): Element | null {
  if (!(target instanceof Element) || partOf(target) === null || target.closest("[data-clickable]") !== null) {
    return null;
  }
  return target.closest("[data-chars-revision]");
}

// The line of a text node in PART nearest the point X, Y. Unless BELOW,
// none when the point is below that line: a click below a view's last
// line names no line, so the server can take it to the end, while a drag
// there stays on the last line.
function lineIn(part: Element, x: number, y: number, below = false): LineFacts | null {
  const caret = caretAt(x, y);
  if (caret === null) return null;
  const element = caret.node instanceof Element ? caret.node : caret.node.parentElement;
  // A line is a child of its text node's element.
  const line = element?.closest("[data-item]") ?? null;
  const text = line?.parentElement ?? null;
  const item = line?.getAttribute("data-item");
  const charsRevision = count(text, "data-chars-revision");
  if (line === null || text === null || !item || charsRevision === null || !part.contains(text)) return null;
  if (!below && y > line.getBoundingClientRect().bottom) return null;
  const range = document.createRange();
  range.setStart(line, 0);
  range.setEnd(caret.node, caret.offset);
  return { item, charsRevision, column: [...range.toString()].length };
}

function modifiers(evt: MouseEvent): PointerFacts["modifiers"] {
  return { alt: evt.altKey, ctrl: evt.ctrlKey, meta: evt.metaKey, shift: evt.shiftKey };
}

// Send a click: on release, at the place of EVT.
function sendClick(evt: MouseEvent, button: 0 | 1 | 2): void {
  const part = partOf(evt.target);
  const revision = screenRevision();
  const target = part?.getAttribute("data-part");
  if (part === null || revision === null || !target) return;
  send<PointerFacts>({
    type: "pointer",
    kind: "click",
    revision,
    button,
    clicks: Math.max(1, evt.detail),
    modifiers: modifiers(evt),
    target,
    node: nodeIn(part, evt.target as Element),
    line: lineIn(part, evt.clientX, evt.clientY),
  });
}

// Send what the pressed left button P did, of KIND, naming P's part and
// node; LINE is the line where it happened, if any.
function sendPressed(p: Press, kind: "down" | "movement" | "drag", revision: number,
                     held: PointerFacts["modifiers"], line: LineFacts | null): void {
  send<PointerFacts>({
    type: "pointer",
    kind,
    revision,
    button: 0,
    clicks: p.clicks,
    modifiers: held,
    target: p.target,
    node: p.node,
    line,
  });
}

// Send the newest place the held button moved to, unless a movement is
// on its way and no new screen has been applied since it went. A place
// outside the text of the part pressed in is not sent: the selection
// stays where the last movement put it. A movement has no modifiers
// (Emacs's mouse-movement).
function sendMovement(): void {
  const p = press;
  const revision = screenRevision();
  if (p === null || p.pending === null || revision === null || p.waiting === revision) return;
  const { x, y } = p.pending;
  p.pending = null;
  const line = lineIn(p.part, x, y, true);
  if (line === null) return;
  p.waiting = revision;
  sendPressed(p, "movement", revision, { alt: false, ctrl: false, meta: false, shift: false }, line);
}

// The release of the pressed left button at the place of EVT: a click
// where it was pressed, a drag once it moved away. A drag released
// outside the text of the part pressed in names no line, and the server
// ends it where the last movement put the cursor.
function release(evt: MouseEvent): void {
  const p = press;
  if (p === null) return;
  press = null;
  screenWatch?.disconnect();
  released = true;
  if (!p.dragging) {
    sendClick(evt, 0);
    return;
  }
  const revision = screenRevision();
  if (revision !== null) {
    sendPressed(p, "drag", revision, modifiers(evt), lineIn(p.part, evt.clientX, evt.clientY, true));
  }
}

action({
  name: "tunaPointer",
  apply({ evt }: { evt?: Event }): void {
    if (!(evt instanceof MouseEvent)) return;
    switch (evt.type) {
      case "mousedown": {
        released = false;
        const text = evt.button === 0 ? inText(evt.target) : null;
        const part = partOf(evt.target);
        const revision = screenRevision();
        const target = part?.getAttribute("data-part");
        if (text === null || part === null || revision === null || !target) {
          if (keepsFocus(evt.target)) evt.preventDefault();
          return;
        }
        // The browser starts no selection of its own, and keeps focus.
        evt.preventDefault();
        press = {
          part, target, node: nodeIn(part, evt.target as Element), clicks: Math.max(1, evt.detail),
          x: evt.clientX, y: evt.clientY, dragging: false, waiting: null, pending: null,
        };
        const screen = document.getElementById("screen");
        if (typeof MutationObserver === "function" && screen !== null) {
          screenWatch ??= new MutationObserver(sendMovement);
          screenWatch.disconnect();
          screenWatch.observe(screen, { attributes: true, attributeFilter: ["data-revision"] });
        }
        sendPressed(press, "down", revision, modifiers(evt), lineIn(part, evt.clientX, evt.clientY));
        return;
      }
      case "mousemove": {
        const p = press;
        if (p === null) return;
        // The button went up where the page did not see it (outside the
        // window): this is the release.
        if ((evt.buttons & 1) === 0) { release(evt); return; }
        if (!p.dragging && Math.hypot(evt.clientX - p.x, evt.clientY - p.y) <= dragFuzz) return;
        p.dragging = true;
        p.pending = { x: evt.clientX, y: evt.clientY };
        sendMovement();
        return;
      }
      case "mouseup":
        if (evt.button === 0) release(evt);
        return;
      case "contextmenu":
        // contextmenu too, so a right click on chrome reaches auxclick.
        if (keepsFocus(evt.target)) evt.preventDefault();
        return;
      case "click":
      case "auxclick": {
        const button = evt.button;
        if (button !== 0 && button !== 1 && button !== 2) return;
        if (button === 0 && released) { released = false; return; }
        sendClick(evt, button);
        return;
      }
    }
  },
});

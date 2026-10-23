import { action } from "datastar";
import { send } from "./input-sender";

// What the browser saw, never what it means: the server looks the click
// up in its keymaps (ADR 7, ADR 8). A click is sent on release, as the
// browser's click (left) and auxclick (middle, right) events. A click in
// or beside a line of text also names the line and the column nearest
// it; the server moves that through edits made since the screen was drawn.
type PointerFacts = Readonly<{
  type: "pointer";
  kind: "click";
  revision: number;   // the screen the click was computed on
  button: 0 | 1 | 2;  // left, middle, right
  clicks: number;     // presses in a row: 2 for a double click
  modifiers: Readonly<{ alt: boolean; ctrl: boolean; meta: boolean; shift: boolean }>;
  target: string;     // the nearest data-part, such as "tab-line:30"
  node: number | null; // the nearest data-node inside that part
  line: LineFacts | null; // the line of text clicked, inside that part
}>;

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
// focus. Inside other nodes the browser keeps its own behavior, such as
// selecting text.
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

// The line of a text node in PART nearest the click, unless the click is
// below it: a click below a view's last line names no line, so the server
// can take it to the end.
function lineIn(part: Element, evt: MouseEvent): LineFacts | null {
  const caret = caretAt(evt.clientX, evt.clientY);
  if (caret === null) return null;
  const element = caret.node instanceof Element ? caret.node : caret.node.parentElement;
  // A line is a child of its text node's element.
  const line = element?.closest("[data-item]") ?? null;
  const text = line?.parentElement ?? null;
  const item = line?.getAttribute("data-item");
  const charsRevision = count(text, "data-chars-revision");
  if (line === null || text === null || !item || charsRevision === null || !part.contains(text)) return null;
  if (evt.clientY > line.getBoundingClientRect().bottom) return null;
  const range = document.createRange();
  range.setStart(line, 0);
  range.setEnd(caret.node, caret.offset);
  return { item, charsRevision, column: [...range.toString()].length };
}

action({
  name: "tunaPointer",
  apply({ evt }: { evt?: Event }): void {
    if (!(evt instanceof MouseEvent)) return;
    switch (evt.type) {
      case "mousedown":
      case "contextmenu":
        // contextmenu too, so a right click on chrome reaches auxclick.
        if (keepsFocus(evt.target)) evt.preventDefault();
        return;
      case "click":
      case "auxclick": {
        const button = evt.button;
        if (button !== 0 && button !== 1 && button !== 2) return;
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
          modifiers: {
            alt: evt.altKey,
            ctrl: evt.ctrlKey,
            meta: evt.metaKey,
            shift: evt.shiftKey,
          },
          target,
          node: nodeIn(part, evt.target as Element),
          line: lineIn(part, evt),
        });
        return;
      }
    }
  },
});

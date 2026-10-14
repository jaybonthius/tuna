import { action } from "datastar";
import { enqueue } from "./input-queue";

// What the browser saw, never what it means: the server looks the click
// up in its keymaps (ADR 7, ADR 8). A click is sent on release, as the
// browser's click (left) and auxclick (middle, right) events.
type PointerFacts = Readonly<{
  type: "pointer";
  kind: "click";
  revision: number;   // the screen the click was computed on
  button: 0 | 1 | 2;  // left, middle, right
  clicks: number;     // presses in a row: 2 for a double click
  modifiers: Readonly<{ alt: boolean; ctrl: boolean; meta: boolean; shift: boolean }>;
  target: string;     // the nearest data-part, such as "tab-line:30"
  node: number | null; // the nearest data-node inside that part
}>;

function partOf(target: EventTarget | null): Element | null {
  return target instanceof Element ? target.closest("[data-part]") : null;
}

// Chrome is a part outside any buffer node: pressing on it keeps keyboard
// focus where it is and starts no text selection. Inside nodes the browser
// keeps its own behavior, such as selecting text.
function onChrome(target: EventTarget | null): boolean {
  return partOf(target) !== null && (target as Element).closest("[data-node]") === null;
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

action({
  name: "tunaPointer",
  apply({ evt }: { evt?: Event }): void {
    if (!(evt instanceof MouseEvent)) return;
    switch (evt.type) {
      case "mousedown":
      case "contextmenu":
        // contextmenu too, so a right click on chrome reaches auxclick.
        if (onChrome(evt.target)) evt.preventDefault();
        return;
      case "click":
      case "auxclick": {
        const button = evt.button;
        if (button !== 0 && button !== 1 && button !== 2) return;
        const part = partOf(evt.target);
        const revision = screenRevision();
        const target = part?.getAttribute("data-part");
        if (part === null || revision === null || !target) return;
        enqueue<PointerFacts>({
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
        });
        return;
      }
    }
  },
});

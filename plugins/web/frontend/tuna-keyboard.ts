import { action } from "datastar";
import { enqueue } from "./input-queue";

type KeydownFacts = Readonly<{
  type: "keydown";
  key: string;
  code: string;
  location: number;
  repeat: boolean;
  isComposing: boolean;
  altKey: boolean;
  ctrlKey: boolean;
  metaKey: boolean;
  shiftKey: boolean;
  isMac: boolean;
  altLeft: boolean;
  altRight: boolean;
  altGraph: boolean;
}>;

const isMac = /Mac/i.test(navigator.platform);
let altLeft = false;
let altRight = false;

// Track physical modifiers before Datastar's document keydown action.
// These are browser facts, not the server's Option/Meta policy.
function trackAlt(evt: KeyboardEvent): void {
  const held = evt.type === "keydown";
  if (evt.code === "AltLeft" || (evt.key === "Alt" && evt.location === 1)) altLeft = held;
  if (evt.code === "AltRight" || (evt.key === "Alt" && evt.location === 2)) altRight = held;
}
window.addEventListener("keydown", trackAlt, true);
window.addEventListener("keyup", trackAlt, true);
window.addEventListener("blur", () => { altLeft = false; altRight = false; });

action({
  name: "tunaKeyboard",
  apply({ evt }: { evt?: Event }): void {
    if (!(evt instanceof KeyboardEvent) || evt.type !== "keydown") return;
    if (!evt.isComposing) evt.preventDefault();
    enqueue<KeydownFacts>({
      type: "keydown",
      key: evt.key,
      code: evt.code,
      location: evt.location,
      repeat: evt.repeat,
      isComposing: evt.isComposing,
      altKey: evt.altKey,
      ctrlKey: evt.ctrlKey,
      metaKey: evt.metaKey,
      shiftKey: evt.shiftKey,
      isMac,
      altLeft: evt.altKey && altLeft,
      altRight: evt.altKey && altRight,
      altGraph: evt.getModifierState("AltGraph"),
    });
  },
});

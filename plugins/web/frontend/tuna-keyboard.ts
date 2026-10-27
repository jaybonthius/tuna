import { action } from "datastar";
import { send } from "./input-sender";

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

// The browser's paste keys: Cmd+V on a Mac; elsewhere Ctrl+Shift+V and
// Shift+Insert, since Ctrl+V is Emacs's C-v. They are neither cancelled
// nor sent, so the browser fires its paste event (tunaPaste) instead.
function pasteChord(evt: KeyboardEvent): boolean {
  const v = evt.key === "v" || evt.key === "V";
  if (isMac) return v && evt.metaKey && !evt.ctrlKey && !evt.altKey && !evt.shiftKey;
  if (evt.altKey || evt.metaKey) return false;
  return (v && evt.ctrlKey && evt.shiftKey) || (evt.key === "Insert" && evt.shiftKey && !evt.ctrlKey);
}

action({
  name: "tunaKeyboard",
  apply({ evt }: { evt?: Event }): void {
    if (!(evt instanceof KeyboardEvent) || evt.type !== "keydown") return;
    if (pasteChord(evt)) return;
    if (!evt.isComposing) evt.preventDefault();
    send<KeydownFacts>({
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
    }, evt.timeStamp);
  },
});

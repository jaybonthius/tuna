import { send } from "tuna";

const mac = /Mac|iPhone|iPad/.test(navigator.platform);

// The browser reports Alt without its side, so the page follows each
// Option key's own presses.
let leftOption = false;
let rightOption = false;

function trackOption(event) {
  const down = event.type === "keydown";
  if (event.code === "AltLeft") leftOption = down;
  else if (event.code === "AltRight") rightOption = down;
}

window.addEventListener("keydown", trackOption, true);
window.addEventListener("keyup", trackOption, true);
window.addEventListener("blur", () => {
  leftOption = false;
  rightOption = false;
});

const modifierKeys = new Set([
  "", "Shift", "Control", "Alt", "AltGraph", "Meta", "OS", "Super", "Hyper", "CapsLock", "NumLock",
  "ScrollLock", "Fn", "FnLock", "Symbol", "SymbolLock", "Process", "Compose", "Unidentified",
]);

// The browser fires its paste event, the one way a page reads the
// clipboard, only for its own paste keys: Cmd-V on a Mac; elsewhere
// Ctrl-Shift-V and Shift-Insert, since Ctrl-V is C-v.
function pasteKey(event) {
  const v = event.key === "v" || event.key === "V";
  if (mac) return v && event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey;
  if (event.altKey || event.metaKey) return false;
  return (v && event.ctrlKey && event.shiftKey) || (event.key === "Insert" && event.shiftKey && !event.ctrlKey);
}

function modifiers(event, altGraph) {
  const names = [];
  if (altGraph) {
    names.push("alt-graph");
  } else {
    if (event.ctrlKey) names.push("control");
    if (event.altKey && !mac) names.push("alt");
    // A press of either Option the page missed, as when it came before
    // the page had focus, leaves no side; the left one is the usual.
    if (event.altKey && mac && (leftOption || !rightOption)) names.push("left-option");
    if (event.altKey && mac && rightOption) names.push("right-option");
  }
  if (event.shiftKey) names.push("shift");
  if (event.metaKey) names.push("super");
  return names;
}

window.addEventListener("keydown", (event) => {
  // Key code 229 marks a key an input method takes, in browsers that do
  // not set isComposing on the first one.
  if (event.isComposing || event.keyCode === 229) return;
  const key = event.key;
  if (modifierKeys.has(key)) return;
  // A dead key starts a composed character, except under an Option key,
  // which Tuna may take as Meta.
  if (key === "Dead" && !(mac && event.altKey)) return;
  if ([...key].length !== 1 && !/^[A-Za-z0-9]+$/.test(key)) return;
  if (pasteKey(event)) return;
  event.preventDefault();
  const altGraph = event.getModifierState("AltGraph");
  const item = { type: "key", key, code: event.code, modifiers: modifiers(event, altGraph) };
  if (key === "g" && event.ctrlKey && !event.altKey && !event.metaKey && !event.shiftKey && !altGraph) {
    item.quit = true;
  }
  send(item);
});

import { getPath } from "datastar";

// Keys, pointers and scroll reports share page-load numbering, and each
// names the tab it comes from: the page shell's `tab` signal, which
// Datastar also sends with the screen stream and /applied (ADR 16). Send
// immediately; the server restores each tab's order. Retry the same body
// only when no HTTP response arrived.
let sequence = 0;

export function send<T extends object>(facts: T): void {
  const body = JSON.stringify({ ...facts, version: 1, tab: getPath("tab"), sequence: ++sequence });
  const post = () => fetch("/commands", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Datastar-Request": "true",
    },
    body,
  }).catch(() => { setTimeout(post, 250); });
  void post();
}

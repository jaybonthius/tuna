import { getPath } from "datastar";

// Keys, pointers and scroll reports share page-load numbering, and each
// names the tab it comes from: the page shell's `tab` signal, which
// Datastar also sends with the screen stream and /applied (ADR 16). Send
// immediately; the server restores each tab's order. Retry the same body
// only when no HTTP response arrived.
let sequence = 0;

// When each item still unreported was sent, on the page's clock, and when
// its event happened (null when not given): tunaApplied reports them with
// the first screen that includes them.
export type SentItem = { event: number | null; sent: number };
export const sentItems = new Map<number, SentItem>();
const sentItemsLimit = 1024;

// Send FACTS as the next item; EVENT-TIME is its event's timeStamp, when
// it has one worth measuring from (a key).
export function send<T extends object>(facts: T, eventTime?: number): void {
  const number = ++sequence;
  const body = JSON.stringify({ ...facts, version: 1, tab: getPath("tab"), sequence: number });
  sentItems.set(number, { event: eventTime ?? null, sent: performance.now() });
  if (sentItems.size > sentItemsLimit) sentItems.delete(sentItems.keys().next().value as number);
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

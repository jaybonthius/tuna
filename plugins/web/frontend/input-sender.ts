// Keys, pointers and scroll reports share page-load numbering. Send
// immediately; the server restores order. Retry the same body only when no
// HTTP response arrived.
let sequence = 0;

export function send<T extends object>(facts: T): void {
  const body = JSON.stringify({ ...facts, version: 1, sequence: ++sequence });
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

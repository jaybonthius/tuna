// Keys, pointers, scroll reports and scroll bar drags share page-load
// numbering. Send immediately; the server restores order. Retry the same
// body only when no HTTP response arrived. The promise settles once a
// response arrived.
let sequence = 0;

export function send<T extends object>(facts: T): Promise<void> {
  const body = JSON.stringify({ ...facts, version: 1, sequence: ++sequence });
  return new Promise((resolve) => {
    const post = () => fetch("/commands", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Datastar-Request": "true",
      },
      body,
    }).then(() => { resolve(); }, () => { setTimeout(post, 250); });
    void post();
  });
}

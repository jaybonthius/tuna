import { getPath } from "datastar";

// Items go at once, on as many connections as the browser opens, and Tuna
// puts each client's items back in order by their numbers. Only a failed
// connection is retried, with the same body and number.
let seq = 0;

// The first screen comes inside the page, so its scripts may send before
// Datastar has read the page's signals; the client is in them as written.
function client() {
  return getPath("client") ?? document.body?.getAttribute("data-signals:client")?.slice(1, -1);
}

export function send(item) {
  const body = JSON.stringify({ ...item, client: client(), seq: ++seq });
  const post = (delay) => {
    fetch("/input", { method: "POST", headers: { "Content-Type": "application/json" }, body })
      .catch(() => setTimeout(() => post(Math.min(delay * 2, 5000)), delay));
  };
  post(250);
}

const procedures = new Map();

export function define(name, procedure) {
  procedures.set(name, procedure);
}

// Tuna calls a page's procedures through a script it sends, which runs
// outside every module.
window.tuna = {
  call(name, value) {
    const procedure = procedures.get(name);
    if (procedure) procedure(value);
  },
};

// A page kept for the back button may be shown again, and then its
// stream reopens, so only a page that is going away says goodbye.
window.addEventListener("pagehide", (event) => {
  if (!event.persisted) navigator.sendBeacon("/goodbye", JSON.stringify({ client: client() }));
});

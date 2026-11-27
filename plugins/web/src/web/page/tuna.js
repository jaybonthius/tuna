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

function post(url, body, delay = 250) {
  fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body })
    .catch(() => setTimeout(() => post(url, body, Math.min(delay * 2, 5000)), delay));
}

export function send(item) {
  post("/input", JSON.stringify({ ...item, client: client(), seq: ++seq }));
}

// Unlike an item, an upload is not sent again: a stream's data, such as
// audio, is better lost than late.
export function upload(name, bytes) {
  return fetch(`/upload/${name}`, {
    method: "POST",
    headers: { "Content-Type": "application/octet-stream", "Tuna-Client": client() },
    body: bytes,
  });
}

const procedures = new Map();

export function define(name, procedure) {
  procedures.set(name, procedure);
}

// An answer is not an item: the asking command holds the client's
// later items until it comes, so it must not queue behind them.
function answer(id, value) {
  post("/answer", JSON.stringify({ client: client(), id, value: value ?? null }));
}

// Tuna calls a page's procedures through a script it sends, which runs
// outside every module.
window.tuna = {
  call(name, value) {
    const procedure = procedures.get(name);
    if (procedure) procedure(value);
  },
  // The asking command holds its client's keys until an answer comes,
  // so a procedure that throws still answers.
  ask(id, name, value) {
    const procedure = procedures.get(name);
    let result = null;
    try {
      if (procedure) result = procedure(value);
    } finally {
      answer(id, result);
    }
  },
};

// A page kept for the back button may be shown again, and then its
// stream reopens, so only a page that is going away says goodbye.
window.addEventListener("pagehide", (event) => {
  if (!event.persisted) navigator.sendBeacon("/goodbye", JSON.stringify({ client: client() }));
});

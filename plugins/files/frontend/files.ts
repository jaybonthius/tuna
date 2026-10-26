import { getPath } from "datastar";

// The files plugin's page script: when the tab becomes visible or gains
// focus, it asks the server to look at every visited file again, since
// another program may have changed one while the user was away and a
// watch may have missed it. At most one post a second.

let last = 0;

function check(): void {
  if (document.visibilityState !== "visible") return;
  const now = Date.now();
  if (now - last < 1000) return;
  last = now;
  void fetch("/plugin/files/check", {
    method: "POST",
    headers: { "Tuna-Tab": String(getPath("tab")) },
    body: "",
  }).catch(() => undefined);
}

document.addEventListener("visibilitychange", check);
window.addEventListener("focus", check);

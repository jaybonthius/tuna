// Times are milliseconds since the epoch, so that two browsers on one
// machine compare.
const log = { keys: [], morphs: [] };
window.displayMeasure = log;

const now = () => performance.timeOrigin + performance.now();

window.addEventListener("keydown", (event) => {
  log.keys.push({ key: event.key, ctrl: event.ctrlKey, alt: event.altKey, at: performance.timeOrigin + event.timeStamp });
}, true);

// Datastar morphs in its own listener for this event on the document,
// so a capture listener on the window runs before the morph and one
// added to the document meanwhile runs after it.
window.addEventListener("datastar-fetch", (event) => {
  if (event.detail.type !== "datastar-patch-elements") return;
  const start = now();
  const size = String(event.detail.argsRaw?.elements ?? "").length;
  const ended = () => {
    document.removeEventListener("datastar-fetch", ended);
    const end = now();
    requestAnimationFrame(() => {
      const channel = new MessageChannel();
      channel.port1.onmessage = () => log.morphs.push({ start, end, paint: now(), size });
      channel.port2.postMessage(0);
    });
  };
  document.addEventListener("datastar-fetch", ended);
}, true);

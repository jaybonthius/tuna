import { send, define } from "tuna";

document.addEventListener("paste", (event) => {
  event.preventDefault();
  const text = event.clipboardData?.getData("text/plain") ?? "";
  if (text !== "") send({ type: "paste", text });
});

define("copy", (text) => {
  const clipboard = navigator.clipboard;
  if (clipboard === undefined) {
    send({ type: "clipboard", outcome: "unavailable" });
    return;
  }
  clipboard.writeText(text).catch((error) => {
    const name = error?.name;
    send({
      type: "clipboard",
      outcome: "refused",
      reason: typeof name === "string" && /^[A-Za-z]{1,64}$/.test(name) ? name : "Error",
    });
  });
});

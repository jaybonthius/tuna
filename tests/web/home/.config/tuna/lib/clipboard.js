import { send, define } from "tuna";

document.addEventListener("paste", (event) => {
  event.preventDefault();
  send({ type: "paste", text: event.clipboardData.getData("text/plain") });
});

define("copy", (text) => navigator.clipboard.writeText(text));

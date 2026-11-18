import { send, define } from "tuna";

// With noopener, window.open returns null whether or not it opened a
// tab, so the opener is cut afterwards instead.
define("browse-url", (url) => {
  const opened = window.open(url, "_blank");
  if (opened === null) send({ type: "browse-url", url });
  else opened.opener = null;
});

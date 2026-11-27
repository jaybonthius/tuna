import { send } from "tuna";

// Programs ask the terminal for its colours to choose a light or dark
// theme, so the page reports the colours this device's theme and light
// or dark setting give the terminal: a probe styled as a terminal's text
// is read through a canvas, which turns any CSS colour into sRGB bytes.
const probe = document.createElement("div");
probe.className = "terminal";
probe.setAttribute("aria-hidden", "true");
probe.style.cssText = "position: fixed; inset-block-start: -100vh; visibility: hidden; pointer-events: none;";
const names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"];
const faces = [...names, ...names.map((name) => `bright-${name}`)].map((name) => {
  const span = document.createElement("span");
  span.dataset.face = `ansi-colors.${name}`;
  span.textContent = " ";
  probe.append(span);
  return span;
});

const canvas = document.createElement("canvas").getContext("2d", { willReadFrequently: true });

function hex(color) {
  canvas.clearRect(0, 0, 1, 1);
  canvas.fillStyle = "#000";
  canvas.fillStyle = color;
  canvas.fillRect(0, 0, 1, 1);
  const [r, g, b] = canvas.getImageData(0, 0, 1, 1).data;
  return "#" + [r, g, b].map((n) => n.toString(16).padStart(2, "0")).join("");
}

let last = null;

function report() {
  if (!probe.isConnected) document.body.append(probe);
  const style = getComputedStyle(probe);
  const item = {
    type: "terminal-colors",
    foreground: hex(style.color),
    background: hex(style.backgroundColor),
    cursor: hex(style.caretColor),
    palette: faces.map((span) => hex(getComputedStyle(span).color)),
  };
  const text = JSON.stringify(item);
  if (text === last) return;
  last = text;
  send(item);
}

report();
matchMedia("(prefers-color-scheme: dark)").addEventListener("change", report);

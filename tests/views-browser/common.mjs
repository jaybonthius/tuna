import fs from "fs";
import os from "os";
import path from "path";
import { fileURLToPath } from "url";
import playwright from "../browser/playwright.mjs";
import { sleep, startTuna, repl, stopTuna } from "../browser/tuna.mjs";

export { sleep, repl };

const here = path.dirname(fileURLToPath(import.meta.url));

// Read in the page: the selected view and what it shows.
const probe = `
window.__view = () => document.querySelector(".layout-view.selected .view[data-placement]");
window.__state = () => {
  const v = window.__view();
  if (!v) return null;
  const t = window.tunaViews;
  const top = v.getBoundingClientRect().top + v.clientTop;
  const items = t.viewItems(v);
  let first = null;
  for (const item of items) {
    const b = t.box(item);
    if (b && b.bottom > top + 0.5) { first = { text: item.textContent, id: item.id, offset: b.top - top, slot: Number(item.dataset.slot), line: Number(item.dataset.line) }; break; }
  }
  const range = v.scrollHeight - v.clientHeight;
  return {
    id: Number(v.dataset.view), scrollTop: v.scrollTop, scrollLeft: v.scrollLeft, scrollHeight: v.scrollHeight,
    scrollWidth: v.scrollWidth, clientHeight: v.clientHeight, clientWidth: v.clientWidth, offsetWidth: v.offsetWidth,
    offsetHeight: v.offsetHeight, thumb: range > 0 ? v.scrollTop / range : 0, size: v.clientHeight / v.scrollHeight,
    first, measured: t.measured ? t.measured(Number(v.dataset.view)) : 0, slots: Number(v.dataset.slots),
    lineHeight: t.lineHeight(v), drawn: items.length, firstDrawn: items[0]?.textContent, lastDrawn: items.at(-1)?.textContent,
  };
};
// Counts screens and reports, and samples the item at the top in every
// painted frame, so a test sees whether text moved between frames.
window.__screens = 0;
window.__reports = 0;
document.addEventListener("datastar-fetch", (e) => { if (e.detail.type === "datastar-patch-elements") window.__screens++; });
window.__frames = null;
window.__sample = (on) => {
  if (!on) { const f = window.__frames; window.__frames = null; return f; }
  window.__frames = [];
  const tick = () => {
    if (window.__frames === null) return;
    const s = window.__state();
    window.__frames.push(s && { t: performance.now(), scrollTop: s.scrollTop, scrollHeight: s.scrollHeight, first: s.first, drawn: s.drawn });
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
  return true;
};
`;

// A browser with classic scroll bars that take room beside the text, as a
// Linux or Windows desktop's: Playwright hides them unless told not to.
export async function launch(name, { width, height, mobile = false } = {}) {
  const browser = await playwright[name].launch({ ignoreDefaultArgs: ["--hide-scrollbars"] });
  const options = { viewport: { width, height } };
  if (mobile) Object.assign(options, { isMobile: true, hasTouch: true, deviceScaleFactor: 2 });
  const context = await browser.newContext(options);
  await context.addInitScript(probe);
  const page = await context.newPage();
  page.on("pageerror", (e) => console.log(`page error: ${e.message}`));
  // Reports go out as fetches to the page's input route.
  page.on("request", (r) => { if (r.method() === "POST" && /scroll/.test(r.postData() ?? "")) page.__reports = (page.__reports ?? 0) + 1; });
  return { browser, context, page };
}

export function start(bin, name, prepare) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), `tuna-views-${name}-`));
  return startTuna(path.resolve(bin), home, path.join(here, "init.ss"), prepare).then((tuna) => ({ tuna, home }));
}

// The view at ROWS rows of text: the page's height less what the view
// lacks.
export async function fitRows(page, width, rows) {
  const height = () => page.evaluate(() => window.__view().getBoundingClientRect().height);
  const s = await state(page);
  const want = rows * s.lineHeight;
  const viewport = page.viewportSize();
  let at = viewport.height - Math.round((await height()) - want);
  // The chrome around a view may take fractions of a px, and a view a
  // fraction short of its rows hides part of the last.
  for (const tried of [at, at + 1, at - 1]) {
    await page.setViewportSize({ width, height: tried });
    await sleep(100);
    if (Math.abs((await height()) - want) < 0.02) { at = tried; break; }
  }
  await page.setViewportSize({ width, height: at });
  await page.waitForFunction((want) => window.__state().clientHeight === want, want);
  await settle(page);
}

export async function stop({ tuna, home }) {
  await stopTuna(tuna);
  fs.rmSync(home, { recursive: true, force: true });
}

export function state(page) {
  return page.evaluate(() => window.__state());
}

// Waits until no screen has come for QUIET ms, so the page and Tuna have
// settled on a place.
export async function settle(page, quiet = 400, most = 15000) {
  const start = Date.now();
  let last = await page.evaluate(() => window.__screens);
  let since = Date.now();
  while (Date.now() - start < most) {
    await sleep(50);
    const now = await page.evaluate(() => window.__screens);
    if (now !== last) { last = now; since = Date.now(); }
    else if (Date.now() - since >= quiet) return;
  }
}

export async function focusView(page) {
  const s = await page.evaluate(() => { const v = window.__view(); const b = v.getBoundingClientRect(); return { x: b.left + b.width / 2, y: b.top + b.height / 2 }; });
  await page.mouse.move(s.x, s.y);
  return s;
}

export class Results {
  constructor(name) { this.name = name; this.list = []; }
  check(id, ok, note = "") {
    this.list.push({ id, ok });
    console.log(`${ok ? "PASS" : "FAIL"} ${id}${note ? " " + note : ""}`);
  }
  end() {
    const failed = this.list.filter((r) => !r.ok);
    console.log(`${this.name}: ${this.list.length - failed.length} passed, ${failed.length} failed`);
    process.exitCode = failed.length ? 1 : 0;
  }
}

// The view's scroll bar's thumb, found by pressing along the bar and
// seeing where a press drags: the bar draws no element the page can read.
export async function thumbOf(page) {
  const g = await page.evaluate(() => {
    const v = window.__view();
    const b = v.getBoundingClientRect();
    return { top: b.top + v.clientTop, left: b.left + v.clientLeft, cw: v.clientWidth, ch: v.clientHeight, bar: v.offsetWidth - v.clientWidth - 2 * v.clientLeft };
  });
  const x = g.left + g.cw + g.bar / 2;
  const at = await page.evaluate(() => window.__view().scrollTop);
  let start = null;
  let end = null;
  for (let y = 0; y < g.ch; y += 2) {
    await page.mouse.move(x, g.top + y);
    await page.mouse.down();
    const paged = await page.evaluate((at) => window.__view().scrollTop !== at, at);
    await page.mouse.move(x, g.top + y + 3);
    const moved = await page.evaluate((at) => window.__view().scrollTop !== at, at);
    await page.mouse.up();
    if (paged || moved) {
      await page.evaluate((at) => { window.__view().scrollTop = at; }, at);
      await sleep(100);
    }
    const thumb = moved && !paged;
    if (thumb && start === null) start = y;
    if (!thumb && start !== null) { end = y; break; }
  }
  return { x, top: g.top, height: g.ch, start, end };
}

export function browsers() {
  return (process.env.BROWSERS ?? "chromium").split(" ").filter((b) => b !== "");
}

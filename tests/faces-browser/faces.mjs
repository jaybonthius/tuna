import { spawn } from "child_process";
import fs from "fs";
import net from "net";
import os from "os";
import path from "path";
import { fileURLToPath } from "url";
import zlib from "zlib";
import playwright from "../browser/playwright.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
if (!argv[0]) { console.error("usage: node faces.mjs TUNA [--only NAME,...]"); process.exit(2); }
const bin = path.resolve(argv[0]);
const onlyAt = argv.indexOf("--only");
const only = onlyAt >= 0 ? new Set(argv[onlyAt + 1].split(",")) : null;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const FIRA_CODE = '"Fira Code"', FIRA_SANS = '"Fira Sans"';

const home = fs.mkdtempSync(path.join(os.tmpdir(), "tuna-faces-browser-"));
const config = path.join(home, ".config/tuna");
const work = path.join(home, "work");

// Another test may be serving pages at the same time, so no port is fixed.
function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

async function startTuna() {
  fs.mkdirSync(config, { recursive: true });
  fs.mkdirSync(work, { recursive: true });
  fs.copyFileSync(path.join(here, "init.ss"), path.join(config, "init.ss"));
  fs.writeFileSync(path.join(config, "user.css"), "");
  for (const f of ["look.py", "look.sls"]) fs.copyFileSync(path.join(here, f), path.join(work, f));
  fs.mkdirSync(path.join(work, "folder/sub"), { recursive: true });
  for (const f of ["a.txt", "b.txt", "c.txt"]) fs.writeFileSync(path.join(work, "folder", f), f + "\n");
  // treesit finds the grammar it pins where it would have built it, so
  // the test fetches nothing.
  const grammars = path.join(home, ".local/share/tuna/grammars");
  fs.mkdirSync(grammars, { recursive: true });
  const grammar = "libtree-sitter-python-293fdc02038e.so";
  fs.copyFileSync(path.join(path.dirname(path.dirname(bin)), "test-grammars", grammar), path.join(grammars, grammar));
  const library = path.join(home, "library");
  fs.cpSync(path.join(path.dirname(bin), "plugins"), library, { recursive: true });
  const port = await freePort();
  const child = spawn(bin, [`--eval=(options:set! web:port ${port})`],
    { cwd: work, env: { ...process.env, HOME: home, TUNA_LIBRARY: library }, stdio: ["pipe", "pipe", "pipe"] });
  const tuna = { child, url: `http://127.0.0.1:${port}/`, out: "", waiters: [], n: 0 };
  const wake = () => { for (const w of [...tuna.waiters]) w(); };
  const exited = () => child.exitCode !== null || child.signalCode !== null;
  child.stdout.on("data", (d) => { tuna.out += d.toString(); wake(); });
  child.stderr.on("data", (d) => { tuna.out += d.toString(); wake(); });
  child.on("exit", wake);
  const failed = () => /(^|\n)! /.test(tuna.out) || exited();
  try {
    await waitFor(tuna, () => tuna.out.includes("Tuna is at") || failed(), 120000);
    if (failed()) throw new Error("Tuna did not start; output:\n" + tuna.out.slice(-3000));
  } catch (e) {
    // Tuna lives while this script holds its input open, and would write
    // its saved state into the home deleted after this throw.
    if (!exited()) {
      child.kill("SIGKILL");
      await new Promise((r) => child.on("exit", r));
    }
    throw e;
  }
  return tuna;
}

function waitFor(tuna, ok, ms) {
  return new Promise((resolve, reject) => {
    if (ok()) return resolve();
    const check = () => { if (ok()) { clearTimeout(timer); tuna.waiters = tuna.waiters.filter((w) => w !== check); resolve(); } };
    const timer = setTimeout(() => { tuna.waiters = tuna.waiters.filter((w) => w !== check); reject(new Error("timeout; output:\n" + tuna.out.slice(-3000))); }, ms);
    tuna.waiters.push(check);
  });
}

async function repl(tuna, form) {
  const n = ++tuna.n;
  const start = tuna.out.length;
  tuna.child.stdin.write(`(let ([test-value (let () ${form})]) (printf "~%@@~a ~s~%" ${n} test-value))\n`);
  let result = null;
  await waitFor(tuna, () => {
    const text = tuna.out.slice(start);
    const m = text.match(new RegExp(`@@${n} (.*)\\n`));
    if (m) { result = m[1]; return true; }
    // A quit from C-g pressed in the page is reported on the console too.
    const e = text.match(/(^|\n)! (?!&cancelled)(.*)\n/);
    if (e) { result = new Error(e[2]); return true; }
    return false;
  }, 60000);
  if (result instanceof Error) throw result;
  return result;
}

// Tuna's console exits at the end of its input.
async function stopTuna(tuna) {
  tuna.child.stdin.end();
  await Promise.race([new Promise((r) => tuna.child.on("exit", r)), sleep(10000)]);
  if (tuna.child.exitCode === null && tuna.child.signalCode === null) tuna.child.kill("SIGKILL");
}

const probe = `
window.__style = (e) => {
  const s = getComputedStyle(e);
  return { color: s.color, bg: s.backgroundColor, weight: s.fontWeight, style: s.fontStyle,
           family: s.fontFamily.split(",")[0].trim(), size: s.fontSize, line: s.textDecorationLine,
           lstyle: s.textDecorationStyle, lcolor: s.textDecorationColor };
};
window.__item = (text, face) => {
  for (const e of document.querySelectorAll('#screen [data-face="' + face + '"]'))
    if (e.textContent === text) return e;
  return null;
};
window.__at = (text, face) => { const e = window.__item(text, face); return e && window.__style(e); };
window.__sel = (selector) => { const e = document.querySelector(selector); return e && window.__style(e); };
window.__resolved = (property, value) => {
  const d = document.createElement("span");
  d.style.setProperty(property, value);
  document.body.appendChild(d);
  const v = getComputedStyle(d).getPropertyValue(property);
  d.remove();
  return v;
};
`;

let tuna, browser, page;
let userCount = 0;
let themeOn = false;

async function setCase({ theme = false, css = "", scheme = "light" } = {}) {
  const file = `case-${++userCount}.css`;
  fs.writeFileSync(path.join(config, file), css);
  if (theme !== themeOn) { await repl(tuna, `(theme! ${theme ? "#t" : "#f"})`); themeOn = theme; }
  await repl(tuna, `(user-css! "${file}")`);
  await page.emulateMedia({ colorScheme: scheme });
  await page.waitForFunction(([f, theme]) => {
    const links = [...document.querySelectorAll("link[rel=stylesheet]")];
    const user = links.find((l) => l.href.includes(f));
    const modus = links.some((l) => l.href.includes("modus.css"));
    return user && user.sheet && modus === theme && links.every((l) => l.sheet);
  }, [file, theme], { timeout: 30000 });
  await sleep(150);
}

const at = (text, face) => page.evaluate(([t, f]) => window.__at(t, f), [text, face]);
const sel = (s) => page.evaluate((s) => window.__sel(s), s);
const resolved = (property, value) => page.evaluate(([p, v]) => window.__resolved(p, v), [property, value]);

const results = [];
function check(id, ok, note = "") {
  results.push({ id, ok, note });
  console.log(`${ok ? "PASS" : "FAIL"} ${id}${note ? " " + note : ""}`);
}
const want = (id) => !only || only.has(id.split(" ")[0]);

const PROPS = ["color", "bg", "weight", "style", "family", "size", "line"];
const ITEMS = [["if", "keyword"], ["return", "keyword.return"], ["def", "keyword.function"], ["#!r6rs", "keyword.directive"],
  ["err", "error"], ["warn", "warning"], ["succ", "success"], ["^M", "escape-glyph"], ["C-x", "key-binding"],
  ["car", "function.builtin"], ["call", "function.call"], ["get", "function.method.call"], ["fn", "function"],
  [";c", "comment"], [";;;d", "comment.documentation"], ['"d"', "string.documentation"], ['"s"', "string"], ["K", "constant"],
  ["T", "type"], ["int", "type.builtin"], ["mod", "module"], ["@at", "attribute"], ["\\n", "string.escape"], ["+add", "diff.plus"],
  ["H1", "markup.heading.1"], ["H2", "markup.heading.2"], ["H3", "markup.heading.3"], ["H4", "markup.heading.4"],
  ["H5", "markup.heading.5"], ["H6", "markup.heading.6"], ["Hf", "markup.heading"],
  ["S", "markup.strong"], ["Q", "markup.quote"], ["L", "markup.link"], ["U", "markup.underline"], ["I", "markup.italic"], ["raw", "markup.raw"],
  ["derr", "diagnostic.error"], ["dwarn", "diagnostic.warning"], ["dinfo", "diagnostic.info"], ["dhint", "diagnostic.hint"],
  ["dunn", "diagnostic.unnecessary"], ["mt", "match"], ["mo", "match.other"]];

async function readAll() {
  const out = {};
  for (const [t, f] of ITEMS) out[f] = await at(t, f);
  return out;
}

function changed(a, b, skip = [], props = PROPS) {
  return Object.keys(a).filter((k) => !skip.includes(k) && props.some((p) => a[k][p] !== b[k][p]));
}

// No plugin draws a faced strong element, and the Markdown HTML has no
// buffer of its own to show it.
async function injectPage(markdown) {
  await page.evaluate(([html]) => {
    const d = document.createElement("div");
    d.innerHTML = html;
    document.body.appendChild(d);
  }, [`<strong id="ua" data-face="keyword">ua</strong>${markdown}`]);
}

async function main() {
  for (const signal of ["SIGTERM", "SIGINT"]) {
    process.on(signal, () => {
      if (tuna) tuna.child.kill("SIGKILL");
      fs.rmSync(home, { recursive: true, force: true });
      process.exit(1);
    });
  }
  try {
    tuna = await startTuna();
    browser = await playwright.chromium.launch();
    const ctx = await browser.newContext({ viewport: { width: 1400, height: 1000 } });
    await ctx.addInitScript(probe);
    page = await ctx.newPage();
    await page.goto(tuna.url);
    await page.waitForSelector("#screen .view");
    await repl(tuna, "(show-fixture)");
    await page.waitForFunction(() => window.__item("if", "keyword"));
    const md = JSON.parse(await repl(tuna, '(markdown-html "Some `code` here.\\n\\n```\\nblock\\n```\\n")'));
    await injectPage(md);
    await runChecks();
  } finally {
    if (browser) await browser.close();
    if (tuna) await stopTuna(tuna);
    fs.rmSync(home, { recursive: true, force: true });
  }
  const failed = results.filter((r) => !r.ok);
  console.log(`faces-browser: ${results.length - failed.length} passed, ${failed.length} failed`);
  process.exitCode = failed.length ? 1 : 0;
}

const rgb = (s) => { const n = s.match(/[\d.]+/g).slice(0, 3).map(Number); return "#" + n.map((x) => x.toString(16).padStart(2, "0")).join(""); };
const bold = (w) => Number(w) >= 600;

async function showFixture() {
  await repl(tuna, "(show-fixture)");
  await page.waitForFunction(() => window.__item("if", "keyword") && window.__item("rkw", "keyword"));
  await sleep(200);
}

async function runChecks() {
  await setCase();
  const base = await readAll();
  const baseUa = await sel("#ua");

  if (want("family-weight")) {
    await setCase({ css: ":root { --faces-keyword-font-weight: bold; }" });
    const r = await readAll();
    const moved = changed(r, base, ["keyword", "keyword.return", "keyword.function", "keyword.directive"]);
    check("family-weight", ["keyword", "keyword.return", "keyword.function", "keyword.directive"].every((f) => r[f].weight === "700") && moved.length === 0,
      `def/return ${r["keyword.function"].weight}/${r["keyword.return"].weight}; others changed: ${moved}`);
  }
  if (want("member-over-family")) {
    await setCase({ css: ":root { --faces-keyword-font-weight: bold; --faces-keyword-return-font-weight: normal; }" });
    const r = await readAll();
    check("member-over-family", r["keyword.return"].weight === "400" && r["keyword"].weight === "700" && r["keyword.function"].weight === "700");
  }
  await setCase();
  if (want("keyword-in-heading")) {
    const r = await at("hkw", "keyword");
    check("keyword-in-heading", r.weight === "700", `keyword in a heading: ${r.weight}`);
  }
  if (want("own-token")) {
    const values = { color: ["color", "rgb(1, 2, 3)"], background: ["bg", "rgb(4, 5, 6)"], "font-weight": ["weight", "300"],
      "font-style": ["style", "italic"], "font-family": ["family", "serif"], "font-size": ["size", "21px"], "text-decoration": ["line", "overline"] };
    for (const [token, [prop, v]] of Object.entries(values)) {
      await setCase({ css: `:root { --faces-keyword-${token}: ${v}; }` });
      const r = await at("if", "keyword");
      const others = PROPS.filter((p) => p !== prop && r[p] !== base.keyword[p]);
      check(`own-token ${token}`, r[prop] === v && others.length === 0, `${prop}=${r[prop]}; others changed: ${others}`);
    }
    await setCase();
  }
  if (want("messages-faces-bold")) check("messages-faces-bold", ["error", "warning", "success"].every((f) => base[f].weight === "700"),
    ["error", "warning", "success"].map((f) => base[f].weight).join(" "));
  if (want("markdown-code")) {
    const code = await sel(".markdown-code"), block = await sel(".markdown-code-block");
    const size = await resolved("font-size", "var(--tuna-font-size-code)");
    const bg = await resolved("background-color", "var(--tuna-surface-subtle)");
    const raw = base["markup.raw"].color;
    check("markdown-code", [code, block].every((e) => e.family === FIRA_CODE && e.size === size && e.bg === bg && e.color === raw) && bg !== "rgba(0, 0, 0, 0)",
      `code ${code.family} ${code.size} ${code.bg} ${code.color}; block ${block.family} ${block.size} ${block.bg} ${block.color}; `
      + `markdown.css's ${size} ${bg}; markup.raw ${raw}`);
  }
  if (want("face-lists")) {
    const x = await at("x", "markup.strong"), y = await at("y", "markup.raw");
    check("face-lists", x.weight === "700" && x.color === base.keyword.color && y.color === base["markup.raw"].color && y.family === FIRA_CODE,
      `(markup.strong keyword): ${x.weight} ${x.color}; (markup.raw keyword): ${y.color} ${y.family}`);
  }
  if (want("outer-diagnostic")) {
    await setCase({ css: ":root { --tuna-error: rgb(255, 0, 0); --faces-keyword-color: rgb(0, 0, 0); --faces-keyword-text-decoration: none; }" });
    const shot = async () => {
      const box = await page.evaluate(() => {
        const r = window.__item("word", "keyword").getBoundingClientRect();
        return { x: r.left - 2, y: r.top, width: r.width + 4, height: r.height + 4 };
      });
      return redPixels(await page.screenshot({ clip: box }));
    };
    const withLine = await shot();
    await repl(tuna, "(without-outer-diagnostic)");
    await sleep(500);
    const without = await shot();
    await showFixture();
    check("outer-diagnostic", withLine > 20 && without === 0, `red pixels with the diagnostic ${withLine}, without ${without}`);
    await setCase();
  }
  if (want("region-over-faces") || want("matches-over-region")) {
    await repl(tuna, '(region "ab" 0 "rka")');
    await page.waitForFunction(() => document.querySelector("#screen .region"));
    await sleep(300);
    const regionBg = await page.evaluate(() => getComputedStyle(window.__item("rkw", "keyword").closest(".region") || document.querySelector("#screen .region")).backgroundColor);
    const rkw = await at("rkw", "keyword"), rdiff = await at("r+", "diff.plus"), rm = await at("rm", "match"), rk = await at("rka", "keyword");
    const rkBand = await page.evaluate(() => { const e = window.__item("rka", "keyword"); const r = e.parentElement.closest(".region"); return r && getComputedStyle(r).backgroundColor; });
    if (want("region-over-faces")) {
      await setCase({ css: ":root { --faces-keyword-font-weight: bold; --faces-keyword-font-style: italic; --faces-keyword-background: rgb(4, 5, 6); }" });
      const styled = await at("rkw", "keyword");
      check("region-over-faces", rkw.color === base.keyword.color && rdiff.bg === regionBg && styled.weight === "700" && styled.style === "italic" && styled.bg === regionBg,
        `keyword ${rkw.color}; diff.plus bg ${rdiff.bg}; region ${regionBg}; bold italic keyword bg ${styled.bg}`);
      await setCase();
    }
    if (want("matches-over-region")) {
      await repl(tuna, '(region "mmrr" 2 "mmrr")');
      await sleep(400);
      await page.waitForFunction(() => window.__item("mm", "match"));
      // views draws the region outermost, so where the region crosses a
      // match above it, the match is drawn inside the region's piece.
      const inner = await page.evaluate(() => {
        const piece = window.__item("mm", "match").closest(".line").querySelector(".region");
        const m = piece.querySelector('[data-face="match"]');
        return { piece: getComputedStyle(piece).backgroundColor, match: getComputedStyle(m).backgroundColor };
      });
      check("matches-over-region", rm.bg !== "rgba(0, 0, 0, 0)" && rm.bg !== regionBg && rk.bg === "rgba(0, 0, 0, 0)" && rkBand === regionBg
        && inner.piece === regionBg && inner.match === rm.bg,
        `match ${rm.bg}; keyword above ${rk.bg} on band ${rkBand}; region piece ${inner.piece} under a match ${inner.match}`);
    }
    await repl(tuna, "(no-region)");
  }
  if (want("region-under-modus")) {
    await setCase({ theme: true });
    await repl(tuna, '(region "ab" 0 "rka")');
    await sleep(400);
    const r = await at("rkw", "keyword");
    await repl(tuna, "(no-region)");
    check("region-under-modus", r.color === "rgb(0, 0, 0)", `keyword in the region under modus: ${r.color}`);
  }
  if (want("inherit-and-currentcolor")) {
    await setCase({ theme: true });
    const themed = (await at("if", "keyword")).color;
    await setCase({ theme: true, css: ":root { --faces-keyword-color: inherit; }" });
    const inherited = (await at("if", "keyword")).color;
    await setCase({ theme: true, css: ":root { --faces-keyword-color: currentcolor; }" });
    const current = await page.evaluate(() => {
      const e = window.__item("if", "keyword");
      return { own: getComputedStyle(e).color, text: getComputedStyle(e.parentElement).color };
    });
    check("inherit-and-currentcolor", inherited === base.keyword.color && inherited !== themed && current.own === current.text && current.own !== themed,
      `inherit ${inherited}, faces' default ${base.keyword.color}, modus ${themed}; currentcolor ${current.own}, text ${current.text}`);
  }
  if (want("messages-semibold") || want("echo-area-code-font")) {
    await setCase({ theme: true });
    const face = { error: (await at("err", "error")).color, warning: (await at("warn", "warning")).color };
    const shown = {};
    for (const f of ["error", "warning"]) {
      await repl(tuna, `(echo faces:${f} "${f}")`);
      await page.waitForFunction((f) => document.querySelector(`.echo-area-message[data-face="${f}"]`), f);
      shown[`echo ${f}`] = await sel(`.echo-area-message[data-face="${f}"]`);
    }
    // While a prompt waits, the minibuffer shows the echo area's message.
    await page.keyboard.press("Alt+x");
    await page.waitForSelector(".minibuffer-question");
    for (const f of ["error", "warning"]) {
      await repl(tuna, `(echo faces:${f} "${f}")`);
      await page.waitForFunction((f) => document.querySelector(`.minibuffer-message[data-face="${f}"]`), f);
      shown[`minibuffer ${f}`] = await sel(`.minibuffer-message[data-face="${f}"]`);
    }
    await page.keyboard.press("Control+g");
    await page.waitForFunction(() => !document.querySelector(".minibuffer-question"));
    const wrong = Object.entries(shown).filter(([k, s]) => s.weight !== "600" || s.color !== face[k.split(" ")[1]]);
    if (want("messages-semibold")) check("messages-semibold", wrong.length === 0 && face.error !== face.warning,
      `error ${face.error}, warning ${face.warning}; ` + Object.entries(shown).map(([k, s]) => `${k} ${s.weight} ${s.color}`).join(", "));
    await setCase();
    await repl(tuna, '(echo faces:error "Error")');
    await sleep(300);
    const e2 = await sel('.echo-area-message[data-face="error"]');
    if (want("echo-area-code-font")) check("echo-area-code-font", e2.family === FIRA_CODE && e2.size === base.keyword.size, `${e2.family} ${e2.size}`);
  }
  if (want("transient-keys") || want("transient-key-as-key-binding")) {
    await repl(tuna, "(show-menu)");
    await page.waitForFunction(() => document.querySelectorAll(".transient-key").length === 2);
    const menu = await page.evaluate(() => {
      const keys = [...document.querySelectorAll(".transient-key")];
      const read = { keys: keys.map((k) => window.__style(k)), label: window.__sel(".transient-entry .ui-label") };
      // transient draws its keys in keyword, not key-binding (a gap of
      // transient's): this shows what key-binding would give them.
      keys[1].setAttribute("data-face", "key-binding");
      read.asKeyBinding = window.__style(keys[1]);
      return read;
    });
    await repl(tuna, "(hide-menu)");
    await page.waitForFunction(() => !document.querySelector(".transient-key"));
    if (want("transient-keys")) check("transient-keys", menu.keys.every((k) => k.family === FIRA_CODE) && menu.label.family === FIRA_SANS,
      `keys ${menu.keys.map((k) => k.family)}; label ${menu.label.family}`);
    if (want("transient-key-as-key-binding")) check("transient-key-as-key-binding", menu.asKeyBinding.family === FIRA_CODE && menu.asKeyBinding.color === base["key-binding"].color,
      `${menu.asKeyBinding.family} ${menu.asKeyBinding.color}`);
  }
  // find-file's row shows its key and its documentation.
  const rows = async () => {
    await page.keyboard.press("Alt+x");
    await page.waitForSelector(".minibuffer-question");
    await page.keyboard.type("find-fi", { delay: 10 });
    await page.waitForSelector('.completion-column[data-face="shadow"]');
    await page.waitForSelector(".completion-list-count");
    await sleep(400);
    const r = { key: await sel('.completion-column[data-face="keyword"]'), doc: await sel('.completion-column[data-face="shadow"]'),
      count: await sel(".completion-list-count"), match: await sel('.completion-match[data-face^="completion.match"]'),
      prompt: await sel(".minibuffer-question") };
    await page.keyboard.press("Control+g");
    await page.waitForFunction(() => !document.querySelector(".minibuffer-question"));
    await sleep(300);
    return r;
  };
  if (want("annotations-ui-font") || want("completion-count")) {
    const r = await rows();
    const ui = await resolved("font-size", "var(--tuna-font-size-ui)");
    if (want("annotations-ui-font")) check("annotations-ui-font", r.key && [r.key, r.doc].every((c) => c.family === FIRA_SANS && c.size === ui),
      `key ${r.key && r.key.family} ${r.key && r.key.size}; documentation ${r.doc.family} ${r.doc.size}; UI ${ui}`);
    const listSize = await resolved("font-size", "var(--tuna-font-size-1)");
    if (want("completion-count")) check("completion-count", r.count.family === FIRA_SANS && r.count.size === listSize, `${r.count.family} ${r.count.size} (size 1: ${listSize})`);
  }
  if (want("chat-notice") || want("chat-diff")) {
    await repl(tuna, "(show-chat)");
    await page.waitForSelector(".chat-notice");
    await setCase({ css: ":root { --faces-diff-plus-background: rgb(1, 2, 3); }" });
    const n = await sel(".chat-notice"), add = await sel(".chat-added");
    const ui = await resolved("font-size", "var(--tuna-font-size-ui)");
    if (want("chat-notice")) check("chat-notice", n.family === FIRA_SANS && n.size === ui, `${n.family} ${n.size} (UI ${ui}), weight ${n.weight}`);
    if (want("chat-diff")) check("chat-diff", add.bg === "rgb(1, 2, 3)", add.bg);
    await setCase();
  }
  if (want("dired-header") || want("modus-plain") || want("modus-bold-constructs") || want("modus-bold-weight") || want("modus-always-bold") || want("modus-dired-folder")) {
    await repl(tuna, `(show-dired "${path.join(work, "folder")}/")`);
    await page.waitForSelector(".dired-entry");
    await repl(tuna, "(begin (run-command dired:mark 1) (run-command dired:flag-deletion 1) #t)");
    await page.waitForSelector('[data-face="dired.flagged"]');
  }
  const dired = async () => {
    await repl(tuna, `(show-dired "${path.join(work, "folder")}/")`);
    await page.waitForSelector('#screen [data-face="dired.flagged"]');
    await sleep(200);
    const d = { header: await sel('[data-face="dired.header"] .line'), headerFace: await sel('[data-face="dired.header"]'), summary: await sel(".dired-summary"),
      summaryInHeader: await page.evaluate(() => !!document.querySelector('[data-face="dired.header"] .dired-summary')),
      folder: await sel('[data-face="dired.folder"]'), mark: await sel('.dired-entry[data-mark="*"] [data-face="dired.mark"]'),
      marked: await sel('[data-face="dired.marked"]'), flagged: await sel('[data-face="dired.flagged"]') };
    await showFixture();
    return d;
  };
  if (want("dired-header")) {
    await setCase();
    const plain = await dired();
    // A block's text decoration is drawn through its children whatever
    // their own style, so the summary must sit outside the header's face.
    await setCase({ css: ":root { --dired-header-color: rgb(7, 8, 9); --dired-header-font-size: 1.4em; --dired-header-text-decoration: underline; }" });
    const d = await dired();
    check("dired-header", d.header.color === "rgb(7, 8, 9)" && d.headerFace.line === "underline" && d.header.size !== plain.header.size
      && !d.summaryInHeader && d.summary.color === plain.summary.color && d.summary.size === plain.summary.size && d.summary.weight === plain.summary.weight,
      `header ${d.header.color} ${d.headerFace.line} ${d.header.size}; summary ${d.summary.color} ${d.summary.size} ${d.summary.weight}, `
      + `inside the header's face: ${d.summaryInHeader}`);
    await setCase();
  }
  if (want("strong-stays-bold")) check("strong-stays-bold", baseUa.weight === "700", baseUa.weight);
  if (want("method-call")) {
    await repl(tuna, `(options:set! treesit:excluded-captures '())`);
    await repl(tuna, `(visit "${path.join(work, "look.py")}")`);
    await page.waitForFunction(() => window.__item("exists", "function.method.call"), null, { timeout: 60000 });
    const ex = await at("exists", "function.method.call");
    await showFixture();
    const call = await at("call", "function.call");
    await setCase({ theme: true });
    const callModus = await at("call", "function.call"), getModus = await at("get", "function.method.call");
    check("method-call", ex.color === call.color && getModus.color === callModus.color, `exists ${ex.color}, function.call ${call.color}; modus ${getModus.color}/${callModus.color}`);
    await repl(tuna, "(options:set! treesit:excluded-captures default-excluded)");
    await setCase();
  }
  if (want("key-binding")) {
    const k = base["key-binding"];
    const info = await resolved("color", "var(--tuna-info)");
    check("key-binding", k.family === FIRA_CODE && k.color === info && k.bg === "rgba(0, 0, 0, 0)", `${k.family} ${k.color} (info ${info}) bg ${k.bg}`);
  }

  const CONSTRUCTS = ["keyword", "function.builtin", "type", "module", "string.escape", "error", "warning", "success", "escape-glyph"];
  await showFixture();
  await setCase({ theme: true });
  const modus = await readAll();
  if (want("modus-plain")) {
    const weights = CONSTRUCTS.map((f) => [f, modus[f].weight]).filter(([, w]) => w !== "400");
    const slants = ["comment", "comment.documentation", "string.documentation"].filter((f) => modus[f].style !== "normal");
    const d = await dired();
    const r = await rows();
    check("modus-plain", weights.length === 0 && slants.length === 0 && d.header.weight === "400" && d.mark.weight === "400" && r.match.weight === "400",
      `not 400: ${weights}; slanted: ${slants}; dired header ${d.header.weight} mark ${d.mark.weight}; completion match ${r.match.weight}`);
  }
  if (want("modus-keyword-in-heading")) {
    const k = await at("hkw", "keyword"), dir = await at("hdir", "keyword.directive");
    check("modus-keyword-in-heading", k.weight === "700" && dir.weight === "400", `keyword in a heading ${k.weight}; directive ${dir.weight}`);
  }
  if (want("modus-bold-constructs")) {
    await setCase({ theme: true, css: ":root { --modus-bold-constructs: bold; }" });
    const r = await readAll(); const d = await dired(); const c = await rows();
    const notBold = CONSTRUCTS.filter((f) => r[f].weight !== "700");
    const notNormal = ["keyword.directive", "function", "function.call", "string", "constant"].filter((f) => r[f].weight !== "400");
    check("modus-bold-constructs", notBold.length === 0 && notNormal.length === 0 && d.header.weight === "700" && d.mark.weight === "700" && c.match.weight === "700",
      `not bold: ${notBold}; not normal: ${notNormal}; dired header ${d.header.weight} mark ${d.mark.weight}; completion match ${c.match.weight}`);
  }
  if (want("modus-bold-weight")) {
    await setCase({ theme: true, css: ":root { --tuna-font-weight-bold: 600; }" });
    let r = await readAll(); let d = await dired();
    const a = ["markup.heading.1", "markup.strong", "key-binding"].filter((f) => r[f].weight !== "600");
    const aOk = a.length === 0 && d.marked.weight === "600" && d.flagged.weight === "600";
    await setCase({ theme: true, css: ":root { --tuna-font-weight-bold: 600; --modus-bold-constructs: var(--tuna-font-weight-bold); }" });
    r = await readAll(); d = await dired();
    const b = CONSTRUCTS.filter((f) => r[f].weight !== "600");
    check("modus-bold-weight", aOk && b.length === 0, `not 600: ${a}; marked ${d.marked.weight}; with constructs, not 600: ${b}`);
  }
  if (want("modus-italic-constructs")) {
    await setCase({ theme: true, css: ":root { --modus-italic-constructs: italic; }" });
    const r = await readAll();
    const ital = ["comment", "comment.documentation", "string.documentation", "markup.quote"];
    const moved = Object.keys(r).filter((f) => !ital.includes(f) && r[f].style !== modus[f].style);
    check("modus-italic-constructs", ital.every((f) => r[f].style === "italic") && moved.length === 0, `others changed: ${moved}`);
  }
  if (want("modus-always-bold")) {
    await setCase({ theme: true });
    const d = await dired();
    const prompt = (await rows()).prompt;
    const bolds = ["markup.heading.1", "markup.heading.2", "markup.heading.3", "markup.heading.4", "markup.heading.5", "markup.heading.6", "markup.strong", "key-binding"]
      .filter((f) => modus[f].weight !== "700");
    check("modus-always-bold", bolds.length === 0 && d.marked.weight === "700" && d.flagged.weight === "700" && prompt.weight === "700"
      && modus["key-binding"].color === "rgb(166, 0, 0)",
      `not bold: ${bolds}; marked ${d.marked.weight}; prompt ${prompt.weight}; key-binding ${modus["key-binding"].color}`);
  }
  if (want("modus-headings")) {
    const H = { "markup.heading.1": "rgb(0, 0, 0)", "markup.heading.2": "rgb(87, 67, 22)", "markup.heading.3": "rgb(25, 54, 104)",
      "markup.heading.4": "rgb(114, 16, 69)", "markup.heading.5": "rgb(42, 80, 69)", "markup.heading.6": "rgb(127, 0, 0)" };
    const bad = Object.entries(H).filter(([f, c]) => modus[f].color !== c);
    check("modus-headings", bad.length === 0, bad.map(([f]) => `${f} ${modus[f].color}`).join(", "));
  }
  if (want("heading-sizes")) {
    await setCase({ theme: true, css: ":root { --faces-markup-heading-1-font-size: 1.3em; --faces-markup-heading-2-font-size: 1.2em; --faces-markup-heading-3-font-size: 1.1em; }" });
    const r = await readAll();
    const text = parseFloat(base.keyword.size);
    const sizes = [1, 2, 3, 4].map((n) => parseFloat(r[`markup.heading.${n}`].size) / text);
    check("heading-sizes", Math.abs(sizes[0] - 1.3) < 0.01 && Math.abs(sizes[1] - 1.2) < 0.01 && Math.abs(sizes[2] - 1.1) < 0.01 && sizes[3] === 1,
      sizes.map((s) => s.toFixed(2)).join(" "));
  }
  if (want("heading-family-size")) {
    const text = parseFloat(base.keyword.size);
    await setCase({ theme: true, css: ":root { --faces-markup-heading-font-size: 1.1em; }" });
    let r = await readAll();
    const a = [1, 2, 6].map((n) => parseFloat(r[`markup.heading.${n}`].size) / text).concat([parseFloat(r["markup.heading"].size) / text]);
    await setCase({ theme: true, css: ":root { --faces-markup-heading-font-size: 1.1em; --faces-markup-heading-1-font-size: 1.5em; }" });
    r = await readAll();
    const b = [1, 2, 3, 4, 5, 6].map((n) => parseFloat(r[`markup.heading.${n}`].size) / text);
    check("heading-family-size", a.every((x) => Math.abs(x - 1.1) < 0.01) && Math.abs(b[0] - 1.5) < 0.01 && b.slice(1).every((x) => Math.abs(x - 1.1) < 0.01),
      `family 1.1: ${a.map((x) => x.toFixed(2))}; level 1 1.5: ${b.map((x) => x.toFixed(2))}`);
  }
  if (want("modus-underlines")) {
    const LINES = { "markup.link": ["underline", "solid", "rgb(53, 70, 194)"], "markup.underline": ["underline", "solid", "rgb(89, 89, 89)"],
      "diagnostic.error": ["underline", "wavy", "rgb(208, 0, 0)"], "diagnostic.warning": ["underline", "wavy", "rgb(128, 128, 0)"],
      "diagnostic.info": ["underline", "wavy", "rgb(0, 136, 153)"], "diagnostic.hint": ["underline", "wavy", "rgb(0, 136, 153)"],
      "diagnostic.unnecessary": ["underline", "wavy", "rgb(0, 136, 153)"] };
    const bad = Object.entries(LINES).filter(([f, [l, s, c]]) => modus[f].line !== l || modus[f].lstyle !== s || modus[f].lcolor !== c);
    check("modus-underlines", bad.length === 0 && modus["diagnostic.unnecessary"].color === "rgb(0, 0, 0)" && modus.match.color === "rgb(0, 0, 0)" && modus["match.other"].color === "rgb(0, 0, 0)",
      bad.map(([f]) => `${f} ${modus[f].line} ${modus[f].lstyle} ${modus[f].lcolor}`).join(", "));
  }
  if (want("modus-palette")) {
    await setCase({ theme: true, css: ":root { --modus-keyword: var(--modus-fg-main); }" });
    const r = await at("if", "keyword");
    check("modus-palette", r.color === "rgb(0, 0, 0)", r.color);
  }
  if (want("modus-dired-folder")) {
    await setCase({ theme: true });
    const d = await dired();
    check("modus-dired-folder", d.folder.weight === "400", d.folder.weight);
  }
  if (want("stock-modus")) await m13();
}

async function chars(file) {
  await repl(tuna, `(visit "${path.join(work, file)}")`);
  // Highlighting runs in a worker; the file's first keyword shows when done.
  await page.waitForFunction(() => document.querySelector('#screen .view [data-face^="keyword"]'), null, { timeout: 60000 });
  await sleep(800);
  return page.evaluate(() => {
    const view = [...document.querySelectorAll("#screen .view")].find((v) => v.querySelector('[data-face^="keyword"]'));
    const out = [];
    for (const line of view.querySelectorAll(".line")) {
      const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
      for (let n = walker.nextNode(); n; n = walker.nextNode()) {
        const s = getComputedStyle(n.parentElement);
        const face = n.parentElement.closest("[data-face]");
        for (const ch of n.data) out.push([ch, s.color, s.fontWeight, face ? face.getAttribute("data-face") : null]);
      }
      out.push(["\n", null, null, null]);
    }
    return out;
  });
}

function emacsChars(file, n) {
  const out = new Array(n).fill(null);
  for (const line of fs.readFileSync(file, "utf8").split("\n")) {
    if (!line) continue;
    const [s, e, fg, w, face] = line.split("\t");
    for (let i = Number(s); i < Number(e); i++) out[i] = [fg.toLowerCase(), ["bold", "semi-bold", "extra-bold", "ultra-bold"].includes(w) ? "bold" : "normal", face];
  }
  return out;
}

function compare(tuna, tsv, text) {
  const e = emacsChars(tsv, text.length);
  const diffs = [];
  let i = 0;
  while (i < text.length) {
    const t = tuna[i];
    if (/\s/.test(text[i]) || !t || !e[i] || (t[0] === e[i][0] && t[1] === e[i][1])) { i++; continue; }
    let j = i;
    while (j < text.length && !/\s/.test(text[j]) && tuna[j] && tuna[j][0] === t[0] && tuna[j][1] === t[1] && e[j] && e[j][0] === e[i][0] && e[j][1] === e[i][1]) j++;
    diffs.push(`${JSON.stringify(text.slice(i, Math.max(j, i + 1)))} tuna ${t[0]} ${t[1]} ${t[2]} emacs ${e[i][0]} ${e[i][1]} ${e[i][2]}`);
    i = Math.max(j, i + 1);
  }
  return diffs;
}

// chez-scheme tags text that scheme-mode leaves plain: a record type's
// name, its fields, Chez's procedures, #f and a string's escape.
const SCHEME_TAGGED = new Set(["point", "fields", "*", "display", "null?", "list", "car", "#f", "\\n"]);

async function m13() {
  const text = { py: fs.readFileSync(path.join(here, "look.py"), "utf8"), sls: fs.readFileSync(path.join(here, "look.sls"), "utf8") };
  const stock = (name) => path.join(here, "stock", name);
  for (const constructs of ["plain", "bold"]) {
    for (const scheme of ["light", "dark"]) {
      await setCase({ theme: true, scheme, css: constructs === "bold" ? ":root { --modus-bold-constructs: bold; }" : "" });
      for (const [level, excluded] of [[3, null], [4, "'()"]]) {
        if (excluded) await repl(tuna, `(options:set! treesit:excluded-captures ${excluded})`);
        await repl(tuna, '(let ([b (buffers:find "look.py")]) (when b (buffers:kill! b)) #t)');
        const drawn = await chars("look.py");
        const got = drawn.map(([, c, w, f]) => c ? [rgb(c), bold(w) ? "bold" : "normal", f] : null);
        const same = drawn.map(([ch]) => ch).join("").startsWith(text.py.trimEnd());
        const diffs = compare(got, stock(`stock-${scheme}-${constructs}-${level}-py.tsv`), text.py);
        check(`stock-modus python level ${level} ${constructs} ${scheme}`, same && diffs.length === 0, `${same ? "" : "drawn text differs; "}${diffs.join("; ")}`);
        if (excluded) await repl(tuna, "(options:set! treesit:excluded-captures default-excluded)");
      }
      const drawn = await chars("look.sls");
      const got = drawn.map(([, c, w, f]) => c ? [rgb(c), bold(w) ? "bold" : "normal", f] : null);
      if (!drawn.map(([ch]) => ch).join("").startsWith(text.sls.trimEnd())) check(`stock-modus scheme ${constructs} ${scheme} text`, false, "drawn text differs");
      const diffs = compare(got, stock(`stock-${scheme}-${constructs}-3-sls.tsv`), text.sls);
      const unexpected = diffs.filter((d) => !SCHEME_TAGGED.has(JSON.parse(d.slice(0, d.indexOf(" tuna")))));
      check(`stock-modus scheme ${constructs} ${scheme}`, unexpected.length === 0 && diffs.length === 11, `${diffs.length} runs differ, all chez-scheme's tags: ${diffs.map((d) => d.slice(0, d.indexOf(" tuna"))).join(" ")}${unexpected.length ? "; unexpected: " + unexpected.join("; ") : ""}`);
    }
  }
}

// Decoded here rather than with an image library, which would be one
// more dependency for one count.
function redPixels(png) {
  let pos = 8, idat = [], w, h, ctype;
  while (pos < png.length) {
    const n = png.readUInt32BE(pos), t = png.toString("ascii", pos + 4, pos + 8), c = png.subarray(pos + 8, pos + 8 + n);
    if (t === "IHDR") { w = c.readUInt32BE(0); h = c.readUInt32BE(4); ctype = c[9]; }
    if (t === "IDAT") idat.push(c);
    pos += 12 + n;
  }
  const bpp = ctype === 6 ? 4 : 3, raw = zlib.inflateSync(Buffer.concat(idat)), stride = w * bpp;
  let prev = Buffer.alloc(stride), count = 0, i = 0;
  for (let y = 0; y < h; y++) {
    const f = raw[i]; const line = Buffer.from(raw.subarray(i + 1, i + 1 + stride)); i += 1 + stride;
    for (let x = 0; x < stride; x++) {
      const a = x >= bpp ? line[x - bpp] : 0, b = prev[x], cc = x >= bpp ? prev[x - bpp] : 0;
      if (f === 1) line[x] = (line[x] + a) & 255;
      else if (f === 2) line[x] = (line[x] + b) & 255;
      else if (f === 3) line[x] = (line[x] + ((a + b) >> 1)) & 255;
      else if (f === 4) { const p = a + b - cc, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - cc); line[x] = (line[x] + (pa <= pb && pa <= pc ? a : pb <= pc ? b : cc)) & 255; }
    }
    prev = line;
    for (let x = 0; x < stride; x += bpp) if (line[x] > 200 && line[x + 1] < 80 && line[x + 2] < 80) count++;
  }
  return count;
}

main().catch((e) => { console.error(e); process.exitCode = 2; });

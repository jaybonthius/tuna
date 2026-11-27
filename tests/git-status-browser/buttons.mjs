import { spawn, execFileSync } from "child_process";
import fs from "fs";
import net from "net";
import os from "os";
import path from "path";
import { fileURLToPath } from "url";
import playwright from "../browser/playwright.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const bin = path.resolve(process.argv[2] ?? "");
if (!process.argv[2]) { console.error("usage: node buttons.mjs TUNA"); process.exit(2); }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const home = fs.mkdtempSync(path.join(os.tmpdir(), "tuna-git-status-browser-"));
const config = path.join(home, ".config/tuna");
const work = path.join(home, "work");
const gitEnv = { ...process.env, HOME: home, GIT_CONFIG_NOSYSTEM: "1",
  GIT_AUTHOR_NAME: "Tuna", GIT_AUTHOR_EMAIL: "tuna@example.org", GIT_COMMITTER_NAME: "Tuna", GIT_COMMITTER_EMAIL: "tuna@example.org" };

function git(...args) { execFileSync("git", args, { cwd: path.join(work, "repo"), env: gitEnv, stdio: "pipe" }); }

// A scratch repository: a.py changed in the worktree, b.txt staged.
function makeRepository() {
  fs.mkdirSync(path.join(work, "repo"), { recursive: true });
  git("init", "-q", "-b", "main");
  fs.writeFileSync(path.join(work, "repo/a.py"), "one\ntwo\nthree\n");
  fs.writeFileSync(path.join(work, "repo/b.txt"), "alpha\n");
  git("add", "-A"); git("commit", "-qm", "First");
  fs.writeFileSync(path.join(work, "repo/a.py"), "one\nTWO\nthree\n");
  fs.writeFileSync(path.join(work, "repo/b.txt"), "ALPHA\n");
  git("add", "b.txt");
}

// Another test may be serving pages at the same time, so no port is fixed.
function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => { const { port } = server.address(); server.close(() => resolve(port)); });
  });
}

async function startTuna() {
  fs.mkdirSync(config, { recursive: true });
  fs.copyFileSync(path.join(here, "init.ss"), path.join(config, "init.ss"));
  makeRepository();
  const library = path.join(home, "library");
  fs.cpSync(path.join(path.dirname(bin), "plugins"), library, { recursive: true });
  const port = await freePort();
  const child = spawn(bin, [`--eval=(options:set! web:port ${port})`],
    { cwd: work, env: { ...gitEnv, TUNA_LIBRARY: library }, stdio: ["pipe", "pipe", "pipe"] });
  const tuna = { child, url: `http://127.0.0.1:${port}/`, out: "", waiters: [], n: 0 };
  const wake = () => { for (const w of [...tuna.waiters]) w(); };
  child.stdout.on("data", (d) => { tuna.out += d.toString(); wake(); });
  child.stderr.on("data", (d) => { tuna.out += d.toString(); wake(); });
  child.on("exit", wake);
  await waitFor(tuna, () => tuna.out.includes("Tuna is at") || child.exitCode !== null, 120000);
  if (child.exitCode !== null) throw new Error("Tuna did not start; output:\n" + tuna.out.slice(-3000));
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
    const e = text.match(/(^|\n)! (?!&cancelled)(.*)\n/);
    if (e) { result = new Error(e[2]); return true; }
    return false;
  }, 60000);
  if (result instanceof Error) throw result;
  return result;
}

async function stopTuna(tuna) {
  tuna.child.stdin.end();
  await Promise.race([new Promise((r) => tuna.child.on("exit", r)), sleep(10000)]);
  if (tuna.child.exitCode === null && tuna.child.signalCode === null) tuna.child.kill("SIGKILL");
}

const results = [];
function check(id, ok, note = "") {
  results.push({ id, ok, note });
  console.log(`${ok ? "PASS" : "FAIL"} ${id}${note ? " " + note : ""}`);
}

let tuna, browser, page;

const heading = (text) => page.locator("#screen .ui-section-heading", { hasText: text }).first();
const buttonIn = (text, label) => heading(text).locator(".git-status-button", { hasText: label });
const visibility = (locator) => locator.evaluate((e) => getComputedStyle(e).visibility);
const short = async () => JSON.parse(await repl(tuna, "(short)"));

async function waitShort(want) {
  for (let i = 0; i < 300; i++) {
    if ((await short()) === want) return true;
    await sleep(100);
  }
  return false;
}

async function runChecks() {
  await repl(tuna, "(show-status)");
  await heading("modified   a.py").waitFor();
  await page.mouse.move(5, 5);
  const plus = buttonIn("modified   a.py", "+");
  check("hidden away from the pointer", (await visibility(plus)) === "hidden");
  await heading("modified   a.py").hover();
  check("shown under the pointer", (await visibility(plus)) === "visible");
  check("staged row has unstage and discard", (await buttonIn("modified   b.txt", "−").count()) === 1 && (await buttonIn("modified   b.txt", "⟲").count()) === 1);
  check("list heading has buttons", (await buttonIn("Unstaged changes", "+").count()) === 1);
  const before = await repl(tuna, "(point-and-selected)");

  // + stages that row whatever point is; point and the selected
  // view stay.
  await plus.click();
  check("+ stages the row", await waitShort("M  a.py\nM  b.txt\n"));
  await repl(tuna, "(current?)");
  check("point and selection stay", (await repl(tuna, "(point-and-selected)")) === before, before);

  // − unstages it, once the page shows the row staged.
  await heading("Staged changes (2)").waitFor();
  await heading("modified   a.py").hover();
  await buttonIn("modified   a.py", "−").click();
  check("− unstages the row", await waitShort(" M a.py\nM  b.txt\n"));
  await repl(tuna, "(current?)");

  // Hunk headings carry them too.
  await heading("Staged changes (1)").waitFor();
  await repl(tuna, "(show-file! 'unstaged \"a.py\")");
  const hunk = heading("@@ -1,3 +1,3 @@");
  await hunk.waitFor();
  await hunk.hover();
  check("hunk heading has buttons", (await visibility(hunk.locator(".git-status-button", { hasText: "+" }))) === "visible");

  // A heading's text lines up with its body's and with a heading that
  // has no body, the chevron left of them all.
  const lefts = await page.evaluate(() => {
    const lines = [...document.querySelectorAll("#screen .line")];
    const left = (prefix) => lines.find((l) => l.textContent.startsWith(prefix))?.getBoundingClientRect().left;
    return { head: left("Head:"), hunk: left("@@ -1,3"), body: left(" one"),
             chevron: document.querySelector("#screen .ui-section-chevron").getBoundingClientRect().right };
  });
  check("headings and bodies line up", lefts.head !== undefined && lefts.head === lefts.hunk && lefts.hunk === lefts.body
        && lefts.chevron <= lefts.body, JSON.stringify(lefts));

  // ⟲ discards the row, asking first.
  await heading("modified   a.py").hover();
  await buttonIn("modified   a.py", "⟲").click();
  await page.waitForFunction(() => document.body.innerText.includes("Discard unstaged changes"), null, { timeout: 30000 });
  check("⟲ asks first", true);
  await page.keyboard.press("y");
  check("⟲ discards the row", await waitShort("M  b.txt\n"));
  check("the file is restored", fs.readFileSync(path.join(work, "repo/a.py"), "utf8") === "one\ntwo\nthree\n");
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
    const ctx = await browser.newContext({ viewport: { width: 1200, height: 900 } });
    page = await ctx.newPage();
    await page.goto(tuna.url).catch((e) => { throw new Error(e.message + "\n" + tuna.out.slice(-3000)); });
    await page.waitForSelector("#screen .view");
    await runChecks();
  } finally {
    if (browser) await browser.close();
    if (tuna) await stopTuna(tuna);
    fs.rmSync(home, { recursive: true, force: true });
  }
  const failed = results.filter((r) => !r.ok);
  console.log(`git-status-browser: ${results.length - failed.length} passed, ${failed.length} failed`);
  process.exitCode = failed.length ? 1 : 0;
}

main().catch((e) => { console.error(e); process.exitCode = 2; });

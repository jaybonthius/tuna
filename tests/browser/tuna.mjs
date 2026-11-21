import { spawn, execFileSync } from "child_process";
import fs from "fs";
import net from "net";
import path from "path";
import { fileURLToPath } from "url";

const here = path.dirname(fileURLToPath(import.meta.url));

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

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

// Starts BIN in HOME with INIT as its configuration and reads its
// console; PREPARE writes what else the test needs into HOME and WORK,
// Tuna's working folder.
export async function startTuna(bin, home, init, prepare = () => {}) {
  const config = path.join(home, ".config/tuna");
  const work = path.join(home, "work");
  fs.mkdirSync(config, { recursive: true });
  fs.mkdirSync(work, { recursive: true });
  fs.copyFileSync(init, path.join(config, "init.ss"));
  fs.writeFileSync(path.join(config, "user.css"), "");
  prepare(home, work);
  // Some plugins build native code beside their sources, which other
  // tests read from the same build at the same time.
  const library = path.join(home, "library");
  execFileSync("sh", [path.join(here, "../../boot/copy-library.sh"), path.join(path.dirname(bin), "plugins"), library]);
  const port = await freePort();
  const child = spawn(bin, [`--eval=(set-option! web:port ${port})`],
    { cwd: work, env: { ...process.env, HOME: home, TUNA_LIBRARY: library }, stdio: ["pipe", "pipe", "pipe"] });
  const tuna = { child, url: `http://127.0.0.1:${port}/`, out: "", waiters: [], n: 0, work };
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

export function waitFor(tuna, ok, ms) {
  return new Promise((resolve, reject) => {
    if (ok()) return resolve();
    const check = () => { if (ok()) { clearTimeout(timer); tuna.waiters = tuna.waiters.filter((w) => w !== check); resolve(); } };
    const timer = setTimeout(() => { tuna.waiters = tuna.waiters.filter((w) => w !== check); reject(new Error("timeout; output:\n" + tuna.out.slice(-3000))); }, ms);
    tuna.waiters.push(check);
  });
}

// Evaluates FORM at Tuna's console and returns what it printed of its
// value.
export async function repl(tuna, form) {
  const n = ++tuna.n;
  const start = tuna.out.length;
  tuna.child.stdin.write(`(let ([test-value (let () ${form})]) (printf "~%@@~a ~s~%" ${n} test-value))\n`);
  let result = null;
  await waitFor(tuna, () => {
    const text = tuna.out.slice(start);
    const m = text.match(new RegExp(`@@${n} (.*)\\n`));
    if (m) { result = m[1]; return true; }
    // A quit from C-g pressed in the page is reported on the console too.
    const e = text.match(/(^|\n)! (?!&quit)(.*)\n/);
    if (e) { result = new Error(e[2]); return true; }
    return false;
  }, 60000);
  if (result instanceof Error) throw result;
  return result;
}

// Tuna's console exits at the end of its input.
export async function stopTuna(tuna) {
  tuna.child.stdin.end();
  await Promise.race([new Promise((r) => tuna.child.on("exit", r)), sleep(10000)]);
  if (tuna.child.exitCode === null && tuna.child.signalCode === null) tuna.child.kill("SIGKILL");
}

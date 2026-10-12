import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { setImmediate } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import { createContext, SourceTextModule, SyntheticModule } from "node:vm";
import test from "node:test";

const tuna = new URL("../", import.meta.url);
const source = await readFile(new URL("web/tuna-keyboard.js", tuna), "utf8");

class KeyboardEvent extends Event {
  constructor(key, options = {}) {
    const { type = "keydown", ...metadata } = options;
    super(type, { cancelable: true });
    Object.assign(this, {
      key, code: "KeyA", location: 0, repeat: false, isComposing: false,
      altKey: false, ctrlKey: false, metaKey: false, shiftKey: false,
    }, metadata);
  }
}

class MemoryStorage {
  #items = new Map();
  getItem(key) { return this.#items.has(key) ? this.#items.get(key) : null; }
  setItem(key, value) { this.#items.set(key, String(value)); }
}

// Each harness is one page load; tabs share a storage across reloads.
async function harness(sessionStorage = new MemoryStorage()) {
  const posts = [];
  const errors = [];
  let plugin;
  const context = createContext({
    KeyboardEvent,
    sessionStorage,
    crypto: globalThis.crypto,
    Uint8Array,
    fetch(url, options) {
      return new Promise((resolve, reject) => {
        posts.push({ url, options, body: JSON.parse(options.body), resolve, reject });
      });
    },
    console: { error: (...args) => errors.push(args) },
  });
  const datastar = new SyntheticModule(["action"], function () {
    this.setExport("action", (value) => { plugin = value; });
  }, { context });
  const module = new SourceTextModule(source, { context });
  await module.link((specifier) => {
    assert.equal(specifier, "datastar");
    return datastar;
  });
  await module.evaluate();
  assert.equal(plugin.name, "tunaKeyboard");
  return { posts, errors, send: (evt) => plugin.apply({ evt }) };
}

test("committed plugin matches the esbuild recipe", () => {
  const built = execFileSync("esbuild", [
    fileURLToPath(new URL("frontend/tuna-keyboard.ts", tuna)),
    "--bundle", "--external:datastar", "--format=esm", "--minify",
    "--platform=browser", "--target=es2022", "--legal-comments=none",
  ], { encoding: "utf8" });
  assert.equal(built, source);
});

test("every keydown is posted in order, including modifiers and composition", async () => {
  const h = await harness();
  const keys = ["a", "Alt", "Control", "Shift", "Meta", "AltGraph", "Dead", "Process", "Unidentified", "", "é", "Enter"];
  const events = keys.map((key, index) => new KeyboardEvent(key, {
    code: "KeyA", location: index % 4, repeat: index % 2 === 1,
    isComposing: key === "Process", altKey: true, ctrlKey: true,
    metaKey: true, shiftKey: true,
  }));
  events.forEach(h.send);
  assert.equal(h.posts.length, 1, "only one POST may be in flight");
  for (let index = 0; index < events.length; index++) {
    assert.equal(h.posts.length, index + 1);
    const post = h.posts[index];
    const event = events[index];
    assert.equal(post.url, "/commands");
    assert.equal(post.options.method, "POST");
    assert.equal(post.options.credentials, "same-origin");
    assert.equal(post.options.headers["Content-Type"], "application/json");
    assert.equal(post.options.headers["Datastar-Request"], "true");
    assert.deepEqual(post.body, {
      version: 1, type: "keydown", clientId: h.posts[0].body.clientId, sequence: index + 1,
      key: event.key, code: event.code,
      location: event.location, repeat: event.repeat, isComposing: event.isComposing,
      altKey: true, ctrlKey: true, metaKey: true, shiftKey: true,
    });
    assert.equal(event.defaultPrevented, !event.isComposing);
    post.resolve({ status: 204 });
    await setImmediate();
  }
  assert.deepEqual(h.errors, []);
});

test("captures facts immediately and ignores non-keydown events", async () => {
  const h = await harness();
  h.send(undefined);
  h.send(new Event("click"));
  h.send(new Event("keydown"));
  h.send(new KeyboardEvent("a", { type: "keyup" }));
  assert.equal(h.posts.length, 0);
  h.send(new KeyboardEvent("a"));
  const queued = new KeyboardEvent("b");
  h.send(queued);
  queued.key = "changed";
  h.posts[0].resolve({ status: 204 });
  await setImmediate();
  assert.equal(h.posts[1].body.key, "b");
  h.posts[1].resolve({ status: 204 });
  await setImmediate();
});

test("reports rejected and failed requests without replaying them or stopping input", async () => {
  const h = await harness();
  ["a", "b", "c"].forEach((key) => h.send(new KeyboardEvent(key)));
  h.posts[0].resolve({ status: 503 });
  await setImmediate();
  h.posts[1].reject(new Error("connection lost"));
  await setImmediate();
  h.posts[2].resolve({ status: 204 });
  await setImmediate();
  assert.deepEqual(h.posts.map((post) => post.body.key), ["a", "b", "c"]);
  assert.equal(h.errors.length, 2);
  h.send(new KeyboardEvent("d"));
  assert.equal(h.posts[3].body.key, "d");
  h.posts[3].resolve({ status: 204 });
  await setImmediate();
});

test("each tab has its own client id and an increasing sequence across reloads", async () => {
  const tab = new MemoryStorage();
  const first = await harness(tab);
  first.send(new KeyboardEvent("a"));
  first.posts[0].resolve({ status: 204 });
  await setImmediate();
  first.send(new KeyboardEvent("b"));
  const id = first.posts[0].body.clientId;
  assert.match(id, /^[0-9a-f]{32}$/);
  assert.deepEqual(first.posts.map((post) => [post.body.clientId, post.body.sequence]),
                   [[id, 1], [id, 2]]);
  first.posts[1].resolve({ status: 204 });
  await setImmediate();

  const reloaded = await harness(tab);
  reloaded.send(new KeyboardEvent("c"));
  assert.deepEqual([reloaded.posts[0].body.clientId, reloaded.posts[0].body.sequence], [id, 3]);
  reloaded.posts[0].resolve({ status: 204 });
  await setImmediate();

  const other = await harness();
  other.send(new KeyboardEvent("d"));
  assert.notEqual(other.posts[0].body.clientId, id);
  assert.equal(other.posts[0].body.sequence, 1);
  other.posts[0].resolve({ status: 204 });
  await setImmediate();
});

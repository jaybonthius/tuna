import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { setImmediate } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import { createContext, SourceTextModule, SyntheticModule } from "node:vm";
import test from "node:test";

const tuna = new URL("../", import.meta.url);
const source = await readFile(new URL("web/tuna-input.js", tuna), "utf8");

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

class MouseEvent extends Event {
  constructor(type, target, options = {}) {
    super(type, { cancelable: true });
    Object.defineProperty(this, "target", { value: target });
    Object.assign(this, {
      button: 0, detail: 1,
      altKey: false, ctrlKey: false, metaKey: false, shiftKey: false,
    }, options);
  }
}

// Just enough of an element for the pointer action: attributes, a parent,
// closest() for [data-name] selectors, and contains().
class Element {
  constructor(attributes = {}, parent = null) {
    this.attributes = attributes;
    this.parent = parent;
  }
  getAttribute(name) { return name in this.attributes ? String(this.attributes[name]) : null; }
  closest(selector) {
    const name = selector.match(/^\[([a-z-]+)\]$/)[1];
    for (let e = this; e !== null; e = e.parent) if (name in e.attributes) return e;
    return null;
  }
  contains(other) {
    for (let e = other; e !== null; e = e.parent) if (e === this) return true;
    return false;
  }
}

class MemoryStorage {
  #items = new Map();
  getItem(key) { return this.#items.has(key) ? this.#items.get(key) : null; }
  setItem(key, value) { this.#items.set(key, String(value)); }
}

// Each harness is one page load; tabs share a storage across reloads.
async function harness(sessionStorage = new MemoryStorage(), screen = new Element({ "data-revision": 7 })) {
  const posts = [];
  const errors = [];
  const actions = {};
  const context = createContext({
    KeyboardEvent,
    MouseEvent,
    Element,
    document: { getElementById: (id) => (id === "screen" ? screen : null) },
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
    this.setExport("action", (value) => { actions[value.name] = value; });
  }, { context });
  const module = new SourceTextModule(source, { context });
  await module.link((specifier) => {
    assert.equal(specifier, "datastar");
    return datastar;
  });
  await module.evaluate();
  assert.deepEqual(Object.keys(actions).sort(), ["tunaKeyboard", "tunaPointer"]);
  return {
    posts, errors,
    send: (evt) => actions.tunaKeyboard.apply({ evt }),
    point: (evt) => actions.tunaPointer.apply({ evt }),
  };
}

test("committed plugin matches the esbuild recipe", () => {
  const built = execFileSync("esbuild", [
    fileURLToPath(new URL("frontend/tuna-input.ts", tuna)),
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

// A screen with a tab, and a view holding a text node: the markup the
// server sends, reduced to the attributes the pointer action reads.
function screenParts() {
  const screen = new Element({ id: "screen", "data-revision": 7 });
  const tab = new Element({ "data-part": "tab:30", "data-clickable": "" }, screen);
  const view = new Element({ "data-part": "view:12" }, screen);
  const node = new Element({ "data-node": 4 }, view);
  const line = new Element({}, node);
  const statusLine = new Element({ "data-part": "status-line:12" }, view);
  const outside = new Element({}, screen);
  return { screen, tab, view, node, line, statusLine, outside };
}

test("a click is sent on release as a pointer item naming its part, node and screen", async () => {
  const parts = screenParts();
  const h = await harness(new MemoryStorage(), parts.screen);
  h.point(new MouseEvent("click", parts.tab));
  h.point(new MouseEvent("click", parts.line, { detail: 2, ctrlKey: true }));
  h.point(new MouseEvent("auxclick", parts.statusLine, { button: 2, shiftKey: true }));
  const expected = [
    { button: 0, clicks: 1, target: "tab:30", node: null,
      modifiers: { alt: false, ctrl: false, meta: false, shift: false } },
    { button: 0, clicks: 2, target: "view:12", node: 4,
      modifiers: { alt: false, ctrl: true, meta: false, shift: false } },
    { button: 2, clicks: 1, target: "status-line:12", node: null,
      modifiers: { alt: false, ctrl: false, meta: false, shift: true } },
  ];
  for (let index = 0; index < expected.length; index++) {
    assert.equal(h.posts.length, index + 1, "one POST in flight at a time");
    assert.deepEqual(h.posts[index].body, {
      version: 1, type: "pointer", kind: "click", clientId: h.posts[0].body.clientId,
      sequence: index + 1, revision: 7, ...expected[index],
    });
    h.posts[index].resolve({ status: 204 });
    await setImmediate();
  }
  assert.deepEqual(h.errors, []);
});

test("keys and clicks share one queue, client id and sequence, in the order they happened", async () => {
  const parts = screenParts();
  const h = await harness(new MemoryStorage(), parts.screen);
  h.send(new KeyboardEvent("a"));
  h.point(new MouseEvent("click", parts.tab));
  h.send(new KeyboardEvent("b"));
  for (let index = 0; index < 3; index++) {
    h.posts[index].resolve({ status: 204 });
    await setImmediate();
  }
  assert.deepEqual(h.posts.map((post) => [post.body.type, post.body.sequence]),
                   [["keydown", 1], ["pointer", 2], ["keydown", 3]]);
  assert.equal(new Set(h.posts.map((post) => post.body.clientId)).size, 1);
});

test("clicks outside parts, other buttons, and screens without a revision send nothing", async () => {
  const parts = screenParts();
  const h = await harness(new MemoryStorage(), parts.screen);
  h.point(new MouseEvent("click", parts.outside));
  h.point(new MouseEvent("auxclick", parts.tab, { button: 3 }));
  h.point(new MouseEvent("mouseup", parts.tab));
  h.point(new Event("click"));
  delete parts.screen.attributes["data-revision"];
  h.point(new MouseEvent("click", parts.tab));
  assert.equal(h.posts.length, 0);
});

test("pressing on chrome keeps focus and the context menu away; inside text nodes it does not", async () => {
  const parts = screenParts();
  const h = await harness(new MemoryStorage(), parts.screen);
  const pressed = (target, type = "mousedown") => {
    const evt = new MouseEvent(type, target);
    h.point(evt);
    return evt.defaultPrevented;
  };
  assert.equal(pressed(parts.tab), true);
  assert.equal(pressed(parts.statusLine), true);
  assert.equal(pressed(parts.view), true);
  assert.equal(pressed(parts.tab, "contextmenu"), true);
  assert.equal(pressed(parts.line), false);
  assert.equal(pressed(parts.line, "contextmenu"), false);
  assert.equal(pressed(parts.outside), false);
  assert.equal(h.posts.length, 0, "a press alone sends nothing");
});

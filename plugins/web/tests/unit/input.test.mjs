import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { setImmediate } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import { createContext, SourceTextModule, SyntheticModule } from "node:vm";
import test from "node:test";

const tuna = new URL("../../", import.meta.url);
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
  getModifierState(name) { return name === "AltGraph" && (this.altGraph ?? false); }
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

// Each harness is one page load, with no browser storage or identity.
async function harness(screen = new Element({ "data-revision": 7 }), platform = "Linux x86_64") {
  const posts = [];
  const errors = [];
  const retries = [];
  const actions = {};
  const listeners = {};
  const fire = (evt) => (listeners[evt.type] ?? []).forEach((listener) => listener(evt));
  const context = createContext({
    navigator: { platform },
    window: { addEventListener(type, listener) { (listeners[type] ??= []).push(listener); } },
    KeyboardEvent,
    MouseEvent,
    Element,
    document: { getElementById: (id) => (id === "screen" ? screen : null) },
    setTimeout(callback, delay) { retries.push({ callback, delay }); },
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
    posts, errors, retries,
    fire,
    send: (evt) => { if (evt instanceof KeyboardEvent) fire(evt); actions.tunaKeyboard.apply({ evt }); },
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

test("every keydown is posted immediately, including modifiers and composition", async () => {
  const h = await harness();
  const keys = ["a", "Alt", "Control", "Shift", "Meta", "AltGraph", "Dead", "Process", "Unidentified", "", "é", "Enter"];
  const events = keys.map((key, index) => new KeyboardEvent(key, {
    code: "KeyA", location: key === "Alt" ? 0 : index % 4, repeat: index % 2 === 1,
    isComposing: key === "Process", altKey: true, ctrlKey: true,
    metaKey: true, shiftKey: true,
  }));
  events.forEach(h.send);
  assert.equal(h.posts.length, events.length, "all POSTs are in flight before any response");
  for (let index = 0; index < events.length; index++) {
    const post = h.posts[index];
    const event = events[index];
    assert.equal(post.url, "/commands");
    assert.equal(post.options.method, "POST");
    assert.equal(post.options.headers["Content-Type"], "application/json");
    assert.equal(post.options.headers["Datastar-Request"], "true");
    assert.deepEqual(post.body, {
      version: 1, type: "keydown", sequence: index + 1,
      key: event.key, code: event.code,
      location: event.location, repeat: event.repeat, isComposing: event.isComposing,
      altKey: true, ctrlKey: true, metaKey: true, shiftKey: true,
      isMac: false, altLeft: false, altRight: false, altGraph: false,
    });
    assert.equal(event.defaultPrevented, !event.isComposing);
    post.resolve({ status: 204 });
    await setImmediate();
  }
  assert.deepEqual(h.errors, []);
});

test("Option sides are captured at keydown, released independently and cleared on blur", async () => {
  const h = await harness(undefined, "MacIntel");
  const alt = (code, type = "keydown") => new KeyboardEvent("Alt", { code, type, altKey: type === "keydown" });
  h.send(alt("AltLeft"));
  h.send(new KeyboardEvent("≈", { code: "KeyX", altKey: true }));
  h.send(alt("AltRight"));
  h.send(new KeyboardEvent("Dead", { code: "KeyE", altKey: true, repeat: true }));
  h.send(alt("AltLeft", "keyup"));
  h.send(new KeyboardEvent("≈", { code: "KeyX", altKey: true }));
  h.send(alt("AltRight", "keyup"));
  h.send(new KeyboardEvent("x", { code: "KeyX" }));
  h.send(alt("AltRight"));
  h.fire(new Event("blur"));
  h.send(new KeyboardEvent("≈", { code: "KeyX", altKey: true }));
  h.send(new KeyboardEvent("Alt", { code: "", location: 1, altKey: true }));
  h.send(new KeyboardEvent("x", { altKey: false }));
  const expected = [
    ["Alt", true, false], ["≈", true, false], ["Alt", true, true], ["Dead", true, true],
    ["≈", false, true], ["x", false, false], ["Alt", false, true], ["≈", false, false],
    ["Alt", true, false], ["x", false, false],
  ];
  for (let index = 0; index < expected.length; index++) {
    const post = h.posts[index];
    assert.equal(post.body.isMac, true);
    assert.equal(post.body.altGraph, false);
    assert.deepEqual([post.body.key, post.body.altLeft, post.body.altRight], expected[index]);
    assert.equal(post.body.sequence, index + 1, "keyup and blur never enter the ordered queue");
    post.resolve({ status: 204 });
    await setImmediate();
  }
  assert.equal(h.posts.length, expected.length);
});

test("location fallback tracks right Option and keyup, and AltGraph is a browser fact", async () => {
  const h = await harness(undefined, "Win32");
  h.send(new KeyboardEvent("Alt", { code: "", location: 2, altKey: true }));
  h.send(new KeyboardEvent("@", { code: "KeyQ", ctrlKey: true, altKey: true, altGraph: true }));
  h.send(new KeyboardEvent("Alt", { type: "keyup", code: "", location: 2 }));
  h.send(new KeyboardEvent("q"));
  for (let index = 0; index < 3; index++) {
    const post = h.posts[index];
    assert.equal(post.body.isMac, false);
    assert.equal(post.body.altLeft, false);
    assert.equal(post.body.altRight, index !== 2);
    assert.equal(post.body.altGraph, index === 1);
    post.resolve({ status: 204 });
    await setImmediate();
  }
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

test("only network failures retry the same item; later items do not wait", async () => {
  const h = await harness();
  ["a", "b", "c"].forEach((key) => h.send(new KeyboardEvent(key)));
  assert.equal(h.posts.length, 3);
  h.posts[0].resolve({ status: 503 });
  h.posts[1].reject(new Error("connection lost"));
  h.posts[2].resolve({ status: 204 });
  await setImmediate();
  assert.equal(h.retries.length, 1, "HTTP errors are responses, not network failures");
  assert.equal(h.retries[0].delay, 250);
  h.send(new KeyboardEvent("d"));
  assert.equal(h.posts[3].body.sequence, 4);
  h.retries.shift().callback();
  assert.equal(h.posts[4].options.body, h.posts[1].options.body);
  h.posts[4].reject(new Error("still offline"));
  await setImmediate();
  h.retries.shift().callback();
  assert.equal(h.posts[5].options.body, h.posts[1].options.body);
  h.posts[5].resolve({ status: 400 });
  await setImmediate();
  assert.equal(h.retries.length, 0, "any response stops retries");
});

test("a page load restarts numbering at one without a client id or storage", async () => {
  const first = await harness();
  first.send(new KeyboardEvent("a"));
  first.send(new KeyboardEvent("b"));
  assert.deepEqual(first.posts.map((post) => post.body.sequence), [1, 2]);
  assert.equal("clientId" in first.posts[0].body, false);
  const reloaded = await harness();
  reloaded.send(new KeyboardEvent("c"));
  assert.equal(reloaded.posts[0].body.sequence, 1);
});

// A screen with a tab, and a view holding a text node: the markup the
// server sends, reduced to the attributes the pointer action reads.
function screenParts() {
  const screen = new Element({ id: "screen", "data-revision": 7 });
  const tab = new Element({ "data-part": "tab-line:30", "data-clickable": "" }, screen);
  const view = new Element({ "data-part": "view:12" }, screen);
  const node = new Element({ "data-node": 4 }, view);
  const line = new Element({}, node);
  const statusLine = new Element({ "data-part": "status-line:12" }, view);
  const outside = new Element({}, screen);
  return { screen, tab, view, node, line, statusLine, outside };
}

test("a click is sent on release as a pointer item naming its part, node and screen", async () => {
  const parts = screenParts();
  const h = await harness(parts.screen);
  h.point(new MouseEvent("click", parts.tab));
  h.point(new MouseEvent("click", parts.line, { detail: 2, ctrlKey: true }));
  h.point(new MouseEvent("auxclick", parts.statusLine, { button: 2, shiftKey: true }));
  const expected = [
    { button: 0, clicks: 1, target: "tab-line:30", node: null,
      modifiers: { alt: false, ctrl: false, meta: false, shift: false } },
    { button: 0, clicks: 2, target: "view:12", node: 4,
      modifiers: { alt: false, ctrl: true, meta: false, shift: false } },
    { button: 2, clicks: 1, target: "status-line:12", node: null,
      modifiers: { alt: false, ctrl: false, meta: false, shift: true } },
  ];
  for (let index = 0; index < expected.length; index++) {
    assert.equal(h.posts.length, expected.length, "all clicks are sent before any response");
    assert.deepEqual(h.posts[index].body, {
      version: 1, type: "pointer", kind: "click",
      sequence: index + 1, revision: 7, ...expected[index],
    });
    h.posts[index].resolve({ status: 204 });
    await setImmediate();
  }
  assert.deepEqual(h.errors, []);
});

test("keys and clicks send immediately with one shared sequence", async () => {
  const parts = screenParts();
  const h = await harness(parts.screen);
  h.send(new KeyboardEvent("a"));
  h.point(new MouseEvent("click", parts.tab));
  h.send(new KeyboardEvent("b"));
  for (let index = 0; index < 3; index++) {
    h.posts[index].resolve({ status: 204 });
    await setImmediate();
  }
  assert.deepEqual(h.posts.map((post) => [post.body.type, post.body.sequence]),
                   [["keydown", 1], ["pointer", 2], ["keydown", 3]]);
  assert.equal(h.posts.length, 3);
});

test("clicks outside parts, other buttons, and screens without a revision send nothing", async () => {
  const parts = screenParts();
  const h = await harness(parts.screen);
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
  const h = await harness(parts.screen);
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

test("pressing on a node marked clickable, such as a button, keeps focus; its click names the node", async () => {
  const parts = screenParts();
  const button = new Element({ "data-node": 9, "data-clickable": "" }, parts.node);
  const label = new Element({}, button);
  const h = await harness(parts.screen);
  const evt = new MouseEvent("mousedown", label);
  h.point(evt);
  assert.equal(evt.defaultPrevented, true);
  assert.equal(h.posts.length, 0, "a press alone sends nothing");
  h.point(new MouseEvent("click", label));
  assert.equal(h.posts[0].body.target, "view:12");
  assert.equal(h.posts[0].body.node, 9);
});

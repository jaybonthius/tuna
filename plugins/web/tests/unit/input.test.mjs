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
    // An attribute given as undefined is left out.
    this.attributes = Object.fromEntries(Object.entries(attributes).filter(([, value]) => value !== undefined));
    this.parent = parent;
  }
  getAttribute(name) { return name in this.attributes ? String(this.attributes[name]) : null; }
  // Whether this element matches SELECTOR: [name], [name="value"] or .class.
  matches(selector) {
    const attribute = selector.match(/^\[([a-z-]+)(?:="([^"]*)")?\]$/);
    if (attribute) {
      return attribute[1] in this.attributes
        && (attribute[2] === undefined || this.getAttribute(attribute[1]) === attribute[2]);
    }
    const name = selector.match(/^\.([a-z-]+)$/)[1];
    return String(this.attributes.class ?? "").split(" ").includes(name);
  }
  closest(selector) {
    for (let e = this; e !== null; e = e.parent) if (e.matches(selector)) return e;
    return null;
  }
  contains(other) {
    for (let e = other; e !== null; e = e.parent) if (e === this) return true;
    return false;
  }
}

// Each harness is one page load, with no browser storage; its page shell's
// `tab` signal is TAB.
async function harness(screen = new Element({ "data-revision": 7 }), platform = "Linux x86_64",
                       elementFromPoint = () => null, tab = "tab-1") {
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
    Event,
    WeakMap,
    WeakSet,
    clearTimeout() {},
    document: { getElementById: (id) => (id === "screen" ? screen : null), elementFromPoint },
    setTimeout(callback, delay) { retries.push({ callback, delay }); },
    fetch(url, options) {
      return new Promise((resolve, reject) => {
        posts.push({ url, options, body: JSON.parse(options.body), resolve, reject });
      });
    },
    console: { error: (...args) => errors.push(args) },
  });
  const datastar = new SyntheticModule(["action", "getPath"], function () {
    this.setExport("action", (value) => { actions[value.name] = value; });
    this.setExport("getPath", (path) => (path === "tab" ? tab : undefined));
  }, { context });
  const module = new SourceTextModule(source, { context });
  await module.link((specifier) => {
    assert.equal(specifier, "datastar");
    return datastar;
  });
  await module.evaluate();
  assert.deepEqual(Object.keys(actions).sort(),
                   ["tunaKeyboard", "tunaPlace", "tunaPointer", "tunaScroll"]);
  return {
    posts, errors, retries,
    fire,
    send: (evt) => { if (evt instanceof KeyboardEvent) fire(evt); actions.tunaKeyboard.apply({ evt }); },
    point: (evt) => actions.tunaPointer.apply({ evt }),
    scroll: (el, reason) => actions.tunaScroll.apply({ el }, reason),
    place: (el) => actions.tunaPlace.apply({ el }),
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
      version: 1, tab: "tab-1", type: "keydown", sequence: index + 1,
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

test("a page load restarts numbering at one, under the tab id its page shell made", async () => {
  const first = await harness();
  first.send(new KeyboardEvent("a"));
  first.send(new KeyboardEvent("b"));
  assert.deepEqual(first.posts.map((post) => [post.body.tab, post.body.sequence]),
                   [["tab-1", 1], ["tab-1", 2]]);
  const reloaded = await harness(undefined, undefined, undefined, "tab-2");
  reloaded.send(new KeyboardEvent("c"));
  assert.deepEqual([reloaded.posts[0].body.tab, reloaded.posts[0].body.sequence], ["tab-2", 1]);
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
      version: 1, tab: "tab-1", type: "pointer", kind: "click",
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

// A laid-out element for the scroll actions. Boxes inside a scroller are
// placed in its content: TOP px below the content's top, HEIGHT px tall;
// the scroller's own box is TOP px below the viewport's top.
class Box extends Element {
  constructor(attributes, parent, top, height) {
    super(attributes, parent);
    Object.assign(this, { top, height, children: [], events: [] });
    parent?.children?.push(this);
  }
  get parentElement() { return this.parent; }
  get scroller() { for (let e = this.parent; e; e = e.parent) if (e instanceof Scroller) return e; return null; }
  getBoundingClientRect() {
    const sc = this.scroller;
    const top = sc ? sc.top + this.top - sc.scrollTop : this.top;
    return { top, bottom: top + this.height, height: this.height, left: 0, width: 300 };
  }
  hasAttribute(name) { return name in this.attributes; }
  removeAttribute(name) { delete this.attributes[name]; }
  querySelectorAll(selector) {
    const found = [];
    const walk = (e) => e.children.forEach((child) => { if (child.matches(selector)) found.push(child); walk(child); });
    walk(this);
    return found;
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] ?? null; }
  dispatchEvent(evt) { this.events.push(evt.type); }
}

// A view's scroller: its box is CLIENTHEIGHT px tall at the viewport's
// top, and it scrolls its content, SCROLLHEIGHT px of it.
class Scroller extends Box {
  constructor(attributes, parent, clientHeight, scrollHeight) {
    super(attributes, parent, 0, clientHeight);
    Object.assign(this, { clientTop: 0, clientHeight, clientWidth: 300, scrollHeight, position: 0 });
  }
  get scrollTop() { return this.position; }
  set scrollTop(y) { this.position = Math.max(0, Math.min(y, this.scrollHeight - this.clientHeight)); }
  getBoundingClientRect() { return { top: this.top, bottom: this.top + this.height, height: this.height, left: 0, width: 300 }; }
}

// View 12's 200 px scroller drawing node 4: 100 items of 20 px, tokens
// "4.1.0" to "4.100.0", with a placement marker for placement 3 putting
// "4.51.0" 5 px above the top edge, asking for 3 view heights drawn each
// way. ATTRIBUTES go on the scroller.
function scrolledView(attributes = {}, marker = {}) {
  const view = new Box({ "data-view": 12 }, null, 0, 200);
  const scroller = new Scroller({
    "data-effect": "...", "data-scroll-root": 4, "data-drawn-screens": 3,
    "data-measured-width": 300, "data-measured-height": 200, ...attributes,
  }, view, 200, 2000);
  const placement = new Box({ class: "placement", "data-placement": 3, "data-target": "4.51.0", "data-align": "top",
                              "data-offset": "5.", ...marker }, scroller, 0, 0);
  const text = new Box({ "data-node": 4 }, scroller, 0, 2000);
  const items = [];
  for (let k = 1; k <= 100; k++) items.push(new Box({ "data-item": `4.${k}.0` }, text, 20 * (k - 1), 20));
  return { view, scroller, placement, items };
}

// View 12's scroller drawing items 51 to 150 of node 4, 20 px each, from
// 1,000 to 3,000 px into its content, between a 1,000 px spacer above and
// a 2,000 px spacer below; placed with item 51 at its top.
function spacedView() {
  const view = new Box({ "data-view": 12 }, null, 0, 200);
  const scroller = new Scroller({
    "data-effect": "...", "data-scroll-root": 4, "data-drawn-screens": 3,
    "data-measured-width": 300, "data-measured-height": 200,
  }, view, 200, 5000);
  const placement = new Box({ class: "placement", "data-placement": 3, "data-target": "4.51.0", "data-align": "top",
                              "data-offset": "0" }, scroller, 0, 0);
  const above = new Box({ class: "spacer", "data-spacer": "above" }, scroller, 0, 1000);
  const text = new Box({ "data-node": 4 }, scroller, 1000, 2000);
  for (let k = 51; k <= 150; k++) new Box({ "data-item": `4.${k}.0` }, text, 1000 + 20 * (k - 51), 20);
  const below = new Box({ class: "spacer", "data-spacer": "below" }, scroller, 3000, 2000);
  return { view, scroller, placement, above, below };
}

test("tunaPlace puts the marker's item at the top, centre or bottom of its scroller", async () => {
  const h = await harness();
  const at = (marker) => { const v = scrolledView({}, marker); h.place(v.placement); return v.scroller.scrollTop; };
  assert.equal(at({}), 1005);
  assert.equal(at({ "data-offset": "-8" }), 992);
  assert.equal(at({ "data-align": "center", "data-offset": "0" }), 1000 + 10 - 100);
  assert.equal(at({ "data-align": "bottom", "data-offset": "0" }), 1000 + 20 - 200);
  // Beyond the content, the browser stops at its end.
  assert.equal(at({ "data-target": "4.100.0" }), 1800);
  // Without a target, to the start of the view, wherever it was; with one
  // not drawn, the view stays where it is.
  const moved = scrolledView({}, { "data-target": undefined });
  moved.scroller.scrollTop = 300;
  h.place(moved.placement);
  assert.equal(moved.scroller.scrollTop, 0);
  const missing = scrolledView({}, { "data-target": "4.999.0" });
  missing.scroller.scrollTop = 300;
  h.place(missing.placement);
  assert.equal(missing.scroller.scrollTop, 300);
  const v = scrolledView();
  h.place(v.placement);
  assert.deepEqual(v.scroller.events, ["scroll"], "the scroller's report trigger runs");
  assert.equal(h.posts.length, 0);
});

test("tunaScroll reports nothing before a placement, then what it measured, once at a time", async () => {
  const v = scrolledView();
  const h = await harness(new Element({ "data-revision": 7 }));
  h.scroll(v.scroller, "moved");
  h.scroll(v.scroller, "rest");
  assert.equal(h.posts.length, 0, "a page reports only once it placed the view");
  h.place(v.placement);
  h.scroll(v.scroller, "moved");
  assert.equal(h.posts.length, 1);
  assert.deepEqual(h.posts[0].body, {
    version: 1, tab: "tab-1", type: "scroll", sequence: 1, revision: 7, view: 12, node: 4, placement: 3,
    top: "4.51.0", offset: 5, lastVisible: "4.60.0", spacer: null, spacerDistance: 0,
    before: 50, after: 49, drawnHeight: 2000, above: 1005, below: 795, width: 300, height: 200,
  }, "item 61 ends 15 px below the view, so item 60 is the last wholly in view");
  assert.equal(v.scroller.getAttribute("data-effect"), null, "one report is on its way at a time");
  h.scroll(v.scroller, "moved");
  assert.equal(h.posts.length, 1);
});

test("tunaScroll reports when drawn px run short or long, the size changed, or scrolling ended", async () => {
  const h = await harness(new Element({ "data-revision": 7 }));
  // Placed and reported once: nothing more is owed.
  const settled = (attributes = {}) => {
    const v = scrolledView(attributes);
    h.place(v.placement);
    h.scroll(v.scroller, "moved");
    v.scroller.attributes["data-effect"] = "...";
    return v;
  };
  const reports = (v, reason = "moved") => {
    const before = h.posts.length;
    h.scroll(v.scroller, reason);
    return h.posts.length - before;
  };
  // 1,005 px above and 795 below, against 3 view heights, 600 px, each
  // way: within the band.
  assert.equal(reports(settled()), 0);
  assert.equal(reports(settled(), "rest"), 1);
  // Short above (less than half of 600), unless the first item is drawn.
  const short = settled();
  short.scroller.scrollTop = 150;
  assert.equal(reports(short), 1);
  const atStart = settled({ "data-run-at-start": "", "data-drawn-screens": 5 });
  atStart.scroller.scrollTop = 150;
  assert.equal(reports(atStart), 0);
  // Short below (less than half of 10 view heights), unless the last item is drawn.
  const low = settled({ "data-drawn-screens": 10 });
  assert.equal(reports(low), 1);
  assert.equal(reports(settled({ "data-drawn-screens": 10, "data-run-at-end": "" })), 0);
  // Long above: more than twice what is asked for, and an item far enough
  // beyond the edge to drop.
  assert.equal(reports(settled({ "data-drawn-screens": 1.5 })), 1);
  // The size changed, or the server has not heard it yet.
  assert.equal(reports(settled({ "data-measured-height": 744 })), 1);
  assert.equal(reports(settled({ "data-measured-width": undefined })), 1);
});

test("an end of scrolling while a report is on its way is owed, and goes with the next screen", async () => {
  const h = await harness(new Element({ "data-revision": 7 }));
  const v = scrolledView();
  h.place(v.placement);
  h.scroll(v.scroller, "moved");
  assert.equal(h.posts.length, 1);
  v.scroller.scrollTop = 1100;
  h.scroll(v.scroller, "rest");
  assert.equal(h.posts.length, 1, "nothing more until the next screen puts the trigger back");
  v.scroller.attributes["data-effect"] = "...";
  h.scroll(v.scroller, "moved");
  assert.equal(h.posts.length, 2);
  assert.equal(h.posts[1].body.top, "4.56.0");
  v.scroller.attributes["data-effect"] = "...";
  h.scroll(v.scroller, "moved");
  assert.equal(h.posts.length, 2);
});

test("only a placement moves the view: a screen that moves what is drawn leaves it where the browser has it", async () => {
  const h = await harness(new Element({ "data-revision": 7 }));
  const v = scrolledView({}, { "data-target": "4.1.0", "data-offset": "0" });
  h.place(v.placement);
  h.scroll(v.scroller, "moved");
  assert.equal(h.posts[0].body.top, "4.1.0");
  // The next screen draws ten items above, which pushes the first one
  // down by 200 px; the browser's scroll anchoring is the browser's.
  for (const item of v.items) item.top += 200;
  v.scroller.scrollHeight += 200;
  v.scroller.attributes["data-effect"] = "...";
  h.scroll(v.scroller, "moved");
  assert.equal(v.scroller.scrollTop, 0);
  // Scrolled to the top of a deeper view after reporting, the same.
  const deep = scrolledView();
  h.place(deep.placement);
  h.scroll(deep.scroller, "moved");
  deep.scroller.scrollTop = 0;
  for (const item of deep.items) item.top += 200;
  deep.scroller.scrollHeight += 200;
  deep.scroller.attributes["data-effect"] = "...";
  h.scroll(deep.scroller, "moved");
  assert.equal(deep.scroller.scrollTop, 0);
});

test("a new placement marker is applied before anything is reported", async () => {
  const h = await harness(new Element({ "data-revision": 7 }));
  const v = scrolledView();
  h.place(v.placement);
  h.scroll(v.scroller, "moved");
  assert.equal(h.posts.length, 1);
  // The next screen carries placement 4: its marker's data-init has not run yet.
  v.placement.attributes["data-placement"] = 4;
  v.scroller.attributes["data-effect"] = "...";
  h.scroll(v.scroller, "rest");
  assert.equal(h.posts.length, 1);
  h.place(v.placement);
  h.scroll(v.scroller, "moved");
  assert.equal(h.posts.length, 2);
  assert.equal(h.posts[1].body.placement, 4);
});

test("a spacer in view reports, unless a report is on its way, and is not owed", async () => {
  const h = await harness(new Element({ "data-revision": 7 }));
  const v = spacedView();
  h.place(v.placement);
  // 600 px drawn above and 1,200 below: within the band.
  v.scroller.scrollTop = 1600;
  h.scroll(v.scroller, "moved");
  v.scroller.attributes["data-effect"] = "...";
  assert.equal(h.posts.length, 1);
  // Enough is drawn beyond the view, but a spacer came into view.
  h.scroll(v.below, "spacer");
  assert.equal(h.posts.length, 2, "the action finds its scroller from the spacer");
  assert.equal(h.posts[1].body.spacer, null, "the top edge is on an item");
  h.scroll(v.below, "spacer");
  assert.equal(h.posts.length, 2, "one report at a time");
  v.scroller.attributes["data-effect"] = "...";
  h.scroll(v.scroller, "moved");
  assert.equal(h.posts.length, 2, "the spacer is observed again by the next screen, not owed");
});

test("a report from a spacer names the drawn item next to it and how far the top edge is from it", async () => {
  const h = await harness(new Element({ "data-revision": 7 }));
  const v = spacedView();
  h.place(v.placement);
  assert.equal(v.scroller.scrollTop, 1000);
  h.scroll(v.scroller, "moved");
  // 400 px up into the spacer above: nothing drawn is in view.
  v.scroller.scrollTop = 600;
  v.scroller.attributes["data-effect"] = "...";
  h.scroll(v.scroller, "rest");
  assert.deepEqual(h.posts[1].body, {
    version: 1, tab: "tab-1", type: "scroll", sequence: 2, revision: 7, view: 12, node: 4, placement: 3,
    top: "4.51.0", offset: -400, lastVisible: null, spacer: "above", spacerDistance: 400,
    before: 0, after: 99, drawnHeight: 2000, above: 0, below: 2200, width: 300, height: 200,
  });
  // 300 px down into the spacer below.
  v.scroller.scrollTop = 3300;
  v.scroller.attributes["data-effect"] = "...";
  h.scroll(v.scroller, "rest");
  assert.deepEqual(h.posts[2].body, {
    version: 1, tab: "tab-1", type: "scroll", sequence: 3, revision: 7, view: 12, node: 4, placement: 3,
    top: "4.150.0", offset: 320, lastVisible: null, spacer: "below", spacerDistance: 300,
    before: 99, after: 0, drawnHeight: 2000, above: 2300, below: 0, width: 300, height: 200,
  });
});

test("after a report from a spacer, the page reports what the next screen drew there", async () => {
  const h = await harness(new Element({ "data-revision": 7 }));
  const v = spacedView();
  h.place(v.placement);
  h.scroll(v.scroller, "moved");
  // 300 px down into the spacer below: nothing drawn is in view.
  v.scroller.scrollTop = 3300;
  v.scroller.attributes["data-effect"] = "...";
  h.scroll(v.scroller, "rest");
  assert.equal(h.posts[1].body.spacer, "below");
  // The answer draws the items the server counted there, from 2,400 px:
  // the view, where the browser left it, shows item 96 at its top, with
  // 900 px drawn above it and 900 below, within the band. The page does
  // not move it, and reports it.
  for (const item of v.scroller.querySelectorAll("[data-item]")) item.top += 1400;
  v.above.height = 2400;
  v.below.top = 4400;
  v.below.height = 600;
  v.scroller.attributes["data-effect"] = "...";
  h.scroll(v.scroller, "moved");
  assert.equal(v.scroller.scrollTop, 3300);
  assert.equal(h.posts.length, 3);
  assert.equal(h.posts[2].body.spacer, null);
  assert.equal(h.posts[2].body.top, "4.96.0");
  assert.equal(h.posts[2].body.offset, 0);
  // Measured, it owes nothing more.
  v.scroller.attributes["data-effect"] = "...";
  h.scroll(v.scroller, "moved");
  assert.equal(h.posts.length, 3);
});

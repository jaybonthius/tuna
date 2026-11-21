// Sizes, styles, edits, folds and narrowing, in each browser the machine
// can run.
import fs from "fs";
import path from "path";
import { launch, start, stop, state, settle, repl, sleep, fitRows, focusView, Results, browsers } from "./common.mjs";

const bin = process.argv[2];
const results = new Results("views-edits-browser");
const near = (a, b, d) => Math.abs(a - b) <= d;

async function opened(t, name, width, height = 800, mobile = false) {
  const b = await launch(name, { width, height, mobile });
  await b.page.goto(t.tuna.url);
  await b.page.waitForSelector(".layout-view.selected .view[data-placement]");
  return b;
}

async function show(t, page, form) {
  const before = await page.evaluate(() => window.__view()?.dataset.showing);
  await repl(t.tuna, form);
  await page.waitForFunction((b) => window.__view()?.dataset.showing !== b, before);
  await settle(page);
}

const top = async (page) => {
  const s = await state(page);
  return s.first.line + (s.first.offset < -0.5 ? 1 : 0);
};

const offsetOf = (page, id) => page.evaluate((id) => {
  const v = window.__view();
  const e = document.getElementById(id);
  return e ? window.tunaViews.box(e).top - (v.getBoundingClientRect().top + v.clientTop) : null;
}, id);

async function scrollTo(page, y) {
  await page.evaluate((y) => { window.__view().scrollTop = y; }, y);
  await settle(page);
}

async function placeTop(t, page, line) {
  await repl(t.tuna, `(views:scroll-to! (sv) (max 1 (line-start ${line})) (views:align top))`);
  await settle(page);
}

// Scrolls through some screens and back, so the table holds more than the
// run drawn now.
async function measureAround(page) {
  await focusView(page);
  for (let i = 0; i < 4; i++) { await page.mouse.wheel(0, 600); await settle(page, 250); }
  for (let i = 0; i < 4; i++) { await page.mouse.wheel(0, -600); await settle(page, 250); }
}

// The slots the table has measured, and those the drawn run spans: a
// table forgotten and measured afresh holds no more than the run's.
const measuredAndDrawn = (page) => page.evaluate(() => {
  const v = window.__view();
  const items = window.tunaViews.viewItems(v);
  const slot = (i) => Number(i.dataset.slot);
  const first = items.length ? slot(items[0]) : 0;
  const last = items.length ? slot(items[items.length - 1]) : 0;
  const atStart = v.hasAttribute("data-run-at-start") ? first : 0;
  const atEnd = v.hasAttribute("data-run-at-end") ? Number(v.dataset.slots) - 1 - last : 0;
  return { measured: window.tunaViews.measured(Number(v.dataset.view)), drawn: last - first + 1 + atStart + atEnd };
});

// Each forget makes the view's table anew.
const tableMark = (page) => page.evaluate(() => {
  const t = window.tunaViews.table(Number(window.__view().dataset.view));
  t.mark = t.mark ?? Math.random();
  return t.mark;
});

const fractionAtTop = (page) => page.evaluate(() => {
  const s = window.__state();
  const e = document.getElementById(s.first.id);
  return { id: s.first.id, fraction: -s.first.offset / window.tunaViews.box(e).height };
});

async function desktop(t, name, width, mobile) {
  const height = mobile ? 760 : 800;
  const { browser, page } = await opened(t, name, width, height, mobile);
  const tag = (id) => `${id} ${name} ${width}`;
  const check = (id, ok, note) => results.check(tag(id), ok, note);
  const chromium = name === "chromium";
  try {
    // A new width forgets the table; the top item keeps its fraction.
    // Point stays out of view, so the view never follows it.
    await show(t, page, "(begin (show-chat! 200) (hand-moves-point! #f))");
    await scrollTo(page, 3000);
    await measureAround(page);
    await page.evaluate(() => { window.__view().scrollTop += 37; });
    await settle(page);
    let before = await fractionAtTop(page);
    let m0 = await measuredAndDrawn(page);
    let mark = await tableMark(page);
    await page.setViewportSize({ width: width - 200, height });
    await settle(page, 600);
    let after = await page.evaluate((id) => {
      const v = window.__view();
      const e = document.getElementById(id);
      const b = window.tunaViews.box(e);
      return { fraction: ((v.getBoundingClientRect().top + v.clientTop) - b.top) / b.height };
    }, before.id);
    let m1 = await measuredAndDrawn(page);
    check("a new width forgets the table", m0.measured > m0.drawn && (await tableMark(page)) !== mark && near(after.fraction, before.fraction, 0.05),
      `fraction ${before.fraction.toFixed(3)} -> ${after.fraction.toFixed(3)}, measured ${m0.measured} -> ${m1.measured} of ${m1.drawn} drawn`);
    await page.setViewportSize({ width, height });
    await settle(page, 600);

    if (chromium) {
      // Switching wrapping forgets the table; the top item's top goes
      // to the top.
      await measureAround(page);
      m0 = await measuredAndDrawn(page);
      before = await fractionAtTop(page);
      mark = await tableMark(page);
      await repl(t.tuna, "(wrap! #f)");
      await settle(page, 600);
      const off = await offsetOf(page, before.id);
      m1 = await measuredAndDrawn(page);
      check("switching wrapping forgets the table", (await tableMark(page)) !== mark && off !== null && near(off, 0, 0.5), `top item at ${off}, measured ${m0.measured} -> ${m1.measured}`);
      await repl(t.tuna, "(wrap! #t)");
      await settle(page, 600);

      // A stylesheet that loads forgets the table; the top item keeps
      // its fraction.
      await measureAround(page);
      await page.evaluate(() => { window.__view().scrollTop += 29; });
      await settle(page);
      before = await fractionAtTop(page);
      m0 = await measuredAndDrawn(page);
      mark = await tableMark(page);
      fs.writeFileSync(path.join(t.home, ".config/tuna/spacious.css"), ".view { line-height: 2; }");
      await repl(t.tuna, `(begin (table-set! web:stylesheets 'spacious "spacious.css") #t)`);
      await page.waitForFunction(() => [...document.querySelectorAll("link[rel=stylesheet]")].some((l) => l.href.includes("spacious") && l.sheet));
      await settle(page, 800);
      after = await page.evaluate((id) => {
        const v = window.__view();
        const b = window.tunaViews.box(document.getElementById(id));
        return { fraction: ((v.getBoundingClientRect().top + v.clientTop) - b.top) / b.height };
      }, before.id);
      m1 = await measuredAndDrawn(page);
      check("a stylesheet that loads forgets the table", (await tableMark(page)) !== mark && near(after.fraction, before.fraction, 0.05),
        `fraction ${before.fraction.toFixed(3)} -> ${after.fraction.toFixed(3)}, measured ${m0.measured} -> ${m1.measured}`);
      await repl(t.tuna, "(begin (table-remove! web:stylesheets 'spacious) #t)");
      await settle(page, 800);

      // A screen whose changes start at another version than the
      // table's forgets it; nothing in view moves.
      await show(t, page, "(show-lines! 10000)");
      await scrollTo(page, 24 * 3000);
      await measureAround(page);
      before = await page.evaluate(() => window.__state().first);
      mark = await tableMark(page);
      await page.evaluate(() => { window.tunaViews.table(Number(window.__view().dataset.view)).version = -7; });
      await repl(t.tuna, "(begin (buffers:insert! (views:buffer (sv)) (- (document:length (buffers:document (views:buffer (sv)))) 1) \"more\\n\") #t)");
      await settle(page);
      const offVersion = await offsetOf(page, before.id);
      m1 = await measuredAndDrawn(page);
      check("a screen from another version forgets the table", (await tableMark(page)) !== mark && offVersion !== null && near(offVersion, before.offset, 0.5), `top item ${before.offset} -> ${offVersion}, measured ${m1.measured} of ${m1.drawn}`);
    }

    // Text typed in the line at the top that wraps it onto another
    // row keeps the line's top; text below moves down a row.
    await show(t, page, "(show-lines! 200)");
    await placeTop(t, page, 50);
    await repl(t.tuna, "(views:set-point! (sv) (+ (line-start 50) 8))");
    await settle(page);
    const lineId = (await state(page)).first.id;
    const nextId = await page.evaluate((id) => document.getElementById(id).nextElementSibling.id, lineId);
    const [a0, n0] = [await offsetOf(page, lineId), await offsetOf(page, nextId)];
    const lh = (await state(page)).lineHeight;
    await repl(t.tuna, `(begin (buffers:insert! (views:buffer (sv)) (+ (line-start 50) 8) (make-string 200 #\\x)) #t)`);
    await settle(page);
    const [a1, n1] = [await offsetOf(page, lineId), await offsetOf(page, nextId)];
    check("typing that wraps the top line keeps its top", near(a1, a0, 0.5) && n1 - n0 >= lh - 0.5, `line ${a0} -> ${a1}, below moved ${n1 - n0}`);

    // Output appended at the end, with and without tail.
    for (const tail of [true, false]) {
      await show(t, page, "(show-lines! 300)");
      await repl(t.tuna, `(tail! ${tail ? "#t" : "#f"})`);
      await page.keyboard.press("Alt+Shift+Period");
      await settle(page);
      const s0 = await state(page);
      await repl(t.tuna, "(append-lines! 5)");
      await settle(page);
      const s1 = await state(page);
      const atEnd = await page.evaluate(() => { const v = window.__view(); return v.scrollTop + v.clientHeight >= v.scrollHeight - 1; });
      if (tail) check("output appended with tail follows the end", atEnd && s1.scrollHeight > s0.scrollHeight, `at the end ${atEnd}`);
      else check("output appended without tail moves nothing in view", s1.first.id === s0.first.id && near(s1.first.offset, s0.first.offset, 0.5) && s1.size < s0.size,
        `top ${s0.first.text} -> ${s1.first.text}, thumb ${s0.size.toFixed(4)} -> ${s1.size.toFixed(4)}`);
    }

    // Edits far above the view leave what is in view still.
    await show(t, page, "(show-lines! 10000)");
    await scrollTo(page, 24 * 5000);
    before = (await state(page)).first;
    await repl(t.tuna, "(insert-lines-at! 2 50)");
    await settle(page);
    const offFar = await offsetOf(page, before.id);
    check("edits far above move nothing in view", offFar !== null && near(offFar, before.offset, 0.5), `top item ${before.offset} -> ${offFar}`);

    // Away and back, the view is at its place and its table starts
    // empty.
    await measureAround(page);
    const topAway = await top(page);
    await repl(t.tuna, "(layout:switch-to-buffer (or (buffers:find \"*other*\") (buffers:make \"*other*\" \"other\\n\")))");
    await page.waitForFunction(() => window.__state()?.slots === 2);
    await repl(t.tuna, "(layout:switch-to-buffer (buffers:find \"*lines*\"))");
    await page.waitForFunction(() => window.__state()?.slots > 1000);
    m1 = await measuredAndDrawn(page);
    await settle(page);
    check("away and back keeps the place", (await top(page)) === topAway && m1.measured <= m1.drawn, `top ${topAway} -> ${await top(page)}, measured ${m1.measured} of ${m1.drawn}`);

    // A reload places the first screen before paint; its table
    // starts empty.
    const topReload = await top(page);
    await page.reload();
    await page.waitForSelector(".layout-view.selected .view[data-placement]");
    const first = await page.evaluate(() => ({ s: window.__state(), m: window.tunaViews.measured(Number(window.__view().dataset.view)) }));
    await settle(page);
    check("a reload places the first screen", first.s.first.line === topReload && first.m <= first.s.drawn, `top ${topReload} -> ${first.s.first.line}, measured ${first.m} of ${first.s.drawn}`);

    // A fold closed and opened above the view moves nothing in view;
    // the slots splice and the table is kept.
    await show(t, page, "(show-lines! 200)");
    if (!mobile) await fitRows(page, width, 21);
    await scrollTo(page, 24 * 40);
    await placeTop(t, page, 60);
    await measureAround(page);
    await placeTop(t, page, 60);
    before = (await state(page)).first;
    m0 = await measuredAndDrawn(page);
    const slots0 = (await state(page)).slots;
    await repl(t.tuna, "(fold-lines! 10 30)");
    await settle(page);
    const slots1 = (await state(page)).slots;
    const offFolded = await offsetOf(page, before.id);
    m1 = await measuredAndDrawn(page);
    await repl(t.tuna, "(unfold-lines! 10)");
    await settle(page);
    const offOpened = await offsetOf(page, before.id);
    const m2 = await measuredAndDrawn(page);
    check("a fold above moves nothing in view", slots1 === slots0 - 20 && near(offFolded, before.offset, 0.5) && near(offOpened, before.offset, 0.5) && m1.measured > m1.drawn && m2.measured > m2.drawn,
      `slots ${slots0} -> ${slots1}, top ${before.offset} -> ${offFolded} -> ${offOpened}, measured ${m0.measured} -> ${m1.measured} -> ${m2.measured}`);

    // A cursor that ends a batch inside a fold in view opens it; the
    // top stays and what lies below moves down.
    await placeTop(t, page, 60);
    await repl(t.tuna, "(fold-lines! 62 70)");
    await settle(page);
    const topId = (await state(page)).first.id;
    const below = await page.evaluate(() => [...document.querySelectorAll(".line")].find((l) => l.textContent === "line 071").id);
    const [t0, b0] = [await offsetOf(page, topId), await offsetOf(page, below)];
    await repl(t.tuna, "(views:set-point! (sv) (line-start 65))");
    await settle(page);
    const [t1, b1] = [await offsetOf(page, topId), await offsetOf(page, below)];
    check("a cursor in a fold opens it", near(t1, t0, 0.5) && near(b1 - b0, 8 * lh, 1), `top ${t0} -> ${t1}, line 71 moved ${b1 - b0}`);

    // Narrowing keeps a place inside it, else goes to its
    // start; widening keeps the place; each forgets the table.
    await placeTop(t, page, 60);
    await measureAround(page);
    await placeTop(t, page, 60);
    let markNarrowed = await tableMark(page);
    await repl(t.tuna, "(narrow-lines! 40 120)");
    await settle(page);
    m1 = await measuredAndDrawn(page);
    check("narrowing keeps a place inside it", (await top(page)) === 60 && (await tableMark(page)) !== markNarrowed, `top ${await top(page)}, measured ${m1.measured} of ${m1.drawn}`);
    await repl(t.tuna, "(widen!)");
    await settle(page);
    await placeTop(t, page, 60);
    await repl(t.tuna, "(narrow-lines! 100 150)");
    await settle(page);
    check("narrowing away from the place goes to its start", (await top(page)) === 100, `top ${await top(page)}`);
    await measureAround(page);
    await placeTop(t, page, 100);
    markNarrowed = await tableMark(page);
    await repl(t.tuna, "(widen!)");
    await settle(page);
    m1 = await measuredAndDrawn(page);
    check("widening keeps the place", (await top(page)) === 100 && (await tableMark(page)) !== markNarrowed, `top ${await top(page)}, measured ${m1.measured} of ${m1.drawn}`);

    if (chromium) {
      // A character typed right after the second of three rows
      // standing alone puts them in one line, and deleting it splits
      // them again; nothing in view above them moves, the table keeps its
      // heights outside the change, and its count of slots agrees.
      await show(t, page, "(show-cells!)");
      await placeTop(t, page, 20);
      await measureAround(page);
      await placeTop(t, page, 20);
      const firstCell = await page.evaluate(() => {
        const v = window.__view();
        const top = v.getBoundingClientRect().top + v.clientTop;
        const cell = [...v.querySelectorAll(".cell")].find((c) => c.getBoundingClientRect().bottom > top + 0.5);
        return { at: cell.closest("[data-at]").dataset.at, top: cell.getBoundingClientRect().top - top };
      });
      mark = await tableMark(page);
      const typed = [];
      for (const form of ["(buffers:insert! (views:buffer (sv)) (+ (group-start 30) 3) \"x\")",
                          "(buffers:replace! (views:buffer (sv)) (+ (group-start 30) 3) (+ (group-start 30) 4) \"\")"]) {
        await repl(t.tuna, `(begin ${form} #t)`);
        await settle(page);
        typed.push(await page.evaluate((at) => {
          const v = window.__view();
          const table = window.tunaViews.table(Number(v.dataset.view));
          const cell = v.querySelector(`[data-at="${at}"] .cell`);
          return { top: cell ? cell.getBoundingClientRect().top - (v.getBoundingClientRect().top + v.clientTop) : null,
                   count: table.heights.count, slots: Number(v.dataset.slots), measured: table.heights.measured };
        }, firstCell.at));
      }
      const kept = (await tableMark(page)) === mark;
      check("rows standing alone joined and split", kept && typed.every((x) => x.top !== null && near(x.top, firstCell.top, 0.5) && x.count === x.slots),
        `table kept ${kept}; ` + typed.map((x) => `top ${x.top}, ${x.count} of ${x.slots} slots, ${x.measured} measured`).join("; "));
    }
  } finally {
    await browser.close();
  }
}

// A split below shrinks the view, and an edit in the other view of the
// buffer moves its numbers, not its text; a hidden tab keeps its table.
async function layouts(t, name) {
  const { browser, page } = await opened(t, name, 1280);
  const tag = (id) => `${id} ${name} 1280`;
  try {
    await show(t, page, "(show-lines! 200)");
    await fitRows(page, 1280, 21);
    await repl(t.tuna, "(views:set-point! (sv) (line-start 109))");
    await settle(page);
    await placeTop(t, page, 90);
    await page.keyboard.press("Control+x");
    await page.keyboard.press("2");
    await settle(page, 600);
    let s = await state(page);
    const rows = Math.floor(s.clientHeight / s.lineHeight);
    const tp = await top(page);
    // Point lost within a view's height of the bottom edge is followed by
    // the least scroll, and from further, to the centre.
    const want = 109 - (90 + rows - 1) <= rows ? 109 - rows + 1 : 109 - Math.floor((rows - 1) / 2);
    results.check(tag("a split below shrinks the view"), tp === want, `rows ${rows}, top ${tp}, want ${want}`);

    await placeTop(t, page, 104);
    const id2 = (await state(page)).first.id;
    await repl(t.tuna, "(insert-lines-at! 2 3)");
    await settle(page);
    s = await state(page);
    const pt = (await repl(t.tuna, "(point-at)")).slice(1, -1).split(" ").map(Number);
    results.check(tag("an edit in the other view moves no text"), s.first.id === id2 && s.first.line === 107 && pt[0] === 112, `top ${s.first.text} line ${s.first.line}, point ${pt.join(":")}`);
    await page.keyboard.press("Control+x");
    await page.keyboard.press("1");
    await settle(page);

    await show(t, page, "(show-lines! 10000)");
    await scrollTo(page, 24 * 3000);
    await measureAround(page);
    const before = await state(page);
    const m0 = await page.evaluate(() => window.tunaViews.measured(Number(window.__view().dataset.view)));
    await repl(t.tuna, "(run-command layout-tabs:new-tab)");
    await settle(page, 600);
    await repl(t.tuna, "(run-command layout-tabs:next-tab)");
    await settle(page, 600);
    const after = await state(page);
    const m1 = await page.evaluate(() => window.tunaViews.measured(Number(window.__view().dataset.view)));
    results.check(tag("a hidden tab keeps its table"), after.id === before.id && after.first.text === before.first.text && after.scrollHeight === before.scrollHeight
      && near(after.scrollTop, before.scrollTop, 0.5) && m1 >= m0,
      `top ${before.first.text} -> ${after.first.text}, height ${before.scrollHeight} -> ${after.scrollHeight}, measured ${m0} -> ${m1}`);
  } finally {
    await browser.close();
  }
}

const began = Date.now();
const t = await start(bin, "edits");
try {
  for (const name of browsers()) {
    await desktop(t, name, 1280, false);
    await desktop(t, name, 390, true);
    if (name === "chromium") await layouts(t, name);
  }
} finally {
  await stop(t);
}
console.log(`took ${Math.round((Date.now() - began) / 1000)} s`);
results.end();

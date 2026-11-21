// Scrolling sideways where lines do not wrap: ten short lines, a line of
// 300 characters, ten more.
import { launch, start, stop, state, settle, repl, sleep, Results, browsers } from "./common.mjs";

const bin = process.argv[2];
const results = new Results("views-sideways-browser");
const near = (a, b, d) => Math.abs(a - b) <= d;

async function opened(t, name, width, mobile) {
  const b = await launch(name, { width, height: mobile ? 760 : 800, mobile });
  await b.page.goto(t.tuna.url);
  await b.page.waitForSelector(".layout-view.selected .view[data-placement]");
  return b;
}

// Where the view is sideways, in columns, and where point's cursor is
// against the text area's edges.
const side = (page) => page.evaluate(() => {
  const v = window.__view();
  const t = window.tunaViews;
  const cw = t.charWidth(v);
  const cursor = [...v.querySelectorAll(".cursor.primary, .cursor-on.primary")].find((c) => c.closest("[data-view]") === v);
  const b = cursor?.getBoundingClientRect();
  return { left: v.scrollLeft, column: Math.round(v.scrollLeft / cw), cw, columns: Math.floor(t.contentSize(v).width / cw),
           textLeft: t.textLeft(v), textRight: t.textRight(v), cursorLeft: b?.left, cursorRight: b?.right,
           scrollWidth: v.scrollWidth, clientWidth: v.clientWidth, bar: v.offsetHeight - v.clientHeight - 2 * v.clientTop,
           clientHeight: v.clientHeight };
});

async function suite(t, name, width, mobile) {
  const { browser, page } = await opened(t, name, width, mobile);
  const tag = (id) => `${id} ${name} ${width}`;
  const check = (id, ok, note) => results.check(tag(id), ok, note);
  const point = async () => (await repl(t.tuna, "(point-at)")).slice(1, -1).split(" ").map(Number);
  const keys = async (...ks) => {
    for (const k of ks) await page.keyboard.press(k);
    await settle(page);
  };
  const goto = async (line, column) => {
    await repl(t.tuna, `(views:set-point! (sv) (+ (max 1 (line-start ${line})) ${column}))`);
    await settle(page);
  };
  // A cursor is a bar of no width in the line, drawn just after its
  // place.
  const shown = (s) => s.cursorLeft >= s.textLeft - 0.5 && s.cursorLeft <= s.textRight + 0.5;
  try {
    await repl(t.tuna, "(show-long-line!)");
    await page.waitForFunction(() => window.__state()?.slots === 22);
    await settle(page);
    await page.mouse.click(10, 10);
    let s = await side(page);
    check("a long line scrolls sideways", s.scrollWidth >= 300 * s.cw && (mobile || s.bar > 0), `scroll width ${s.scrollWidth}, bar ${s.bar} px`);

    await goto(11, 0);
    await keys("Control+e");
    let p = await point();
    s = await side(page);
    const fits = 300 <= s.columns;
    check("C-e on the long line shows point", p[0] === 11 && p[1] === 300 && shown(s) && (fits ? s.left === 0 : near(s.cursorLeft, s.textRight, s.cw)),
      `point ${p.join(":")}, cursor ${s.cursorLeft?.toFixed(1)}-${s.cursorRight?.toFixed(1)} in ${s.textLeft}-${s.textRight}`);
    await keys("Control+a");
    s = await side(page);
    p = await point();
    check("C-a goes back to column 0", p[1] === 0 && s.left === 0, `point ${p.join(":")}, column ${s.column}`);

    const step = s.columns - 2;
    await keys("Control+x", "Shift+Comma");
    s = await side(page);
    p = await point();
    check("C-x < scrolls by a view less two columns", near(s.column, step, 1) && p[0] === 11 && p[1] === 0, `column ${s.column}, want ${step}, point ${p.join(":")}`);
    await keys("Control+x", "Shift+Comma");
    s = await side(page);
    const most = Math.round((s.scrollWidth - s.clientWidth) / s.cw);
    check("C-x < again", near(s.column, Math.min(2 * step, most), 1), `column ${s.column}, want ${Math.min(2 * step, most)}`);
    const scrolledTwice = s.column;
    await keys("Control+x", "Shift+Period");
    s = await side(page);
    check("C-x >", near(s.column, Math.max(0, scrolledTwice - step), 1), `column ${s.column}, want ${Math.max(0, scrolledTwice - step)}`);
    const scrolledBack = s.column;
    await keys("Control+u", "5", "Control+x", "Shift+Comma");
    s = await side(page);
    check("C-u 5 C-x <", near(s.column, Math.min(scrolledBack + 5, most), 1), `column ${s.column}, want ${Math.min(scrolledBack + 5, most)}`);
    await keys("Control+x", "Shift+Period", "Control+x", "Shift+Period", "Control+x", "Shift+Period");
    s = await side(page);
    check("C-x > back to column 0", s.left === 0, `column ${s.column}`);

    // From column 100 of the long line, scrolled so it shows, C-n
    // goes to the end of a short line, and the view to column 0.
    await page.evaluate((x) => { window.__view().scrollLeft = x; }, 60 * s.cw);
    await settle(page);
    await goto(11, 100);
    s = await side(page);
    const before = s.left;
    await keys("Control+n");
    s = await side(page);
    p = await point();
    check("C-n onto a short line goes to column 0", before > 0 && p[0] === 12 && p[1] === 8 && s.left === 0, `point ${p.join(":")}, column ${s.column} from ${Math.round(before / s.cw)}`);

    // C-u 100 C-f on the long line scrolls by the least that shows
    // point.
    await goto(11, 0);
    await keys("Control+u", "1", "0", "0", "Control+f");
    s = await side(page);
    p = await point();
    const visibleAt0 = 100 < s.columns;
    check("C-u 100 C-f scrolls by the least", p[1] === 100 && shown(s) && (visibleAt0 ? s.left === 0 : near(s.cursorLeft, s.textRight, s.cw)),
      `point ${p.join(":")}, column ${s.column}, cursor ${s.cursorLeft?.toFixed(1)}-${s.cursorRight?.toFixed(1)} in ${s.textLeft}-${s.textRight}`);

    // C-b at the leftmost column shown, past column 0, scrolls left
    // by the least that shows point.
    await page.evaluate((x) => { window.__view().scrollLeft = x; }, 60 * s.cw);
    await settle(page);
    await goto(11, 61);
    s = await side(page);
    const left0 = s.column;
    await keys("Control+b");
    await keys("Control+b");
    s = await side(page);
    p = await point();
    check("C-b past the left edge scrolls by the least", p[1] === 59 && shown(s) && near(s.cursorLeft, s.textLeft, s.cw) && s.column < left0 && s.column > 0,
      `point ${p.join(":")}, column ${left0} -> ${s.column}`);

    // A long line entering the drawn run brings the horizontal bar,
    // which takes height; point on the bottom row stays in view.
    if (!mobile) {
      await repl(t.tuna, "(begin (show-lines! 200) (wrap! #f))");
      await page.waitForFunction(() => window.__state()?.slots === 201);
      await settle(page);
      await page.mouse.click(10, 10);
      const s0 = await state(page);
      const rows = Math.floor(s0.clientHeight / s0.lineHeight);
      await goto(rows, 0);
      const top0 = (await state(page)).first.line;
      const h0 = (await side(page)).clientHeight;
      await repl(t.tuna, `(begin (buffers:insert! (views:buffer (sv)) (line-start ${rows + 3}) (string-append (make-string 400 #\\y) "\\n")) #t)`);
      await settle(page);
      const s1 = await side(page);
      const top1 = (await state(page)).first;
      const shownRow = await page.evaluate(() => {
        const v = window.__view();
        const b = window.tunaViews.pointExtent(v);
        return b !== null && b.top >= v.scrollTop - 0.5 && b.top + b.height <= v.scrollTop + v.clientHeight + 0.5;
      });
      await repl(t.tuna, `(begin (buffers:replace! (views:buffer (sv)) (line-start ${rows + 3}) (line-start ${rows + 4}) "") #t)`);
      await settle(page);
      const s2 = await side(page);
      check("the horizontal bar keeps point in view", s1.clientHeight < h0 && shownRow && top1.line >= top0 && s2.clientHeight === h0,
        `height ${h0} -> ${s1.clientHeight} -> ${s2.clientHeight}, top ${top0} -> ${top1.line}, point shown ${shownRow}`);
    }
  } finally {
    await browser.close();
  }
}

const began = Date.now();
const t = await start(bin, "sideways");
try {
  for (const name of browsers()) {
    await suite(t, name, 1280, false);
    if (name === "chromium") await suite(t, name, 390, true);
  }
} finally {
  await stop(t);
}
console.log(`took ${Math.round((Date.now() - began) / 1000)} s`);
results.end();

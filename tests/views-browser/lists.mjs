// Lists: rows standing alone, one slot each, a completion list's margin
// and selection, and group headings.
import { launch, start, stop, state, settle, repl, sleep, focusView, Results, browsers } from "./common.mjs";

const bin = process.argv[2];
const results = new Results("views-lists-browser");

async function opened(t, name, width, mobile) {
  const b = await launch(name, { width, height: mobile ? 760 : 800, mobile });
  await b.page.goto(t.tuna.url);
  await b.page.waitForSelector(".layout-view.selected .view[data-placement]");
  return b;
}

// The completion list's own view, inside the minibuffer's.
const listState = (page) => page.evaluate(() => {
  const list = document.querySelector(".view:has(> .view-lines > .minibuffer-prompts) .view[data-placement]");
  if (!list) return null;
  const top = list.getBoundingClientRect().top + list.clientTop;
  const rows = [...list.querySelectorAll(".ui-list-row")];
  const sel = rows.find((r) => r.getAttribute("aria-current") === "true");
  const lh = rows[0]?.getBoundingClientRect().height ?? 1;
  return { scrollTop: list.scrollTop, height: list.clientHeight, lh, selected: sel?.textContent ?? null,
           selTop: sel ? sel.getBoundingClientRect().top - top : null };
});

async function suite(t, name, width, mobile) {
  const { browser, page } = await opened(t, name, width, mobile);
  const tag = (id) => `${id} ${name} ${width}`;
  const check = (id, ok, note) => results.check(tag(id), ok, note);
  try {
    // A list of a million equal rows keeps its thumb's size once a
    // row is measured, and its table holds only the rows drawn.
    await repl(t.tuna, "(rows-buffer! 1000000)");
    await page.waitForFunction(() => window.__state()?.slots > 1000000);
    await settle(page);
    await focusView(page);
    const heights = new Set();
    let drawnMost = 0;
    for (let i = 0; i < 6; i++) {
      await page.mouse.wheel(0, 900);
      await settle(page, 300);
      const s = await state(page);
      heights.add(s.scrollHeight);
      drawnMost += s.drawn;
    }
    const s = await state(page);
    check("a million rows keep the thumb's size", heights.size === 1 && s.measured <= drawnMost + 10, `heights ${[...heights].join(" ")}, measured ${s.measured} of ${drawnMost} drawn`);

    // The heading of the first row in view sticks to the top, and a
    // run's first heading counts in no row's height.
    await repl(t.tuna, "(grouped-rows! 5000)");
    await page.waitForFunction(() => window.__state()?.slots > 5000);
    await page.evaluate(() => { window.__view().scrollTop = 40000; });
    await settle(page, 600);
    const groups = await page.evaluate(() => {
      const v = window.__view();
      const top = v.getBoundingClientRect().top + v.clientTop;
      // Stuck headings pile up at the top, the last drawn over the rest.
      const heading = [...v.querySelectorAll(".ui-list-heading")].filter((h) => Math.abs(h.getBoundingClientRect().top - top) < 1).at(-1);
      const items = window.tunaViews.viewItems(v);
      const first = items.find((i) => window.tunaViews.box(i).bottom > top + 1);
      const table = window.tunaViews.table(Number(v.dataset.view));
      const firstSlot = Number(items[0].dataset.slot);
      const rowH = window.tunaViews.box(items[5]).height;
      return { heading: heading?.textContent ?? null, first: first?.textContent, group: Math.floor(Number(first?.textContent.slice(4)) / 10),
               firstHeight: table.heights.get(firstSlot), rowH };
    });
    check("group headings", groups.heading === `group ${groups.group}` && Math.abs(groups.firstHeight - groups.rowH) < 0.5,
      `heading ${groups.heading} over ${groups.first}, the run's first row ${groups.firstHeight} px, a row ${groups.rowH} px`);

    // C-n on the last row in view scrolls the list by one row,
    // keeping two rows of margin.
    await page.keyboard.press("Alt+x");
    await page.waitForFunction(() => document.querySelectorAll(".ui-list-row").length > 20);
    await settle(page);
    let l = await listState(page);
    const rows = Math.floor(l.height / l.lh);
    for (let i = 0; i < rows - 3; i++) await page.keyboard.press("Control+n");
    await settle(page);
    const before = await listState(page);
    await page.keyboard.press("Control+n");
    await settle(page);
    const after = await listState(page);
    const margin = (x) => x.height - (x.selTop + x.lh);
    check("C-n keeps a margin below the selection", after.selected !== before.selected && Math.abs(after.scrollTop - before.scrollTop - after.lh) < 1.5 && margin(after) >= 2 * after.lh - 1,
      `scrolled ${after.scrollTop - before.scrollTop} px, rows below the selection ${(margin(after) / after.lh).toFixed(2)}`);

    // A hand scroll leaves the selected row selected.
    const chosen = after.selected;
    const box = await page.evaluate(() => {
      const list = document.querySelector(".view:has(> .view-lines > .minibuffer-prompts) .view[data-placement]");
      const b = list.getBoundingClientRect();
      return { x: b.left + b.width / 2, y: b.top + b.height / 2 };
    });
    await page.mouse.move(box.x, box.y);
    await page.mouse.wheel(0, 600);
    await settle(page, 600);
    l = await listState(page);
    check("a hand scroll keeps the selection", l.selected === chosen && l.scrollTop > after.scrollTop, `selected ${l.selected}, scrolled to ${l.scrollTop}`);
    await page.keyboard.press("Control+g");
    await settle(page);
  } finally {
    await browser.close();
  }
}

const began = Date.now();
const t = await start(bin, "lists");
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

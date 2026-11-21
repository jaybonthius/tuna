// The scroll bars and the hand, in each browser the machine can run, at
// a desktop's size with classic scroll bars and at a phone's with touch.
import { launch, start, stop, state, settle, focusView, repl, sleep, thumbOf, Results, browsers } from "./common.mjs";

const bin = process.argv[2];
const results = new Results("views-bars-browser");
const check = (id, ok, note) => results.check(id, ok, note);
const near = (a, b, d) => Math.abs(a - b) <= d;

async function opened(t, name, size) {
  const b = await launch(name, size);
  await b.page.goto(t.tuna.url);
  await b.page.waitForSelector(".layout-view.selected .view[data-placement]");
  return b;
}

async function show(t, page, form, slots) {
  await repl(t.tuna, form);
  await page.waitForFunction((n) => window.__state()?.slots === n, slots);
  await settle(page);
}

// The item at the top, by id, and where it is in the view's scrolling.
function topItem(page) {
  return page.evaluate(() => {
    const s = window.__state();
    return { id: s.first.id, at: s.first.offset + s.scrollTop, offset: s.first.offset, text: s.first.text, scrollTop: s.scrollTop };
  });
}

function offsetOf(page, id) {
  return page.evaluate((id) => {
    const v = window.__view();
    const e = document.getElementById(id);
    return e ? window.tunaViews.box(e).top - (v.getBoundingClientRect().top + v.clientTop) : null;
  }, id);
}

function counts(page) {
  return page.evaluate(() => ({ screens: window.__screens, writes: window.tunaViews.writes() }));
}

// Reports the page sent, read from its fetches to Tuna.
function watchReports(page) {
  const sent = [];
  page.on("request", (r) => {
    const body = r.postData() ?? "";
    if (r.method() === "POST" && body.includes('"type":"scroll"')) {
      try { sent.push(JSON.parse(JSON.parse(body).item ?? body)); } catch { sent.push({ raw: body }); }
    }
  });
  return sent;
}

// The first pass only measures the text.
async function secondPassHeights(page, selector, steps, step) {
  const c = await page.evaluate((s) => {
    const b = document.querySelector(s).getBoundingClientRect();
    return { x: b.left + b.width / 2, y: b.top + b.height / 2 };
  }, selector);
  await page.mouse.move(c.x, c.y);
  const seen = new Set();
  for (let pass = 0; pass < 2; pass++) {
    for (const dy of [step, -step]) {
      for (let i = 0; i < steps; i++) {
        await page.mouse.wheel(0, dy);
        await settle(page, 250);
        if (pass === 1) seen.add(await page.evaluate((s) => document.querySelector(s).scrollHeight, selector));
      }
    }
  }
  return seen;
}

async function scrollTo(page, top) {
  await page.evaluate((top) => { window.__view().scrollTop = top; }, top);
  await settle(page);
}

async function desktop(t, name) {
  const { browser, page } = await opened(t, name, { width: 1280, height: 800 });
  const sent = watchReports(page);
  const tag = (id) => `${id} ${name} 1280`;
  try {
    // The browser's own bar, room kept for it where the text fits.
    await show(t, page, "(show-lines! 10000)", 10001);
    let s = await page.evaluate(() => {
      const v = window.__view();
      return { bar: v.offsetWidth - v.clientWidth - 2 * v.clientLeft, tall: v.scrollHeight > v.clientHeight,
               drawn: document.querySelectorAll(".view-scroll-bar, .view-thumb").length };
    });
    check(tag("the browser's own bar"), s.bar > 0 && s.tall && s.drawn === 0, `bar ${s.bar} px, drawn bars ${s.drawn}`);
    const wide = s.bar;
    await show(t, page, "(show-lines! 3)", 4);
    s = await page.evaluate(() => {
      const v = window.__view();
      return { bar: v.offsetWidth - v.clientWidth - 2 * v.clientLeft, fits: v.scrollHeight <= v.clientHeight };
    });
    check(tag("room kept for the bar where the text fits"), s.fits && s.bar === wide && wide > 0, `text fits, room kept ${s.bar} px`);

    // A transient menu's view is as tall as the menu and never scrolled,
    // so room for a bar would only narrow it.
    await repl(t.tuna, "(show-menu!)");
    await page.waitForSelector(".transient-menu");
    await settle(page);
    const menuBar = await page.evaluate(() => {
      const v = document.querySelector(".transient-menu").closest(".view");
      return v.offsetWidth - v.clientWidth - 2 * v.clientLeft;
    });
    check(tag("a transient menu keeps no room for a bar"), menuBar === 0, `room kept ${menuBar} px`);
    await page.keyboard.press("Control+g");
    await page.waitForSelector(".transient-menu", { state: "detached" });

    // A wheel step moves the text by the step, the top item with it.
    await show(t, page, "(show-lines! 10000)", 10001);
    await scrollTo(page, 24 * 300);
    await focusView(page);
    let before = await topItem(page);
    await page.mouse.wheel(0, 100);
    await settle(page);
    let after = await offsetOf(page, before.id);
    let st = await state(page);
    check(tag("a wheel step moves the text by the step"), near(st.scrollTop - before.scrollTop, 100, 0.5) && near(before.offset - after, 100, 0.5),
      `scrolled ${st.scrollTop - before.scrollTop}, item moved ${before.offset - after}`);

    // An item above the view grows; nothing in view moves.
    before = await topItem(page);
    const grown = await page.evaluate(() => {
      const v = window.__view();
      const top = v.getBoundingClientRect().top;
      const above = window.tunaViews.viewItems(v).filter((i) => i.getBoundingClientRect().bottom < top - 50);
      const item = above[above.length - 1];
      item.style.paddingBottom = "200px";
      return item.id;
    });
    await settle(page);
    after = await offsetOf(page, before.id);
    check(tag("an item above grows, nothing in view moves"), grown !== null && near(after, before.offset, 0.5), `top item ${before.offset} -> ${after}`);

    // The item at the top grows; its top stays, what is below moves.
    before = await topItem(page);
    const next = await page.evaluate((id) => document.getElementById(id).nextElementSibling.id, before.id);
    const nextBefore = await offsetOf(page, next);
    await page.evaluate((id) => { document.getElementById(id).style.paddingBottom = "200px"; }, before.id);
    await settle(page);
    after = await offsetOf(page, before.id);
    const nextAfter = await offsetOf(page, next);
    check(tag("the top item grows, its top stays"), near(after, before.offset, 0.5) && near(nextAfter - nextBefore, 200, 0.5),
      `top ${before.offset} -> ${after}, next moved ${nextAfter - nextBefore}`);

    // Idle is idle.
    await show(t, page, "(show-lines! 10000)", 10001);
    await scrollTo(page, 24 * 500);
    await settle(page, 800);
    let c0 = await counts(page);
    let r0 = sent.length;
    await sleep(3000);
    let c1 = await counts(page);
    check(tag("idle is idle"), c1.screens === c0.screens && c1.writes === c0.writes && sent.length === r0,
      `screens ${c1.screens - c0.screens}, writes ${c1.writes - c0.writes}, reports ${sent.length - r0}`);

    // The thumb keeps its size and place for the same text.
    await scrollTo(page, 0);
    await focusView(page);
    const down = [];
    for (let i = 0; i < 12; i++) {
      await page.mouse.wheel(0, 400);
      await settle(page, 300);
      st = await state(page);
      down.push([st.scrollTop, st.scrollHeight, st.first.text]);
    }
    const up = [];
    for (let i = down.length - 2; i >= 0; i--) {
      await page.mouse.wheel(0, -400);
      await settle(page, 300);
      st = await state(page);
      up.push([st.scrollTop, st.scrollHeight, st.first.text]);
    }
    const same = up.every((u, k) => { const d = down[down.length - 2 - k]; return near(u[0], d[0], 0.5) && u[1] === d[1] && u[2] === d[2]; });
    const sizes = new Set([...down, ...up].map((x) => x[1]));
    check(tag("same text, same thumb"), same && sizes.size === 1, `heights seen ${[...sizes].join(" ")}`);

    // At rest, point follows the hand into view, or stays.
    await scrollTo(page, 0);
    await repl(t.tuna, "(goto-line! 1)");
    await settle(page);
    await focusView(page);
    await page.mouse.wheel(0, 2400);
    await settle(page, 600);
    let first = (await state(page)).first;
    let point = JSON.parse((await repl(t.tuna, "(car (point-at))")));
    const wholly = first.offset >= -0.5 ? first.slot + 1 : first.slot + 2;
    check(tag("point follows the hand into view"), point === wholly, `point ${point}, first row wholly in view ${wholly} (top ${first.text} at ${first.offset})`);
    await scrollTo(page, 0);
    await repl(t.tuna, "(begin (hand-moves-point! #f) (goto-line! 1))");
    await settle(page);
    await page.mouse.wheel(0, 2400);
    await settle(page, 600);
    point = JSON.parse(await repl(t.tuna, "(car (point-at))"));
    check(tag("point stays where the hand may not move it"), point === 1, `point ${point}`);
    await repl(t.tuna, "(hand-moves-point! #t)");

    // No rest while a button is held in the view; one at its
    // release, also when the release came outside the window.
    await scrollTo(page, 24 * 1000);
    await focusView(page);
    const mid = await focusView(page);
    for (const outside of [false, true]) {
      await page.mouse.move(mid.x, mid.y);
      await page.mouse.down();
      const r1 = sent.length;
      await page.mouse.wheel(0, 300);
      await sleep(800);
      const held = sent.slice(r1).filter((r) => r.settled === true).length;
      if (outside) await page.evaluate(() => window.dispatchEvent(new MouseEvent("mousemove", { buttons: 0 })));
      else await page.mouse.up();
      await settle(page, 600);
      const rests = sent.slice(r1).filter((r) => r.settled === true).length;
      if (outside) await page.mouse.up();
      check(tag(`no rest while a button is held${outside ? ", released outside" : ""}`), held === 0 && rests >= 1, `rests while held ${held}, after ${rests}`);
    }

    // The classic bar's thumb and trough.
    await show(t, page, "(begin (show-lines! 10000) (wrap! #f))", 10001);
    await scrollTo(page, 0);
    const th = await thumbOf(page);
    await scrollTo(page, 0);
    const length = th.end - th.start;
    const track = th.height - 2 * th.start;
    const grab = th.top + th.start + length / 2;
    const target = th.top + th.start + (track - length) / 2 + length / 2;
    await page.mouse.move(th.x, grab);
    await page.mouse.down();
    const steps = 20;
    let under = 0;
    for (let i = 1; i <= steps; i++) {
      await page.mouse.move(th.x, grab + ((target - grab) * i) / steps);
      await sleep(40);
      st = await state(page);
      const thumbAt = th.top + th.start + st.thumb * (track - length) + length / 2;
      under = Math.max(under, Math.abs(thumbAt - (grab + ((target - grab) * i) / steps)));
    }
    await sleep(800);
    const held = await state(page);
    const heldTop = await topItem(page);
    await page.mouse.up();
    await settle(page, 600);
    const rested = await state(page);
    const restedOffset = await offsetOf(page, heldTop.id);
    const line = Number(rested.first.text.slice(5));
    check(tag("thumb dragged to the middle"), near(line, 5000, 100) && under <= 2 && Math.abs(rested.thumb - held.thumb) < 0.001
      && restedOffset !== null && near(restedOffset, heldTop.offset, 0.5),
      `line ${line}, thumb off the pointer ${under.toFixed(2)} px, moved at rest ${(100 * Math.abs(rested.thumb - held.thumb)).toFixed(4)} %`);
    await scrollTo(page, 0);
    await page.mouse.move(th.x, grab);
    await page.mouse.down();
    await page.mouse.move(th.x, th.top + th.height + 50, { steps: 10 });
    await page.mouse.up();
    await settle(page, 600);
    st = await page.evaluate(() => {
      const v = window.__view();
      const items = window.tunaViews.viewItems(v);
      const last = window.tunaViews.box(items[items.length - 1]);
      const b = v.getBoundingClientRect();
      return { bottom: last.bottom, edge: b.top + v.clientTop + v.clientHeight, text: items[items.length - 1].textContent,
               end: v.scrollTop + v.clientHeight >= v.scrollHeight - 1 };
    });
    check(tag("thumb dragged past the end"), st.end && near(st.bottom, st.edge, 1), `last item's bottom ${st.bottom} at the edge ${st.edge}`);
    await scrollTo(page, 24 * 2000);
    await repl(t.tuna, "(goto-line! 2010)");
    await settle(page);
    const m0 = JSON.parse(await repl(t.tuna, "mouse-items"));
    const t0 = (await state(page)).scrollTop;
    await page.mouse.move(th.x, th.top + th.height - th.start - 5);
    await page.mouse.down();
    await page.mouse.up();
    await settle(page, 600);
    const t1 = await state(page);
    const m1 = JSON.parse(await repl(t.tuna, "mouse-items"));
    point = JSON.parse(await repl(t.tuna, "(car (point-at))"));
    const firstLine = t1.first.offset >= -0.5 ? t1.first.slot + 1 : t1.first.slot + 2;
    check(tag("a press in the trough pages"), t1.scrollTop > t0 && m1 === m0 && point >= firstLine,
      `paged ${t1.scrollTop - t0} px, mouse items ${m1 - m0}, point ${point}, first row ${firstLine}`);

    // A fast drag over a million lines shows drawn items a round trip
    // after it stops.
    await show(t, page, "(show-lines! 1000000)", 1000001);
    await scrollTo(page, 0);
    const big = await thumbOf(page);
    await scrollTo(page, 0);
    const bigGrab = big.top + big.start + (big.end - big.start) / 2;
    await page.mouse.move(big.x, bigGrab);
    await page.mouse.down();
    await page.mouse.move(big.x, big.top + big.height / 2, { steps: 4 });
    const stopped = Date.now();
    await page.mouse.up();
    await page.waitForFunction(() => {
      const s = window.__state();
      return s.first !== null && s.first.slot > 1000;
    }, null, { timeout: 5000 }).catch(() => {});
    const waited = Date.now() - stopped;
    st = await state(page);
    check(tag("fast drag over a million lines"), st.first !== null && st.first.slot > 1000 && waited < 2000, `drawn ${waited} ms after the drag stopped, at line ${st.first?.slot + 1}`);

    // The scroll height stays under 4,000,000 px; the first 100 view
    // heights scroll one to one; drawn items keep their size.
    st = await state(page);
    await scrollTo(page, st.clientHeight * 50);
    st = await state(page);
    const want = Math.floor((st.clientHeight * 50) / st.lineHeight) + 1;
    const h = await page.evaluate(() => window.tunaViews.box(window.tunaViews.viewItems(window.__view())[5]).height);
    check(tag("scroll height capped"), st.scrollHeight <= 4000000 && Number(st.first.text.slice(5)) === want && near(h, st.lineHeight, 0.5),
      `scroll height ${st.scrollHeight}, line ${st.first.text} at 50 view heights (${want}), item ${h} px`);

    // Items of many heights keep one scroll height once measured, whichever
    // item ends the drawn run: a chat, and M-x's list, whose first item
    // has no box.
    await repl(t.tuna, "(show-chat! 300)");
    await page.waitForFunction(() => window.__state()?.firstDrawn?.startsWith("Reply 0"));
    await settle(page);
    let seen = await secondPassHeights(page, ".layout-view.selected .view[data-placement]", 10, 600);
    check(tag("a chat keeps its scroll height"), seen.size === 1, `heights on a second pass ${[...seen].join(" ")}`);
    await page.keyboard.press("Alt+x");
    await page.waitForFunction(() => document.querySelectorAll(".ui-list-row").length > 20);
    await settle(page);
    seen = await secondPassHeights(page, ".view:has(> .view-lines > .minibuffer-prompts) .view[data-placement]", 10, 300);
    check(tag("M-x's list keeps its scroll height"), seen.size === 1, `heights on a second pass ${[...seen].join(" ")}`);
    await page.keyboard.press("Control+g");
    await settle(page);
  } finally {
    await browser.close();
  }
}

// A finger's swipe through CDP's touch events, which the browser turns
// into a scroll and its fling; its synthesized scroll gesture moves no
// inner scroller under touch.
async function fling(page, x, y, distance, hold = false) {
  const cdp = await page.context().newCDPSession(page);
  const steps = 12;
  await cdp.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x, y }] });
  for (let i = 1; i <= steps; i++) {
    await cdp.send("Input.dispatchTouchEvent", { type: "touchMove", touchPoints: [{ x, y: y - (distance * i) / steps }] });
    await sleep(8);
  }
  if (!hold) await cdp.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
  return cdp;
}

// The writes to the offset from the gesture's start until its scroll
// first rests, when the browser ends the fling.
async function flung(page, gesture) {
  await page.evaluate(() => {
    const v = window.__view();
    window.__flung = { writes: window.tunaViews.writes(), ended: null };
    v.addEventListener("scrollend", () => { window.__flung.ended = window.tunaViews.writes() - window.__flung.writes; }, { once: true });
  });
  await gesture();
  await page.waitForFunction(() => window.__flung.ended !== null, null, { timeout: 10000 }).catch(() => {});
  return page.evaluate(() => window.__flung.ended);
}

async function phone(t, name) {
  const { browser, page } = await opened(t, name, { width: 390, height: 760, mobile: true });
  const tag = (id) => `${id} ${name} 390`;
  try {
    await show(t, page, "(show-lines! 10000)", 10001);
    const s = await page.evaluate(() => {
      const v = window.__view();
      return { tall: v.scrollHeight > v.clientHeight, drawn: document.querySelectorAll(".view-scroll-bar, .view-thumb").length };
    });
    check(tag("the browser's own bar"), s.tall && s.drawn === 0, `drawn bars ${s.drawn}`);
    await scrollTo(page, 24 * 300);
    const c = await focusView(page);
    let before = await topItem(page);
    await page.mouse.wheel(0, 100);
    await settle(page);
    const after = await offsetOf(page, before.id);
    let st = await state(page);
    check(tag("a wheel step moves the text by the step"), near(st.scrollTop - before.scrollTop, 100, 0.5) && near(before.offset - after, 100, 0.5),
      `scrolled ${st.scrollTop - before.scrollTop}, item moved ${before.offset - after}`);
    if (name === "chromium") {
      // A fling runs to its end with no write; at rest one write.
      await scrollTo(page, 24 * 3000);
      const at0 = (await state(page)).scrollTop;
      const during = await flung(page, () => fling(page, c.x, c.y + 200, 500));
      await settle(page, 600);
      st = await state(page);
      check(tag("a fling runs with no write"), during === 0 && st.scrollTop > at0 + 500, `writes while flinging ${during}, flung ${st.scrollTop - at0} px`);
      // An upward fling reaches the start with no write.
      await scrollTo(page, st.clientHeight * 2);
      const writes = await flung(page, () => fling(page, c.x, c.y - 300, -900));
      const r = { writes, top: (await state(page)).scrollTop };
      await settle(page, 600);
      st = await state(page);
      check(tag("an upward fling reaches the start"), r.writes === 0 && r.top === 0 && st.first.text === "line 00001", `writes ${r.writes}, stopped at ${r.top}, top ${st.first.text}`);
      // A fling stopped by a finger that stays down rests only when
      // the finger lifts.
      await scrollTo(page, 24 * 3000);
      const sent = watchReports(page);
      const cdp = await fling(page, c.x, c.y + 200, 500, true);
      await sleep(1200);
      // Chromium sends no scroll end while the finger is down, as a
      // browser may, so one is sent by hand.
      await page.evaluate(() => window.__view().dispatchEvent(new Event("scrollend")));
      await sleep(300);
      const held = sent.filter((r) => r.settled === true).length;
      await cdp.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
      await settle(page, 600);
      const rests = sent.filter((r) => r.settled === true).length;
      check(tag("no rest while a finger is down"), held === 0 && rests >= 1, `rests while the finger was down ${held}, after ${rests}`);
    }
  } finally {
    await browser.close();
  }
}

const began = Date.now();
const t = await start(bin, "bars");
try {
  for (const name of browsers()) {
    await desktop(t, name);
    await phone(t, name);
  }
} finally {
  await stop(t);
}
console.log(`took ${Math.round((Date.now() - began) / 1000)} s`);
results.end();

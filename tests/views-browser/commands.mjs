// The scroll commands as the page carries them out, in a view of 21 rows
// over a buffer of 200 lines, line 001 to line 200, where each leaves the
// top and point where Emacs leaves them in a window of that size.
import { launch, start, stop, state, settle, repl, sleep, fitRows, Results, browsers } from "./common.mjs";

const bin = process.argv[2];
const results = new Results("views-commands-browser");

async function opened(t, name, width, mobile) {
  const b = await launch(name, { width, height: 800, mobile });
  await b.page.goto(t.tuna.url);
  await b.page.waitForSelector(".layout-view.selected .view[data-placement]");
  return b;
}

async function suite(t, name, width, mobile) {
  const { browser, page } = await opened(t, name, width, mobile);
  const tag = (id) => `${id} ${name} ${width}`;
  const top = async () => {
    const s = await state(page);
    return s.first.line + (s.first.offset < -0.5 ? 1 : 0);
  };
  const point = async () => (await repl(t.tuna, "(point-at)")).slice(1, -1).split(" ").map(Number);
  const keys = async (...ks) => {
    for (const k of ks) {
      if (k.length > 1 && !k.includes("+") && !["Enter", "Escape"].includes(k)) await page.keyboard.type(k);
      else await page.keyboard.press(k);
    }
    await settle(page);
  };
  const echo = () => page.evaluate(() => document.querySelector(".echo-area-message")?.textContent ?? "");
  const expect = async (id, wantTop, wantPoint) => {
    const [tp, pt] = [await top(), await point()];
    const ok = tp === wantTop && (wantPoint === null || (pt[0] === wantPoint[0] && pt[1] === wantPoint[1]));
    results.check(tag(id), ok, `top ${tp}${wantPoint ? ` point ${pt.join(":")}` : ""}`);
  };
  // Point first, then the view, so the placement is the view's and
  // following point does not move it.
  const place = async (topLine, pointLine, column = 0) => {
    await repl(t.tuna, `(views:set-point! (sv) (+ (max 1 (line-start ${pointLine})) ${column}))`);
    await settle(page);
    await repl(t.tuna, `(views:scroll-to! (sv) (max 1 (line-start ${topLine})) (views:align top))`);
    await settle(page);
  };
  try {
    await repl(t.tuna, "(show-lines! 200)");
    await page.waitForFunction(() => window.__state()?.slots === 201);
    await fitRows(page, width, 21);
    await page.mouse.click(10, 10);
    await place(1, 1);

    await keys("Control+v");
    await expect("C-v from the top", 20, [20, 0]);
    await keys("Control+v");
    await expect("C-v again", 39, [39, 0]);
    await keys("Alt+v");
    await expect("M-v", 20, [39, 0]);
    await keys("Control+u", "3", "Control+v");
    await expect("C-u 3 C-v", 23, [39, 0]);
    await keys("Control+u", "-", "3", "Control+v");
    await expect("C-u - 3 C-v", 20, [39, 0]);
    await keys("Control+u", "-", "Control+v");
    await expect("C-u - C-v", 1, [21, 0]);

    await keys("Alt+Shift+Period");
    await expect("M->", 181, [201, 0]);
    await keys("Control+v");
    const end = await echo();
    await expect(`C-v at the end (${end})`, 181, [201, 0]);
    results.check(tag("C-v at the end says so"), /end of buffer/i.test(end), end);
    await keys("Alt+Shift+Comma");
    await expect("M-<", 1, [1, 0]);
    await keys("Alt+v");
    const start = await echo();
    await expect("M-v at the start", 1, [1, 0]);
    results.check(tag("M-v at the start says so"), /beginning of buffer/i.test(start), start);

    await place(1, 21);
    await keys("Control+l");
    await expect("C-l centres point", 11, [21, 0]);
    await keys("Control+l");
    await expect("C-l again puts point at the top", 21, [21, 0]);
    await keys("Control+l");
    await expect("C-l a third time puts point at the bottom", 1, [21, 0]);
    await keys("Control+l");
    await expect("C-l a fourth time centres point", 11, [21, 0]);

    await place(1, 1);
    await keys("Alt+g", "g", "150", "Enter");
    await expect("M-g g 150", 140, [150, 0]);
    await keys("Alt+g", "g", "145", "Enter");
    await expect("M-g g 145", 135, [145, 0]);
    await keys("Control+s", "line 190", "Enter");
    await expect("C-s line 190", 180, [190, 8]);
    await keys("Control+r", "line 020", "Enter");
    await expect("C-r line 020", 10, [20, 0]);

    await place(1, 21);
    await keys("Control+n");
    await expect("C-n on the last row", 2, [22, 0]);
    await place(12, 12);
    await keys("Control+p");
    await expect("C-p on the first row", 11, [11, 0]);

    await place(1, 11);
    await keys("Alt+r");
    await expect("M-r to the middle", 1, [11, 0]);
    await keys("Alt+r");
    await expect("M-r to the top", 1, [1, 0]);
    await keys("Alt+r");
    await expect("M-r to the bottom", 1, [21, 0]);

    await place(1, 1);
    await keys("Alt+g", "g", "195", "Enter");
    await expect("M-g g 195", 181, [195, 0]);
    await keys("Control+l", "Control+l");
    await expect("C-l C-l near the end", 181, [195, 0]);
    await place(170, 170);
    await keys("Control+v");
    await expect("C-v onto the last page", 181, [181, 0]);
    await keys("Control+v");
    const again = await echo();
    await expect("C-v on the last page", 181, [181, 0]);
    results.check(tag("C-v on the last page says so"), /end of buffer/i.test(again), again);
    await place(1, 1);
    await keys("Control+s", "line 199", "Enter");
    await expect("C-s line 199", 181, [199, 8]);
    await place(1, 1);
    await keys("Control+s", "line 030", "Enter");
    await expect("C-s line 030", 10, [30, 8]);

    await repl(t.tuna, "(show-target!)");
    await page.waitForFunction(() => window.__state()?.slots === 200);
    await place(1, 2, 44);
    await keys("Alt+Period");
    await expect("M-. centres the definition", 140, [150, 0]);
    await keys("Alt+Comma");
    await expect("M-, goes back", 1, [2, 44]);
  } finally {
    await browser.close();
  }
}

const began = Date.now();
const t = await start(bin, "commands");
try {
  for (const name of browsers()) {
    await suite(t, name, 1280, false);
    await suite(t, name, 390, true);
  }
} finally {
  await stop(t);
}
console.log(`took ${Math.round((Date.now() - began) / 1000)} s`);
results.end();

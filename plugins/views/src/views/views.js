import { send, define } from "tuna";

const { number, box, viewItems, contentTop, extent, own, lineHeight, setScroll, byHand, forgetWrite, sideways,
        textLeft, textRight, pieces, longLines, textBox, pointExtent, margin, follow, keepAt, charWidth, contentSize,
        charsPerRow, px, setBlock, setGap, rowGaps, sizeSpacers, placeView, firstEdge, extentOf } = window.tunaViews;

// Kept by element, so a view element the morph makes anew is placed
// again.
const states = new WeakMap();
let reports = 0;
let screens = 0;

function newState() {
  return {
    placed: null, hand: false, moving: false, scrolling: false, drag: null, handMoved: 0,
    held: null, wasAtEnd: false, edge: "top", edgeReported: null, pointShown: false,
    sent: null, owed: false, last: null, ask: null, named: null,
    reportedCells: null, currentCells: null, map: null, lines: null, input: "mouse",
  };
}

function drawnScreens(view) {
  return number(view, "data-drawn-screens") ?? 2;
}

function atEnd(view) {
  return view.hasAttribute("data-run-at-end") && view.scrollTop + view.clientHeight >= view.scrollHeight - 1;
}

function toEnd(view) {
  setScroll(view, view.scrollHeight - view.clientHeight);
}

function mark(element) {
  const at = number(element, "data-at");
  return at !== null ? { at } : { line: number(element, "data-line") };
}

// A spacer or a gap stands for text never drawn, so a place in it is the
// character its share counts to, as its share of the scroll bar is.
function markInto(element, into) {
  const chars = number(element, "data-chars") ?? 0;
  return { ...mark(element), chars: Math.min(Math.max(0, chars - 1), Math.max(0, Math.floor(into))) };
}

function markAtShare(element, share) {
  return markInto(element, Math.min(1, Math.max(0, share)) * (number(element, "data-chars") ?? 0));
}

function spacerMark(view, spacer, k) {
  const before = spacer.getAttribute("data-spacer") === "above" ? 0
    : (number(view, "data-chars") ?? 0) - (number(spacer, "data-chars") ?? 0);
  return markInto(spacer, k - before);
}

function spacerAt(view, y) {
  for (const spacer of view.querySelectorAll(":scope > [data-spacer]")) {
    const b = spacer.getBoundingClientRect();
    if (b.height > 0 && b.top <= y && y < b.bottom) return spacer;
  }
  return null;
}

function spacerMarkAtY(spacer, y) {
  const b = spacer.getBoundingClientRect();
  return markAtShare(spacer, (y - b.top) / Math.max(1, b.height));
}

// A place inside a part, a spacer or an item, is the same share of its
// characters as of its height. Parts are measured only where a search
// lands, since a screen holds hundreds and a search reads a few.
function textMap(view) {
  const total = number(view, "data-chars") ?? 0;
  const above = view.querySelector(':scope > [data-spacer="above"]');
  const below = view.querySelector(':scope > [data-spacer="below"]');
  const found = [];
  if (above !== null) found.push([above, 0]);
  for (const item of viewItems(view)) {
    const before = number(item, "data-before");
    if (before !== null) found.push([item, before]);
  }
  if (below !== null) found.push([below, total - (number(below, "data-chars") ?? 0)]);
  const parts = found.map(([element, before], i) => ({
    element, before, chars: Math.max(0, (i + 1 < found.length ? found[i + 1][1] : total) - before),
    spacer: element.hasAttribute("data-spacer"), extent: undefined,
  }));
  return { view, total, parts };
}

function mapOf(view, st) {
  return st.map ?? (st.map = textMap(view));
}

function partExtent(map, part) {
  if (part.extent === undefined) part.extent = extent(map.view, part.element);
  return part.extent;
}

function firstNotBefore(all, before) {
  let low = 0;
  let high = all.length;
  while (low < high) {
    const middle = (low + high) >> 1;
    if (before(all[middle])) low = middle + 1; else high = middle;
  }
  return low;
}

// Y counts in the view's scrolling, not on the screen.
function partAtY(map, y) {
  const end = firstNotBefore(map.parts, (part) => {
    const e = partExtent(map, part);
    return e === null || e.top <= y;
  });
  for (let i = end - 1; i >= 0; i--) {
    if (partExtent(map, map.parts[i]) !== null) return i;
  }
  return -1;
}

function charsAtY(map, y) {
  const i = partAtY(map, y);
  if (i < 0) return 0;
  const part = map.parts[i];
  const e = partExtent(map, part);
  return part.before + Math.min(1, Math.max(0, (y - e.top) / Math.max(1, e.height))) * part.chars;
}

function yAtChars(map, k) {
  const end = firstNotBefore(map.parts, (part) => part.before <= k);
  for (let i = end - 1; i >= 0; i--) {
    const part = map.parts[i];
    const e = partExtent(map, part);
    if (e !== null) {
      return { top: e.top + (part.chars > 0 ? Math.min(1, (k - part.before) / part.chars) * e.height : 0), part };
    }
  }
  return { top: 0, part: null };
}

function topItem(view) {
  const top = contentTop(view);
  for (const item of viewItems(view)) {
    const b = box(item);
    if (b !== null && b.bottom > top) return { item, box: b };
  }
  return null;
}

// The drawn item at the top edge, or, where the top edge lies in a
// spacer, the drawn one nearest it, so a new run moves nothing drawn.
function heldItem(view) {
  const found = topItem(view);
  if (found !== null) return found;
  const all = viewItems(view);
  for (let i = all.length - 1; i >= 0; i--) {
    const b = box(all[i]);
    if (b !== null) return { item: all[i], box: b };
  }
  return null;
}

// What the estimates are made in: a resize, a font that loads or another
// buffer makes them anew.
function basis(view) {
  return `${lineHeight(view)} ${contentSize(view).width} ${charWidth(view)} ${view.getAttribute("data-showing")}`;
}

function measureRows(view) {
  const starts = new Map();
  if (sideways(view)) return starts;
  const left = textLeft(view);
  for (const segment of view.querySelectorAll(".line[data-segment]")) {
    if (!segment.id || !own(view, segment)) continue;
    const first = segment.getClientRects()[0];
    if (first) starts.set(segment.id, first.left - left);
  }
  return starts;
}

// A long line's rows all wrap from where its first drawn segment
// starts, so the gap before that segment puts the first segment drawn
// before at the x it had, and every row after wraps as it did. A
// segment drawn before others that are new is found by steps, since
// where words wrap the x does not follow the gap's width exactly; each
// step must come closer.
function holdRows(view, starts) {
  const left = textLeft(view);
  const width = charsPerRow(view) * charWidth(view);
  for (const gap of rowGaps(view)) {
    let segment = gap.nextElementSibling;
    while (segment !== null && !(segment.hasAttribute("data-segment") && starts.has(segment.id))) {
      segment = segment.getAttribute("data-line") === gap.getAttribute("data-line") ? segment.nextElementSibling : null;
    }
    if (segment === null) continue;
    const want = starts.get(segment.id);
    let size = parseFloat(gap.style.getPropertyValue("--views-gap")) || 0;
    let best = { size, miss: Infinity };
    for (;;) {
      const first = segment.getClientRects()[0];
      if (!first) break;
      const off = want - (first.left - left);
      if (Math.abs(off) >= best.miss) {
        setGap(gap, best.size);
        break;
      }
      best = { size, miss: Math.abs(off) };
      if (Math.abs(off) < 0.5) break;
      size = (((size + off) % width) + width) % width;
      setGap(gap, size);
    }
  }
}

// Sideways the offset holds the drawn segment at the left edge, as it
// holds the item at the top. A font that loads or a resize changes the
// segment's width, so then the fraction of it before the edge is held.
function measureSide(view) {
  if (!sideways(view)) return null;
  const top = contentTop(view);
  const bottom = top + view.clientHeight;
  const edge = textLeft(view);
  for (const segment of view.querySelectorAll(".segment")) {
    if (!segment.id || !own(view, segment)) continue;
    const b = segment.getBoundingClientRect();
    if (b.bottom > top && b.top < bottom && b.left <= edge && b.right > edge) {
      return { id: segment.id, from: b.left - edge, fraction: (edge - b.left) / Math.max(1, b.width) };
    }
  }
  return null;
}

function holdSide(view, side, same, owned) {
  if (side === null) return;
  const segment = document.getElementById(side.id);
  if (segment === null || !own(view, segment)) return;
  const b = segment.getBoundingClientRect();
  const edge = textLeft(view);
  const shift = same ? b.left - (edge + side.from) : b.left + side.fraction * b.width - edge;
  if (Math.abs(shift) <= 0.5) return;
  if (!owned) {
    setScroll(view, view.scrollTop, view.scrollLeft + shift);
    return;
  }
  let gap = segment.previousElementSibling;
  while (gap !== null && !gap.hasAttribute("data-gap")) gap = gap.previousElementSibling;
  if (gap !== null) setGap(gap, Math.max(0, gap.getBoundingClientRect().width - shift));
}

// Datastar's morph reuses an element without an id for whatever new
// content stands where it stood, and the browser's own scroll anchoring
// holds such elements still: it moved the view by the rows a cursor's
// move shifted the text node it held. The page holds an item still by
// its id instead, as CodeMirror holds a line block.
function capture(view, st) {
  // The browser sends a scroll event when it next paints, so a screen
  // can find the hand's scroll before its event does.
  const h = st.held;
  if (h !== null && (Math.abs(view.scrollTop - h.top) > 0.5 || Math.abs(view.scrollLeft - h.left) > 0.5)
      && byHand(view)) {
    handScrolled(view, st);
    st.scrolling = true;
  }
  // What the hand scrolled since the last capture: the page's own writes
  // come before a capture, so they are never counted, nor a resize.
  if (h !== null && byHand(view)) st.handMoved += view.scrollTop - h.top;
  const found = heldItem(view);
  st.held = {
    top: view.scrollTop,
    left: view.scrollLeft,
    item: found && found.item.id ? { id: found.item.id, offset: found.box.top - contentTop(view) } : null,
    basis: basis(view),
    rows: measureRows(view),
    side: measureSide(view),
  };
  st.wasAtEnd = atEnd(view);
}

// What is drawn stays still: the scroll offset follows the held item,
// since a spacer is only its guess and keeps nothing of what was drawn,
// and no scroll bar the hand holds is drawn from the offset. While the
// hand's scroll runs, the spacer above takes the shift instead, until
// the scroll ends: Safari ends a fling's momentum at any write to the
// offset, and WebKit ends a wheel turn's animation.
function hold(view, st) {
  const h = st.held;
  if (h === null) return;
  const same = h.basis === basis(view);
  holdRows(view, same ? h.rows : new Map());
  holdSide(view, h.side, same, handOwns(st));
  if (h.item === null) return;
  const item = document.getElementById(h.item.id);
  const b = item && own(view, item) ? box(item) : null;
  if (b === null) return;
  moveDrawn(view, st, b.top - contentTop(view) - h.item.offset);
}

// While the hand owns the offset, what no spacer above can take, as when
// the run reaches the start, moves the drawn text once: the few rows
// drawn in the last spacer's place are its only error, and a write
// would stop the hand's scroll short of the top.
function moveDrawn(view, st, shift) {
  if (Math.abs(shift) <= 0.5) return;
  if (handOwns(st)) growAbove(view, -shift);
  else setScroll(view, view.scrollTop + shift);
}

// A spacer is a guess, and no thumb is drawn from its pixels, so it can
// take what would move the drawn text while the hand's scroll owns the
// offset.
function growAbove(view, by) {
  const above = view.querySelector(':scope > [data-spacer="above"]');
  if (above !== null) setBlock(above, Math.max(0, above.getBoundingClientRect().height + by));
}

// A thumb the page drags writes the offset itself.
function handOwns(st) {
  return st.scrolling && st.drag === null;
}

// The placement that answers this page's report from a spacer: the
// place it named is drawn now, and goes where the page named it, moved
// as far as the hand has scrolled since.
function namedPlace(view, st, placement) {
  const n = st.named;
  if (n === null || placement === st.placed || view.getAttribute("data-place-kind") !== "position"
      || number(view, "data-reported") !== n.report) return null;
  return n;
}

function following(view, st) {
  return view.getAttribute("data-place-kind") === "follow" && !st.hand;
}

function afterChange(view, st, fresh) {
  const lines = view.querySelector(":scope > .view-lines");
  if (lines !== st.lines) {
    if (st.lines) sizes.unobserve(st.lines);
    if (lines) sizes.observe(lines);
    st.lines = lines;
  }
  sizeSpacers(view, handOwns(st));
  const placement = number(view, "data-placement");
  const named = fresh ? null : namedPlace(view, st, placement);
  if (!fresh) hold(view, st);
  st.map = textMap(view);
  if (named !== null) {
    moveDrawn(view, st, yAtChars(st.map, named.chars).top + (st.handMoved - named.hand) - view.scrollTop);
    if (handOwns(st)) st.map = textMap(view);
    st.placed = placement;
    st.pointShown = false;
    st.owed = st.moving ? true : "settled";
  } else if (fresh || placement !== st.placed) {
    // A placement the first screen's script carried out is carried out
    // again, since a web font may have loaded since and moved the text.
    const placed = placeView(view, fresh);
    placeRows(view);
    st.placed = placement;
    st.pointShown = false;
    st.hand = false;
    st.edge = (fresh ? firstEdge(view, placement) : null) ?? placed;
    st.owed = true;
  } else {
    if (view.hasAttribute("data-tail") && st.wasAtEnd) toEnd(view);
    // Point stays in view after every change while the view follows it,
    // as Emacs's redisplay keeps it, not only after a command moved it.
    if (following(view, st)) {
      if (view.hasAttribute("data-lead")) st.edge = follow(view) ?? st.edge;
      else keepAt(view, view.getAttribute("data-place-edge") ?? "top");
    }
  }
  if (st.drag !== null) dragTo(view, st);
  const reported = number(view, "data-reported");
  if (st.sent !== null && reported === st.sent) st.sent = null;
  if (st.named !== null && reported !== null && reported >= st.named.report) st.named = null;
  capture(view, st);
  drawBars(view, st);
  if (!sendMove(view)) reportIfDue(view, st, false);
  if (st.drag !== null && st.drag.released && st.drag.drawn) dragEnded(view, st);
}

function elementOf(node) {
  return node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
}

// A segment holds text from data-at to data-to; any other element
// marked with data-to stands for tokens.
function standsForTokens(element) {
  return element.hasAttribute("data-to") && !element.classList.contains("segment");
}

function markedAncestor(element, view, token) {
  for (let e = element; e !== null && e !== view; e = e.parentElement) {
    if (standsForTokens(e)) return e;
    if (!token && (e.hasAttribute("data-at") || e.hasAttribute("data-line"))) return e;
  }
  return null;
}

function codePoints(text) {
  let n = 0;
  for (const _ of text) n++;
  return n;
}

// Tuna draws marks only where a line's characters stop being the
// buffer's next tokens: past an element that stands for tokens, the
// count starts again after them.
// A run of raw bytes or control characters is one element, so the
// caret's offset in it names the token.
function placeIn(marked, node, offset) {
  if (standsForTokens(marked)) {
    const glyphs = number(marked, "data-glyphs");
    const at = number(marked, "data-at");
    if (glyphs === null || node === undefined) return { token: at };
    const range = document.createRange();
    range.selectNodeContents(marked);
    range.setEnd(node, offset);
    return { token: Math.min(number(marked, "data-to") - 1, at + Math.floor(codePoints(range.toString()) / glyphs)) };
  }
  let at = number(marked, "data-at");
  let count = 0;
  let done = false;
  const visit = (n) => {
    if (n === node) {
      if (n.nodeType === Node.TEXT_NODE) count += codePoints(n.data.slice(0, offset));
      else for (let i = 0; i < offset && i < n.childNodes.length && !done; i++) visit(n.childNodes[i]);
      done = true;
    } else if (n.nodeType === Node.TEXT_NODE) {
      count += codePoints(n.data);
    } else if (n.nodeType === Node.ELEMENT_NODE) {
      if (n !== marked && standsForTokens(n)) {
        at = number(n, "data-to");
        count = 0;
      } else {
        if (n !== marked && n.classList.contains("segment")) {
          at = number(n, "data-at");
          count = 0;
        }
        for (const child of n.childNodes) {
          visit(child);
          if (done) return;
        }
      }
    }
  };
  visit(marked);
  return at !== null ? { at, count } : { line: number(marked, "data-line"), count };
}

// WebKit gives an offset past the end of an empty element, such as a
// gap, under the point.
function caretAt(x, y) {
  const within = (node, offset) =>
    ({ node, offset: Math.min(offset, node.nodeType === Node.TEXT_NODE ? node.data.length : node.childNodes.length) });
  if (typeof document.caretPositionFromPoint === "function") {
    const caret = document.caretPositionFromPoint(x, y);
    return caret && within(caret.offsetNode, caret.offset);
  }
  if (typeof document.caretRangeFromPoint === "function") {
    const range = document.caretRangeFromPoint(x, y);
    return range && within(range.startContainer, range.startOffset);
  }
  return null;
}

function caretBox(caret) {
  const range = document.createRange();
  range.setStart(caret.node, caret.offset);
  range.collapse(true);
  const rects = range.getClientRects();
  if (rects.length > 0) return rects[0];
  const element = caret.node.nodeType === Node.ELEMENT_NODE ? caret.node.childNodes[caret.offset] ?? caret.node : caret.node.parentElement;
  return element instanceof Element ? element.getBoundingClientRect() : null;
}

function ownLines(view) {
  return Array.from(view.querySelectorAll(".line[data-line]")).filter((line) => own(view, line));
}

function firstEndingBelow(lines, y) {
  return firstNotBefore(lines, (line) => line.getBoundingClientRect().bottom <= y);
}

function lineAbove(view, y) {
  const lines = ownLines(view);
  const i = firstEndingBelow(lines, y);
  if (i < lines.length && lines[i].getBoundingClientRect().top <= y) return lines[i];
  return i > 0 ? lines[i - 1] : null;
}

function placeOf(view, target, x, y) {
  const caret = caretAt(x, y);
  const caretElement = caret && elementOf(caret.node);
  const inView = caretElement !== null && caretElement !== undefined && own(view, caretElement);
  const token = target instanceof Element ? markedAncestor(target, view, true) : null;
  if (token !== null && !(inView && token.contains(caretElement))) return placeIn(token);
  if (inView) {
    const marked = markedAncestor(caretElement, view, false);
    const line = caretElement.closest(".line");
    if (marked !== null && !(line !== null && view.contains(line) && y > line.getBoundingClientRect().bottom)) {
      return placeIn(marked, caret.node, caret.offset);
    }
  }
  const line = lineAbove(view, y);
  return line === null ? null : placeIn(line, line, line.childNodes.length);
}

function markAtX(line, x, y) {
  for (const piece of pieces(line)) {
    const b = piece.getBoundingClientRect();
    if (x < b.left || x >= b.right) continue;
    if (piece.hasAttribute("data-gap")) return markAtShare(piece, (x - b.left) / Math.max(1, b.width));
    const caret = caretAt(x, y);
    if (caret && piece.contains(caret.node)) return placeIn(piece, caret.node, caret.offset);
    const at = number(piece, "data-at");
    const length = number(piece, "data-to") - at;
    return { at, count: Math.min(length - 1, Math.floor(((x - b.left) / Math.max(1, b.width)) * length)) };
  }
  const all = pieces(line);
  if (all.length > 0) {
    const last = all[all.length - 1];
    return last.hasAttribute("data-gap")
      ? { at: number(last, "data-at"), chars: Math.max(0, (number(last, "data-chars") ?? 1) - 1) }
      : { at: number(last, "data-to") - 1 };
  }
  const caret = caretAt(x, y);
  return caret && line.contains(caret.node) ? placeIn(line, caret.node, caret.offset) : placeIn(line, line, line.childNodes.length);
}

// A caret at the start of a wrapped row is also the end of the row
// before, and Chrome gives one on the row before, so the row's start is
// its first character whose box is on the row.
function rowAt(view, x, y) {
  const target = document.elementFromPoint(x, y);
  if (!target || !view.contains(target)) return null;
  const caret = caretAt(x, y);
  let b = caret && caretBox(caret);
  if (!b) return null;
  if (caret.node.nodeType === Node.TEXT_NODE) {
    const range = document.createRange();
    const half = lineHeight(view) / 2;
    while (caret.offset < caret.node.data.length) {
      range.setStart(caret.node, caret.offset);
      range.setEnd(caret.node, caret.offset + 1);
      const r = range.getBoundingClientRect();
      if (r.bottom > y - half) { b = r; break; }
      caret.offset++;
    }
  }
  const element = elementOf(caret.node);
  const marked = element && view.contains(element) ? markedAncestor(element, view, false) : null;
  const at = marked !== null ? placeIn(marked, caret.node, caret.offset) : placeOf(view, target, x, y);
  return at ? { at, top: b.top, bottom: b.bottom } : null;
}

function rowAtY(view, x, y) {
  const spacer = spacerAt(view, y);
  if (spacer === null) return rowAt(view, x, y);
  const lh = lineHeight(view);
  const b = spacer.getBoundingClientRect();
  const top = b.top + Math.floor((y - b.top) / lh) * lh;
  return { at: spacerMarkAtY(spacer, top), top, bottom: top + lh };
}

function rowsInView(view) {
  const lh = lineHeight(view);
  const top = contentTop(view);
  const bottom = top + view.clientHeight;
  const m = margin(view);
  const x = textLeft(view) + 1;
  let first = rowAtY(view, x, top + m + 1);
  if (first !== null && first.top < top + m - 0.5) first = rowAtY(view, x, first.top + 1.5 * lh) ?? first;
  let last = rowAtY(view, x, bottom - m - 1);
  if (last !== null && last.bottom > bottom - m + 0.5) last = rowAtY(view, x, last.bottom - 1.5 * lh) ?? last;
  return { start: first?.at ?? null, end: last?.at ?? null };
}

// The rows wholly in view, top to bottom, as Emacs counts a window's
// lines: a row partly above the top edge is not one.
function rowsShown(view) {
  const lh = lineHeight(view);
  const top = contentTop(view);
  const bottom = top + view.clientHeight;
  const x = textLeft(view) + 1;
  const rows = [];
  let y = top + 1;
  while (y < bottom) {
    const row = rowAtY(view, x, y);
    if (row === null) { y += lh; continue; }
    if (row.top >= top - 0.5 && row.bottom <= bottom + 0.5) rows.push(row);
    y = Math.max(y + 1, row.bottom + 1);
  }
  return rows;
}

// As Emacs's recenter counts screen lines, the rows a placement asks for
// are the rows M-r counts, wherever their heights differ, and stay
// outside the scroll margin, at most a quarter of them.
function placeRows(view) {
  const asked = number(view, "data-place-rows");
  const kind = view.getAttribute("data-place-kind");
  const b = asked === null ? null : extentOf(view, ".view-place", number(view, "data-place-at"));
  if (b === null || (kind !== "top" && kind !== "bottom")) return;
  const rows = rowsShown(view);
  const top = contentTop(view);
  const y = b.top - view.scrollTop + top + 0.5;
  const at = rows.findIndex((row) => row.top <= y && y < row.bottom);
  if (at < 0) return;
  const m = Math.min(number(view, "data-scroll-margin") ?? 0, Math.floor(rows.length / 4));
  const n = Math.max(m, Math.min(asked, rows.length - 1 - m));
  if (kind === "top") setScroll(view, view.scrollTop + rows[Math.max(0, at - n)].top - top);
  else setScroll(view, view.scrollTop + rows[Math.min(rows.length - 1, at + n)].bottom - (top + view.clientHeight));
}

function inViewRows(view, element) {
  const b = element.getBoundingClientRect();
  const top = contentTop(view);
  return b.bottom > top + 0.5 && b.top < top + view.clientHeight - 0.5;
}

function rowY(view, b) {
  const top = contentTop(view);
  return Math.min(Math.max(b.top + b.height / 2, top + 1), top + view.clientHeight - 1);
}

// The column at the left edge is counted on the first line in view that
// reaches it, in positions from its start, and past a line's end in
// cells, as Emacs counts columns past a line's end; where no line
// reaches it, on the first line in view.
function columnOf(view) {
  if (!sideways(view)) return { left: null, past: 0 };
  const left = textLeft(view);
  const shown = ownLines(view).filter((line) => inViewRows(view, line));
  if (shown.length === 0) return { left: null, past: 0 };
  const reaching = shown.find((line) => textBox(line).right > left + 0.5);
  const line = reaching ?? shown[0];
  const b = textBox(line);
  const at = markAtX(line, reaching ? left + 0.5 : b.right - 0.5, rowY(view, b));
  return { left: at, past: reaching ? 0 : Math.max(0, Math.round((left - b.right) / charWidth(view))) };
}

// Each long line drawn names the positions at its own edges, since a
// line of wider characters shows fewer at the same scroll offset; one
// above or below the view too, or it would be drawn around a column
// counted on another line, its end drawn where the view is not, and
// its width would change the scroll width.
function sidesOf(view) {
  if (!sideways(view)) return [];
  const left = textLeft(view) + 0.5;
  const right = textRight(view) - 0.5;
  return longLines(view).map((line) => {
    const y = rowY(view, line.getBoundingClientRect());
    return [markAtX(line, left, y), markAtX(line, right, y)];
  });
}

function gapNearSides(view, columns) {
  if (!sideways(view)) return false;
  const reach = (columns * charWidth(view)) / 2;
  const from = textLeft(view) - reach;
  const to = textRight(view) + reach;
  return longLines(view).some((line) => inViewRows(view, line) && pieces(line).some((piece) => {
    if (!piece.hasAttribute("data-gap")) return false;
    const b = piece.getBoundingClientRect();
    return b.right > from && b.left < to;
  }));
}

function pointVisible(view) {
  const b = pointExtent(view);
  return b !== null && b.top + b.height > view.scrollTop + 0.5 && b.top < view.scrollTop + view.clientHeight - 0.5;
}

// A probe costs a layout, and a mouse event would make one each, so an
// element's cells are measured again only after a screen, a resize or a
// font that loads.
let cellSizes = new WeakMap();

function forgetCells() {
  cellSizes = new WeakMap();
}

function cellSize(element) {
  let cell = cellSizes.get(element);
  if (cell === undefined) {
    const probe = document.createElement("span");
    probe.textContent = "0";
    probe.style.cssText = "position: absolute; visibility: hidden;";
    element.append(probe);
    const height = probe.getBoundingClientRect().height || lineHeight(element);
    probe.remove();
    cell = { width: charWidth(element), height };
    cellSizes.set(element, cell);
  }
  return cell;
}

// An element marked data-body-cells, such as a terminal's screen, has
// cells of its own font; other views count cells of the view's.
function cells(view) {
  const marked = view.querySelector("[data-body-cells]");
  const cell = cellSize(marked && own(view, marked) ? marked : view);
  const { width, height } = contentSize(view);
  return { columns: Math.max(1, Math.floor(width / cell.width)), rows: Math.max(1, Math.floor(height / cell.height)) };
}

// What the page wants drawn beyond each edge, in the counts the spacers
// are sized by: as many lines as fill the screens it keeps, at the
// height its drawn lines beyond that edge take on average and never
// less than one row, or as many characters as fill those rows,
// whichever the text reaches first. A row holds no more characters than
// fit it, so the characters fill the screens however the lines wrap;
// and beyond each side of a line that does not wrap, the screens'
// columns. The lines beyond an edge are those a new run continues; an
// average over the whole run asks for too few where shorter lines lie
// beyond an edge, and the page then finds itself short of the run it
// asked for and reports again for nothing.
function wanted(view, st) {
  const count = drawnScreens(view);
  const { columns } = st.reportedCells ?? cells(view);
  const lh = lineHeight(view);
  const top = contentTop(view);
  const bottom = top + view.clientHeight;
  const ends = viewItems(view)
    .filter((item) => !item.hasAttribute("data-segment") || item.nextElementSibling?.getAttribute("data-line") !== item.getAttribute("data-line"))
    .map(box).filter((b) => b !== null);
  const perLine = (beyond) => {
    const all = beyond.length > 0 ? beyond : ends;
    if (all.length === 0) return lh;
    const from = Math.min(...all.map((b) => b.top));
    const to = Math.max(...all.map((b) => b.bottom));
    return Math.max(lh, (to - from) / all.length);
  };
  const want = count * view.clientHeight;
  const rows = Math.ceil(want / lh) + 1;
  return {
    aboveLines: Math.ceil(want / perLine(ends.filter((b) => b.bottom <= top))) + 1,
    aboveChars: rows * columns,
    belowLines: Math.ceil(want / perLine(ends.filter((b) => b.top >= bottom))) + 1,
    belowChars: rows * columns,
    side: Math.max(1, Math.ceil(count * columns)),
  };
}

// Counted from the items holding the rows a report names, as Tuna counts
// when it draws a run, so a run drawn for an ask always holds it.
function drawnCounts(view, st) {
  const map = mapOf(view, st);
  const all = map.parts;
  const line = (part) => number(part.element, "data-line") ?? 0;
  const m = margin(view);
  const first = partAtY(map, view.scrollTop + m + 1);
  const last = partAtY(map, view.scrollTop + view.clientHeight - m - 1);
  // A long line's segments are one item, as Tuna counts items.
  const items = (from, to) => {
    let n = 0;
    for (let i = from; i < to; i++) {
      const e = all[i].element;
      const prev = i > from ? all[i - 1].element : null;
      if (!(e.hasAttribute("data-segment") && prev !== null && prev.hasAttribute("data-segment")
            && prev.getAttribute("data-line") === e.getAttribute("data-line"))) n++;
    }
    return n;
  };
  const none = { lines: -1, chars: -1, items: -1 };
  const unbounded = { lines: Infinity, chars: Infinity, items: Infinity };
  const startPart = all[0]?.element.getAttribute("data-spacer") === "above" ? all[1] : null;
  const endPart = all.length > 0 && all[all.length - 1].spacer && all[all.length - 1].element.getAttribute("data-spacer") === "below"
    ? all[all.length - 1] : null;
  let above = unbounded;
  if (!view.hasAttribute("data-run-at-start") && startPart) {
    const at = all[first];
    above = at === undefined || at.spacer ? none
      : { lines: line(at) - line(startPart), chars: at.before - startPart.before, items: items(1, first) };
  }
  let below = unbounded;
  if (!view.hasAttribute("data-run-at-end") && endPart) {
    const at = all[last];
    const next = all[last + 1];
    below = at === undefined || at.spacer || next === undefined ? none
      : { lines: line(endPart) - line(next), chars: endPart.before - next.before, items: items(last + 1, all.length - 1) };
  }
  return { above, below };
}

// A run answers the ask it was drawn for by construction, so a run that
// holds less than half of it beyond an edge is short only because the
// rows in view moved; the ask is not made again from the new run, or
// two runs whose lines differ in height could each ask for the other
// forever.
function shortOf(view, counts, ask) {
  const lacks = (c, lines, chars) => c.lines < lines / 2 && c.items < lines / 2 && (sideways(view) || c.chars < chars / 2);
  return lacks(counts.above, ask.aboveLines, ask.aboveChars) || lacks(counts.below, ask.belowLines, ask.belowChars);
}

// Where the top edge lies in a spacer, the top is the place its counts
// put there, so every scroll offset names a place in the text; while the
// thumb is dragged, the place at its share.
function topPlace(view, st) {
  const top = contentTop(view);
  const spacer = spacerAt(view, top);
  if (spacer !== null && st.drag?.vertical) return { mark: spacerMark(view, spacer, st.drag.target), fraction: 0, spacer: true };
  if (spacer !== null) return { mark: spacerMarkAtY(spacer, top), fraction: 0, spacer: true };
  const found = topItem(view);
  return found
    ? { mark: mark(found.item), fraction: Math.min(1, Math.max(0, (top - found.box.top) / Math.max(1, found.box.height))), spacer: false }
    : { mark: null, fraction: 0, spacer: false };
}

function measure(view, st, settled, reask) {
  const at = topPlace(view, st);
  const { start, end } = rowsInView(view);
  const { columns, rows } = st.reportedCells ?? cells(view);
  const { left, past } = columnOf(view);
  return {
    type: "scroll",
    view: number(view, "data-view"),
    placement: st.placed,
    version: number(view, "data-version"),
    top: at.mark,
    spacer: at.spacer,
    fraction: at.fraction,
    left,
    past,
    sides: sidesOf(view),
    start,
    end,
    atStart: view.hasAttribute("data-run-at-start") && view.scrollTop <= 0.5,
    atEnd: atEnd(view),
    columns,
    rows,
    pointVisible: pointVisible(view),
    wanted: reask || st.ask === null ? wanted(view, st) : st.ask,
    hand: st.moving || settled,
    settled,
    edge: st.edge,
  };
}

// One report is on its way per view until a screen brings its number
// back: over a slow link, reports sent faster than screens return would
// queue up and describe the past. Each report makes Tuna draw its client
// again, so one that tells nothing new is not sent.
function reportIfDue(view, st, settled) {
  if (st.sent === null) decideReport(view, st, settled);
  else if (settled) st.owed = "settled";
}

function decideReport(view, st, settled) {
  if (!view.isConnected || view.clientHeight === 0) return;
  const short = st.ask !== null && shortOf(view, drawnCounts(view, st), st.ask);
  // A view's size is the cells of text that fit it: in WebKit a view in
  // a flex column, sized from content of hundreds of thousands of px,
  // is 1/64 px taller or shorter with each run, and its whole px flip.
  const fit = st.currentCells ?? (st.currentCells = cells(view));
  const resized = st.reportedCells?.columns !== fit.columns || st.reportedCells?.rows !== fit.rows;
  const gapNear = gapNearSides(view, fit.columns * drawnScreens(view));
  const lead = view.hasAttribute("data-lead");
  // The other devices keep point at the edge following it brought it to.
  const turned = lead && following(view, st) && st.edge !== st.edgeReported;
  // Point shown at the last check that left the view by a resize, a
  // font, a screen or an edit, not by the hand, is followed, as Emacs's
  // redisplay keeps point in view; the hand's scroll and a placement
  // leave point where they put it.
  const visible = pointVisible(view);
  const lost = lead && st.pointShown && !visible && !st.moving && !following(view, st);
  st.pointShown = visible;
  if (!(st.owed || short || gapNear || resized || turned || settled || lost)) return;
  st.reportedCells = fit;
  // The page asks anew only with the hand, a size or a placement.
  const reask = Boolean(st.owed) || resized || settled || st.moving;
  const report = { ...measure(view, st, settled || st.owed === "settled", reask), lost };
  const text = JSON.stringify(report);
  if (text === st.last) return;
  st.last = text;
  st.owed = false;
  st.edgeReported = st.edge;
  st.ask = report.wanted;
  send(numbered(view, st, report));
}

// A report whose top lies in a spacer names a place there; the page
// keeps where it named it, to put the place there once it is drawn.
function numbered(view, st, report) {
  st.sent = ++reports;
  if (report.spacer) {
    const chars = st.drag?.vertical ? st.drag.target : charsAtY(mapOf(view, st), view.scrollTop);
    st.named = { report: st.sent, hand: st.handMoved, chars };
  }
  return { ...report, report: st.sent };
}

function stateOf(view) {
  let st = states.get(view);
  if (st === undefined) {
    st = newState();
    states.set(view, st);
    sizes.observe(view);
    afterChange(view, st, true);
  }
  return st;
}

function eachView(proc) {
  for (const view of document.querySelectorAll(".view[data-placement]")) proc(view);
}

// Datastar dispatches each event of its stream as a datastar-fetch event
// on the document and patches in its own listener there: a capturing
// listener on the window runs before the patch, and one on the document
// added after Datastar's module runs after it, before the browser paints.
window.addEventListener("datastar-fetch", (event) => {
  if (event.detail.type !== "datastar-patch-elements") return;
  eachView((view) => {
    const st = states.get(view);
    if (st !== undefined) capture(view, st);
  });
}, { capture: true });

document.addEventListener("datastar-fetch", (event) => {
  if (event.detail.type !== "datastar-patch-elements") return;
  screens++;
  forgetCells();
  eachView((view) => {
    const st = states.get(view);
    if (st === undefined) stateOf(view); else afterChange(view, st, false);
  });
});

// Items change size without an edit, as an image decodes or fonts load,
// and the browser's anchoring, which would hold the view still, is off.
const sizes = new ResizeObserver((entries) => {
  forgetCells();
  const changed = new Set();
  for (const entry of entries) {
    const view = states.has(entry.target) ? entry.target : entry.target.parentElement;
    if (!entry.target.isConnected || !states.has(view)) {
      sizes.unobserve(entry.target);
      continue;
    }
    changed.add(view);
  }
  for (const view of changed) {
    const st = states.get(view);
    st.currentCells = null;
    afterChange(view, st, false);
  }
});

// A line that does not wrap is as wide as the view whatever its text,
// so a font that loads changes no size the observer sees; its glyphs'
// widths move the text under the left edge.
document.fonts.addEventListener("loadingdone", () => {
  forgetCells();
  eachView((view) => {
    const st = states.get(view);
    if (st === undefined) return;
    st.currentCells = null;
    afterChange(view, st, false);
  });
});

document.addEventListener("scroll", (event) => {
  const view = event.target;
  if (!(view instanceof Element) || !view.hasAttribute("data-placement")) return;
  const st = states.get(view);
  if (st === undefined) return;
  if (byHand(view)) {
    handScrolled(view, st);
    st.scrolling = true;
  }
  capture(view, st);
  drawBars(view, st);
  reportIfDue(view, st, false);
}, { capture: true, passive: true });

function handScrolled(view, st) {
  if (!st.moving) st.owed ||= true;
  st.pointShown = false;
  st.hand = true;
  st.moving = true;
  st.edge = "top";
  forgetWrite(view);
}

// Only a scroll the hand made and that came to rest moves the other
// clients, so a fling moves them once, where it ends. A scroll made of
// steps, as a wheel's notches are, ends at each step, and each end is a
// place the view stood still.
document.addEventListener("scrollend", (event) => {
  const view = event.target;
  if (!(view instanceof Element) || !view.hasAttribute("data-placement")) return;
  const st = states.get(view);
  if (st === undefined) return;
  const owned = handOwns(st);
  st.scrolling = false;
  // The spacer above goes back to its guess, and the offset takes what
  // the scroll left in it, in one write.
  if (owned) afterChange(view, st, false);
  showBars(view, st);
  if (!st.moving || st.drag !== null) return;
  st.moving = false;
  reportIfDue(view, st, true);
}, { capture: true, passive: true });

// A key or a press may make the view element anew, as a tab switch
// does, and the new element is placed where the last report left it, so
// a hand's scroll not yet at rest is reported at rest first, even past
// the report in flight, whose screen the element may not live to see.
function restBeforeInput() {
  eachView((view) => {
    const st = states.get(view);
    if (st === undefined || !st.moving || st.drag !== null) return;
    st.moving = false;
    decideReport(view, st, true);
  });
}

document.addEventListener("keydown", restBeforeInput, { capture: true });
document.addEventListener("pointerdown", restBeforeInput, { capture: true, passive: true });

function barOf(view, axis) {
  return view.querySelector(`:scope > .view-bars > [data-scroll-bar="${axis}"]`);
}

function setStyle(element, name, value) {
  if (element.style.getPropertyValue(name) !== value) element.style.setProperty(name, value);
}

function leastSize(bar, vertical) {
  const thumb = bar.firstElementChild;
  if (thumb === null) return 0;
  const style = getComputedStyle(thumb);
  return parseFloat(vertical ? style.minBlockSize : style.minInlineSize) || 0;
}

// Only the free length of the bar is the text's, so both ends of the
// text are under the thumb at both ends of the bar.
function thumbFor(track, least, { start, visible, whole }) {
  const size = Math.min(track, Math.max(least, whole > 0 ? (track * visible) / whole : track));
  const at = whole > visible ? (track - size) * Math.min(1, Math.max(0, start / (whole - visible))) : 0;
  return { at, size };
}

function shareStart(at, free, { visible, whole }) {
  return free > 0 ? Math.min(1, at / free) * Math.max(0, whole - visible) : 0;
}

function verticalShare(view, st) {
  const map = mapOf(view, st);
  const start = charsAtY(map, view.scrollTop);
  const end = charsAtY(map, view.scrollTop + view.clientHeight);
  return { start, visible: Math.max(0, end - start), whole: map.total };
}

// A line's stretches on the screen, each with the characters before it
// on the line and its own: a long line's segments and gaps, or a short
// line's text. A place inside one is the same share of its characters
// as of its width.
function lineSpans(line, chars) {
  const all = pieces(line);
  if (all.length === 0) {
    const b = textBox(line);
    return [{ left: b.left, right: b.right, from: 0, chars }];
  }
  let from = 0;
  return all.map((piece) => {
    const b = piece.getBoundingClientRect();
    const n = number(piece, "data-chars") ?? 0;
    const span = { left: b.left, right: b.right, from, chars: n };
    from += n;
    return span;
  });
}

function spansChars(spans) {
  const last = spans[spans.length - 1];
  return last.from + last.chars;
}

function charsAtX(spans, x) {
  for (const s of spans) {
    if (x < s.left) return s.from;
    if (x < s.right) return s.from + ((x - s.left) / Math.max(1, s.right - s.left)) * s.chars;
  }
  return spansChars(spans);
}

function xAtChars(spans, k) {
  for (const s of spans) {
    if (k < s.from + s.chars || s === spans[spans.length - 1]) {
      return s.left + (s.chars > 0 ? Math.min(1, Math.max(0, (k - s.from) / s.chars)) : 0) * (s.right - s.left);
    }
  }
  return 0;
}

// The line in view with the most characters, as Emacs's horizontal bar
// spans the widest line in the window.
function widestLine(view, st) {
  const shown = new Set(ownLines(view).filter((line) => inViewRows(view, line)));
  let best = null;
  for (const part of mapOf(view, st).parts) {
    if (shown.has(part.element) && (best === null || part.chars > best.chars)) best = part;
  }
  return best === null ? null : { line: best.element, spans: lineSpans(best.element, best.chars) };
}

function lineChars(view, st, line) {
  return mapOf(view, st).parts.find((part) => part.element === line)?.chars ?? 0;
}

function horizontalShare(view, st, line) {
  const found = line ? { line, spans: lineSpans(line, lineChars(view, st, line)) } : widestLine(view, st);
  if (found === null) return { start: 0, visible: 1, whole: 1, line: null };
  const start = charsAtX(found.spans, textLeft(view));
  const end = charsAtX(found.spans, textRight(view));
  return { start, visible: Math.max(0, end - start), whole: spansChars(found.spans), line: found.line, spans: found.spans };
}

// The thumbs show shares of the text's characters, as Emacs's vertical
// one does, since the browser's bars measure pixels and the pixels of
// text never drawn are guesses: the vertical one of the view's text, the
// horizontal one of the widest line in view.
function drawBars(view, st) {
  const vertical = barOf(view, "vertical");
  const horizontal = barOf(view, "horizontal");
  if (vertical === null && horizontal === null) return;
  const r = view.getBoundingClientRect();
  const b = (vertical ?? horizontal).parentElement.getBoundingClientRect();
  const x = r.left + view.clientLeft - b.left;
  const y = r.top + view.clientTop - b.top;
  const thumb = (bar, isVertical, track) => {
    const d = st.drag;
    if (d !== null && d.vertical === isVertical) return { at: d.at, size: d.size };
    return thumbFor(track, leastSize(bar, isVertical), isVertical ? verticalShare(view, st) : horizontalShare(view, st, null));
  };
  if (vertical !== null) {
    const fits = view.scrollHeight <= view.clientHeight + 0.5;
    drawBar(vertical, x + view.clientWidth, y, view.clientHeight, fits ? null : thumb(vertical, true, view.clientHeight));
  }
  if (horizontal !== null) {
    const fits = view.scrollWidth <= view.clientWidth + 0.5;
    drawBar(horizontal, x, y + view.clientHeight, view.clientWidth, fits ? null : thumb(horizontal, false, view.clientWidth));
  }
  showBars(view, st);
}

function drawBar(bar, x, y, track, thumb) {
  setStyle(bar, "--views-bar-x", px(x));
  setStyle(bar, "--views-bar-y", px(y));
  setStyle(bar, "--views-bar-length", px(track));
  bar.toggleAttribute("data-fits", thumb === null);
  if (thumb === null) return;
  setStyle(bar, "--views-thumb-start", px(thumb.at));
  setStyle(bar, "--views-thumb-size", px(thumb.size));
}

function showBars(view, st) {
  const bars = view.querySelector(":scope > .view-bars");
  if (bars === null) return;
  const shown = st.drag !== null || st.scrolling || pointedView === view ? st.input : null;
  if (shown === null) bars.removeAttribute("data-shown");
  else if (bars.getAttribute("data-shown") !== shown) bars.setAttribute("data-shown", shown);
}

// A touch screen keeps :hover on the element last tapped, so the bars
// would stay shown after a tap; a mouse's own pointer events say when it
// is over a view.
let pointedView = null;

function pointAt(view) {
  const st = view && states.get(view);
  if (!st) return;
  st.input = "mouse";
  showBars(view, st);
}

document.addEventListener("pointermove", (event) => {
  if (event.pointerType !== "mouse") return;
  const view = event.target instanceof Element ? event.target.closest(".view[data-placement]") : null;
  if (view === pointedView) return;
  const left = pointedView;
  pointedView = view;
  const st = left && states.get(left);
  if (st) showBars(left, st);
  pointAt(view);
}, { capture: true, passive: true });

document.addEventListener("pointerout", (event) => {
  if (event.pointerType !== "mouse" || event.relatedTarget !== null) return;
  const left = pointedView;
  pointedView = null;
  const st = left && states.get(left);
  if (st) showBars(left, st);
}, { capture: true, passive: true });

document.addEventListener("pointerdown", (event) => {
  const view = event.target instanceof Element ? event.target.closest(".view[data-placement]") : null;
  const st = view && states.get(view);
  if (st) st.input = event.pointerType === "touch" ? "touch" : "mouse";
}, { capture: true, passive: true });

// Dragging a thumb is a hand scroll in text: the thumb stays under the
// pointer, and the view goes to the place at the thumb's share, which,
// where it is not drawn, the page names to Tuna as it names any place
// in a spacer.
let dragged = null;

document.addEventListener("pointerdown", (event) => {
  if (event.button !== 0 || dragged !== null || !(event.target instanceof Element)) return;
  const thumb = event.target.closest(".view-thumb");
  const bar = thumb?.parentElement;
  const view = bar?.closest("[data-view]");
  const st = view ? states.get(view) : undefined;
  if (st === undefined) return;
  event.preventDefault();
  const vertical = bar.getAttribute("data-scroll-bar") === "vertical";
  const share = vertical ? verticalShare(view, st) : horizontalShare(view, st, null);
  const t = thumb.getBoundingClientRect();
  const b = bar.getBoundingClientRect();
  const size = vertical ? t.height : t.width;
  st.drag = {
    vertical,
    at: vertical ? t.top - b.top : t.left - b.left,
    grab: vertical ? event.clientY - t.top : event.clientX - t.left,
    size,
    free: Math.max(0, (vertical ? view.clientHeight : view.clientWidth) - size),
    visible: share.visible,
    whole: share.whole,
    target: share.start,
    line: vertical ? null : share.line?.id ?? null,
    released: false,
    drawn: true,
  };
  dragged = { view, st, bar, pointer: event.pointerId };
  bar.setAttribute("data-held", "");
  showBars(view, st);
}, true);

document.addEventListener("pointermove", (event) => {
  if (dragged === null || event.pointerId !== dragged.pointer) return;
  const { view, st, bar } = dragged;
  const d = st.drag;
  const b = bar.getBoundingClientRect();
  d.at = Math.min(d.free, Math.max(0, (d.vertical ? event.clientY - b.top : event.clientX - b.left) - d.grab));
  d.target = shareStart(d.at, d.free, d);
  handScrolled(view, st);
  dragTo(view, st);
  capture(view, st);
  drawBars(view, st);
  reportIfDue(view, st, false);
}, { capture: true, passive: true });

function released(event) {
  if (dragged === null || event.pointerId !== dragged.pointer) return;
  const { view, st } = dragged;
  dragged = null;
  st.drag.released = true;
  if (st.drag.drawn) dragEnded(view, st);
}

document.addEventListener("pointerup", released, true);
document.addEventListener("pointercancel", released, true);

// The thumb's size follows the characters in view at the place it
// names, so two places can each give the other's thumb; the search for
// the place stops after a few rounds.
const dragRounds = 4;

// Where the place is not drawn yet, the view waits in the spacer for
// the screen that draws it. Where it is drawn, the characters in view
// there decide the thumb's size and free length, so the place is found
// again from them until the thumb drawn from it is where the hand left
// it.
function dragTo(view, st) {
  const d = st.drag;
  if (!d.vertical) {
    dragSideways(view, st);
    return;
  }
  const map = mapOf(view, st);
  const bar = barOf(view, "vertical");
  for (let i = 0; i < dragRounds; i++) {
    const { top, part } = yAtChars(map, d.target);
    d.drawn = part !== null && !part.spacer;
    if (Math.abs(view.scrollTop - top) > 0.5) setScroll(view, top);
    if (!d.drawn || bar === null) return;
    const share = verticalShare(view, st);
    const { size } = thumbFor(view.clientHeight, leastSize(bar, true), share);
    const target = shareStart(d.at, view.clientHeight - size, share);
    if (Math.abs(target - d.target) < 0.5) return;
    d.target = target;
  }
}

// Sideways the place is the character at the thumb's share of the line
// the drag began on, which a gap stands for where it is not drawn.
function dragSideways(view, st) {
  const d = st.drag;
  const line = d.line === null ? null : document.getElementById(d.line);
  if (line === null || !own(view, line)) return;
  for (let i = 0; i < dragRounds; i++) {
    const share = horizontalShare(view, st, line);
    const shift = xAtChars(share.spans, d.target) - textLeft(view);
    if (Math.abs(shift) > 0.5) setScroll(view, view.scrollTop, view.scrollLeft + shift);
    const bar = barOf(view, "horizontal");
    if (bar === null) return;
    const { size } = thumbFor(view.clientWidth, leastSize(bar, false), share);
    const target = shareStart(d.at, view.clientWidth - size, share);
    if (Math.abs(target - d.target) < 0.5) return;
    d.target = target;
  }
}

function dragEnded(view, st) {
  barOf(view, st.drag.vertical ? "vertical" : "horizontal")?.removeAttribute("data-held");
  st.drag = null;
  st.moving = false;
  drawBars(view, st);
  reportIfDue(view, st, true);
}

// A press on a bar off its thumb names the place at its share of the
// bar, as Emacs's scroll bar event carries its portion of the whole.
function barPlace(view, bar, x, y) {
  const st = states.get(view);
  const b = bar.getBoundingClientRect();
  if (bar.getAttribute("data-scroll-bar") === "horizontal") {
    const share = Math.min(1, Math.max(0, (x - b.left) / Math.max(1, b.width)));
    const found = st ? horizontalShare(view, st, null) : null;
    return found === null || found.line === null ? null : sidePlace(found.line, share * found.whole, found.spans);
  }
  const map = st ? mapOf(view, st) : textMap(view);
  const k = Math.min(1, Math.max(0, (y - b.top) / Math.max(1, b.height))) * map.total;
  const { part } = yAtChars(map, k);
  if (part === null) return null;
  if (part.spacer) return markInto(part.element, k - part.before);
  return { ...mark(part.element), chars: Math.max(0, Math.floor(k - part.before)) };
}

// The place K characters into LINE: a long line names it in its
// segments and gaps, a short one by its share of the line, since the
// place may lie outside the view, where the browser names no caret.
function sidePlace(line, k, spans) {
  if (pieces(line).length > 0) {
    const b = line.getBoundingClientRect();
    return markAtX(line, xAtChars(spans, k), b.top + b.height / 2);
  }
  return { ...mark(line), chars: Math.max(0, Math.min(Math.round(k), spansChars(spans) - 1)) };
}

// Where a press on a scroll bar lies against the thumb as drawn, named
// as Emacs's scroll bar events name the parts: a command pages toward
// what the user saw.
function barPart(bar, x, y) {
  const t = bar.firstElementChild.getBoundingClientRect();
  if (bar.getAttribute("data-scroll-bar") === "vertical") {
    return y < t.top ? "above-handle" : y >= t.bottom ? "below-handle" : null;
  }
  return x < t.left ? "before-handle" : x >= t.right ? "after-handle" : null;
}

function partField(bar, x, y) {
  const part = bar === null ? null : barPart(bar, x, y);
  return part === null ? {} : { part };
}

// A press held on a scroll bar off its thumb presses again, as GTK's
// trough repeats its step: after 500 ms, then every 250 ms, until the
// thumb as drawn covers the pointer. Each waits for a screen since the
// last, so presses do not queue behind a slow answer and page past the
// thumb. A view element made anew is still the view the press is on.
function repeatPress(p, place, fields) {
  let seen = screens;
  const again = (ms) => {
    p.repeat = setTimeout(() => {
      if (press !== p) return;
      if (!p.bar.isConnected) {
        const view = document.getElementById(p.view.id);
        const bar = view && barOf(view, p.bar.getAttribute("data-scroll-bar"));
        if (!bar) return;
        p.view = view;
        p.bar = bar;
      }
      const part = partField(p.bar, p.x, p.y);
      if (part.part === undefined) return;
      if (screens !== seen) {
        seen = screens;
        sendMouse(p.view, "down", place, { ...fields, ...part });
      }
      again(250);
    }, ms);
  };
  again(500);
}

// C-v's step: the view's height less the context lines, as Emacs
// scrolls by the window's height less next-screen-context-lines. A page
// with less drawn past its edge than a step asks for more and is asked
// again, and then steps as far as it has drawn. The step moves the view
// as the hand does, and the answer is the report of its rest, which the
// page also sends as a report: a command quit before it took the answer
// leaves the report to tell Tuna where the view went, and one that took
// it finds the report changes nothing.
// Sideways, as C-x < scrolls, the step is the view's width less the
// context columns, in the cells the page shows, as Emacs counts columns;
// what lies past it is drawn, or a gap whose place the report names.
// BY, rows or columns, makes the step that many.
define("views-page", ({ view: id, forward, context, again, sideways: across, by }) => {
  const view = document.getElementById(`view-${id}`);
  if (view === null || number(view, "data-view") !== id) return null;
  const st = stateOf(view);
  if (across) {
    const cw = charWidth(view);
    const step = by === null ? Math.max(cw, contentSize(view).width - context * cw) : by * cw;
    setScroll(view, view.scrollTop, forward ? view.scrollLeft + step : Math.max(0, view.scrollLeft - step));
    return pageReport(view, st);
  }
  const lh = lineHeight(view);
  const step = by === null ? Math.max(lh, view.clientHeight - context * lh) : by * lh;
  const all = viewItems(view);
  const first = all.length > 0 ? box(all[0]) : null;
  const last = all.length > 0 ? box(all[all.length - 1]) : null;
  const top = contentTop(view);
  const drawnTop = first ? first.top - top + view.scrollTop : 0;
  const drawnBottom = last ? last.bottom - top + view.scrollTop : 0;
  const most = Math.min(view.scrollHeight - view.clientHeight, Math.max(0, drawnBottom - view.clientHeight));
  const least = Math.max(0, drawnTop);
  const atStart = view.hasAttribute("data-run-at-start");
  const atEndOfRun = view.hasAttribute("data-run-at-end");
  if (forward ? view.scrollTop >= most - 0.5 && atEndOfRun : view.scrollTop <= least + 0.5 && atStart) {
    return { limit: true };
  }
  if (!again && (forward ? view.scrollTop + step > most + 0.5 && !atEndOfRun : view.scrollTop - step < least - 0.5 && !atStart)) {
    return { more: true };
  }
  setScroll(view, forward ? Math.min(most, view.scrollTop + step) : Math.max(least, view.scrollTop - step));
  return pageReport(view, st);
});

function pageReport(view, st) {
  st.pointShown = false;
  st.hand = true;
  st.edge = "top";
  capture(view, st);
  const report = numbered(view, st, measure(view, st, true, true));
  st.ask = report.wanted;
  send(report);
  return { report };
}

// The start of a row wholly in view: ROW from 0 at the top, or from -1
// at the bottom; null, the middle one. A row past the last is the last,
// as move-to-window-line stops at the window's last line.
define("views-row", ({ view: id, row }) => {
  const view = document.getElementById(`view-${id}`);
  if (view === null || number(view, "data-view") !== id) return null;
  const rows = rowsShown(view);
  if (rows.length === 0) return null;
  const index = row === null ? Math.floor(rows.length / 2) : row < 0 ? rows.length + row : row;
  return { version: number(view, "data-version"), at: rows[Math.min(rows.length - 1, Math.max(0, index))].at };
});

// A strip comes to rest when no scroll has come for restMs, not at
// scrollend: its rest moves the focus in the other clients, and a
// scroll made of steps, as a wheel's notches are, ends at each step.
const restMs = 200;

const scrollers = new WeakMap();
const scrollerResting = new WeakMap();

// What a browser rounds an edge to.
const itemTolerance = 1;

function rowAxis(scroller) {
  return scroller.getAttribute("data-axis") !== "column";
}

function scrollPosition(scroller) {
  return rowAxis(scroller) ? scroller.scrollLeft : scroller.scrollTop;
}

function setScrollPosition(scroller, position) {
  if (rowAxis(scroller)) scroller.scrollLeft = position; else scroller.scrollTop = position;
}

function scrollerLength(scroller) {
  return rowAxis(scroller) ? scroller.clientWidth : scroller.clientHeight;
}

function scrollerItems(scroller) {
  return Array.from(scroller.children).filter((child) => child.hasAttribute("data-item"));
}

function itemNamed(scroller, name) {
  return name === null ? undefined : scrollerItems(scroller).find((item) => number(item, "data-item") === name);
}

function edges(scroller, item) {
  const outer = scroller.getBoundingClientRect();
  const b = item.getBoundingClientRect();
  const at = scrollPosition(scroller);
  return rowAxis(scroller)
    ? [b.left - outer.left - scroller.clientLeft + at, b.right - outer.left - scroller.clientLeft + at]
    : [b.top - outer.top - scroller.clientTop + at, b.bottom - outer.top - scroller.clientTop + at];
}

function wholly(scroller, item, at) {
  const [start, end] = edges(scroller, item);
  return start >= at - itemTolerance && end <= at + scrollerLength(scroller) + itemTolerance;
}

// An item longer than the scroller shows its start, as Niri shows a
// column wider than the screen.
function nearest(scroller, item, at) {
  const [start, end] = edges(scroller, item);
  const length = scrollerLength(scroller);
  if (start >= at - itemTolerance && end <= at + length + itemTolerance) return at;
  if (start < at || end - start > length) return start;
  return end - length;
}

function itemsInView(scroller) {
  const at = scrollPosition(scroller);
  const length = scrollerLength(scroller);
  return scrollerItems(scroller)
    .filter((item) => {
      const [start, end] = edges(scroller, item);
      return end > at + itemTolerance && start < at + length - itemTolerance;
    })
    .map((item) => number(item, "data-item"));
}

function whollyInView(scroller) {
  const at = scrollPosition(scroller);
  return scrollerItems(scroller)
    .filter((item) => wholly(scroller, item, at))
    .map((item) => number(item, "data-item"));
}

function placeScroller(scroller, placement) {
  const item = itemNamed(scroller, number(scroller, "data-place-item"));
  const focus = itemNamed(scroller, number(scroller, "data-place-focus"));
  let at = scrollPosition(scroller);
  if (item !== undefined) {
    const [start, end] = edges(scroller, item);
    const length = scrollerLength(scroller);
    switch (scroller.getAttribute("data-place-align")) {
      case "start": at = start; break;
      case "end": at = end - length; break;
      case "center": at = (start + end) / 2 - length / 2; break;
      default: at = nearest(scroller, item, at);
    }
  }
  if (focus !== undefined) at = nearest(scroller, focus, at);
  setScrollPosition(scroller, at);
  scrollers.set(scroller, {
    placed: placement, at: scrollPosition(scroller), gesture: false,
    sent: null, owed: true, reported: null,
  });
  checkScroller(scroller, false);
}

function restingPlace(scroller, state) {
  const at = scrollPosition(scroller);
  const length = scrollerLength(scroller);
  const all = scrollerItems(scroller);
  let best = null;
  for (const item of all) {
    const [start, end] = edges(scroller, item);
    const candidates = getComputedStyle(item).scrollSnapAlign.includes("center")
      ? [["center", (start + end) / 2 - at - length / 2]]
      : [["start", start - at], ["end", end - at - length]];
    for (const [align, distance] of candidates) {
      if (best === null || Math.abs(distance) < Math.abs(best.distance)) best = { item, align, distance };
    }
  }
  if (best === null) return null;
  let index = all.indexOf(best.item);
  // The furthest item wholly in view in the direction the hand moved, as
  // Niri's view_offset_gesture_end chooses.
  const step = at >= state.at ? 1 : -1;
  if (!wholly(scroller, all[index], at)) {
    const next = all[index + step];
    if (next !== undefined && wholly(scroller, next, at)) index += step;
  }
  while (all[index + step] !== undefined && wholly(scroller, all[index + step], at)) index += step;
  return {
    item: number(best.item, "data-item"),
    align: best.align,
    focus: number(all[index], "data-item"),
  };
}

// As for a view, one report is on its way per scroller until a screen
// brings its number back.
function checkScroller(scroller, resting) {
  const state = scrollers.get(scroller);
  if (state === undefined) return;
  if (state.sent !== null) {
    if (resting) state.owed = "rest";
    else if (state.owed !== "rest") state.owed = true;
    return;
  }
  if (!scroller.isConnected || scrollerLength(scroller) === 0) return;
  if (number(scroller, "data-placement") !== state.placed) return;
  const id = number(scroller, "data-scroller");
  if (id === null) return;
  const shown = itemsInView(scroller);
  const whole = whollyInView(scroller);
  const key = `${shown.join(" ")} | ${whole.join(" ")}`;
  const moved = Math.abs(scrollPosition(scroller) - state.at) > itemTolerance;
  if (resting && !moved) state.gesture = false;
  const settled = (resting || state.owed === "rest") && state.gesture && moved;
  if (!settled && !state.owed && key === state.reported) return;
  const report = { type: "scroller", scroller: id, placement: state.placed, items: shown, whole, settled };
  if (settled) {
    const found = restingPlace(scroller, state);
    if (found === null) return;
    Object.assign(report, found);
    state.at = scrollPosition(scroller);
    state.gesture = false;
  }
  state.owed = false;
  state.reported = key;
  state.sent = ++reports;
  send({ ...report, report: state.sent });
}

function scrollersArrived() {
  for (const scroller of document.querySelectorAll("[data-scroller][data-placement]")) {
    const placement = number(scroller, "data-placement");
    const state = scrollers.get(scroller);
    if (state === undefined || state.placed !== placement) {
      placeScroller(scroller, placement);
    } else if (state.sent !== null && number(scroller, "data-reported") === state.sent) {
      state.sent = null;
      checkScroller(scroller, false);
    }
  }
}

// Only a scroll the hand began moves the focus or, at rest, the view in
// the other clients: a placement, or a browser holding its scroll anchor
// or a snap position as the page changes, scrolls too. A hand's scroll
// starts within handMs of its wheel, touch or press.
const handMs = 500;
let handAt = -Infinity;

for (const type of ["wheel", "touchstart", "pointerdown"]) {
  document.addEventListener(type, () => { handAt = performance.now(); }, { capture: true, passive: true });
}

document.addEventListener("scroll", (event) => {
  const scroller = event.target;
  if (!(scroller instanceof Element) || !scroller.hasAttribute("data-scroller")) return;
  const state = scrollers.get(scroller);
  if (state !== undefined && performance.now() - handAt < handMs) state.gesture = true;
  checkScroller(scroller, false);
  clearTimeout(scrollerResting.get(scroller));
  scrollerResting.set(scroller, setTimeout(() => checkScroller(scroller, true), restMs));
}, { capture: true, passive: true });

let scheduled = false;
new MutationObserver((records) => {
  wheelMarksArrived(records);
  if (scheduled) return;
  scheduled = true;
  requestAnimationFrame(() => {
    scheduled = false;
    scrollersArrived();
  });
}).observe(document.documentElement, {
  subtree: true,
  childList: true,
  attributes: true,
  attributeFilter: ["data-placement", "data-reported", "data-wheel"],
});

const dragThreshold = 3;
let press = null;

function modifierNames(event) {
  const names = [];
  if (event.ctrlKey) names.push("control");
  if (event.altKey) names.push("alt");
  if (event.shiftKey) names.push("shift");
  if (event.metaKey) names.push("super");
  return names;
}

// The innermost element marked with the attribute from the target up to
// and including the view, so a mark drawn around a view never takes the
// clicks on its text.
function markedWithin(target, view, attribute) {
  for (let e = target; e !== null; e = e.parentElement) {
    if (e.hasAttribute(attribute)) return e;
    if (e === view) return null;
  }
  return null;
}

// A mark names its modifier as keys:event-modifiers does, since plugins
// write it in Scheme.
const markModifierHeld = new Map([
  ["control", (event) => event.ctrlKey],
  ["meta", (event) => event.altKey],
  ["shift", (event) => event.shiftKey],
  ["super", (event) => event.metaKey],
]);

function takenWithin(target, view, attribute, event) {
  const element = markedWithin(target, view, attribute);
  if (element === null) return null;
  const held = markModifierHeld.get(element.getAttribute(attribute));
  return held !== undefined && held(event) ? null : element;
}

// An event in a grid names the node it stands for, never a character,
// so it is never stale while the node lives.
function placeFor(view, grid, target, x, y) {
  const bar = target instanceof Element ? target.closest("[data-scroll-bar]") : null;
  if (bar !== null && own(view, bar)) return barPlace(view, bar, x, y);
  if (grid !== null) {
    const marked = markedAncestor(grid, view, true);
    return marked === null ? null : placeIn(marked);
  }
  return placeOf(view, target, x, y);
}

function referenceOf(target, view, grid) {
  for (let e = target; e !== null; e = e.parentElement) {
    if (e === grid || e === view || e.hasAttribute("data-keymap")) return e;
  }
  return view;
}

function keymapsOf(target, view) {
  const keymaps = [];
  for (let e = target; e !== null; e = e.parentElement) {
    if (e.hasAttribute("data-keymap")) keymaps.push(parseInt(e.getAttribute("data-keymap"), 10));
    if (e === view) break;
  }
  return keymaps;
}

function contentBox(element) {
  const b = element.getBoundingClientRect();
  const style = getComputedStyle(element);
  return {
    left: b.left + element.clientLeft + parseFloat(style.paddingInlineStart),
    top: b.top + element.clientTop + parseFloat(style.paddingBlockStart),
  };
}

// The cell under the pointer is counted here, in the reference's own
// cells, since Tuna keeps no size of the page's.
function pointer(reference, event) {
  const content = contentBox(reference);
  const x = event.clientX - content.left;
  const y = event.clientY - content.top;
  const cell = cellSize(reference);
  return { x, y, column: Math.max(0, Math.floor(x / cell.width)), row: Math.max(0, Math.floor(y / cell.height)) };
}

function sendMouse(view, action, place, extra) {
  const version = number(view, "data-version");
  const showing = number(view, "data-showing");
  const id = number(view, "data-view");
  if (version === null || showing === null || id === null) return;
  send({ type: "mouse", action, view: id, version, showing, ...place, ...extra });
}

// A drag's moves share the view's one report in flight, so a selection
// keeps pace with the screens that draw it.
function sendMove(view) {
  const p = press;
  if (p === null || p.view !== view || p.pending === null) return false;
  const state = states.get(view);
  if (state === undefined || state.sent !== null) return false;
  const { x, y } = p.pending;
  // The screen that frees the move may have replaced the element under
  // the pointer.
  const target = p.pending.target.isConnected ? p.pending.target : document.elementFromPoint(x, y);
  p.pending = null;
  if (!(target instanceof Element) || !own(view, target)) return false;
  const place = placeFor(view, p.grid, target, x, y);
  if (place === null) return false;
  state.sent = ++reports;
  sendMouse(view, "move", place, { modifiers: [], report: state.sent, ...pointer(p.reference, { clientX: x, clientY: y }) });
  return true;
}

function keymapsField(keymaps) {
  return keymaps.length === 0 ? {} : { keymaps };
}

function release(event) {
  const p = press;
  press = null;
  clearTimeout(p.repeat);
  const inView = event.target instanceof Element && own(p.view, event.target);
  const place = inView ? placeFor(p.view, p.grid, event.target, event.clientX, event.clientY) : null;
  sendMouse(p.view, p.dragging ? "drag" : "click", place ?? {},
    { button: p.button, clicks: p.clicks, modifiers: modifierNames(event), ...keymapsField(p.keymaps),
      ...(inView ? pointer(p.reference, event) : {}), ...partField(p.bar, event.clientX, event.clientY) });
}

// Tuna numbers the buttons as Emacs does on X: the left, middle and
// right buttons, then back and forward.
const buttonNumbers = [1, 2, 3, 8, 9];
const buttonMasks = [1, 4, 2, 8, 16];

// A press Tuna took is Tuna's alone, so what the browser would do after
// it, a click, a right press's menu, going back or forward, is cancelled
// until the next press.
let taken = false;

function cancel(event) {
  if (!taken) return;
  event.preventDefault();
  event.stopPropagation();
}

// Taking a press keeps the browser from selecting text and the keyboard
// focus where it is. A press on a thumb is the page's own drag.
document.addEventListener("mousedown", (event) => {
  if (press !== null) {
    event.preventDefault();
    return;
  }
  taken = false;
  const button = buttonNumbers[event.button];
  if (button === undefined || !(event.target instanceof Element)) return;
  const view = event.target.closest("[data-view]");
  if (view === null) return;
  event.preventDefault();
  taken = true;
  if (event.target.closest(".view-thumb") !== null) return;
  const grid = takenWithin(event.target, view, "data-grid", event);
  const keymaps = keymapsOf(event.target, view);
  const reference = referenceOf(event.target, view, grid);
  const bar = event.target.closest(".view-scroll-bar");
  press = { view, x: event.clientX, y: event.clientY, clicks: event.detail, button, mask: buttonMasks[event.button],
            keymaps, grid, reference, dragging: false, pending: null, repeat: null, bar };
  const fields = { button, clicks: event.detail, modifiers: modifierNames(event), ...keymapsField(keymaps),
                   ...pointer(reference, event), ...partField(bar, event.clientX, event.clientY) };
  const place = placeFor(view, grid, event.target, event.clientX, event.clientY) ?? {};
  sendMouse(view, "down", place, fields);
  if (bar !== null) repeatPress(press, place, fields);
}, true);

// A release outside the window sends no mouseup, so a move with the
// button up ends the press.
window.addEventListener("mousemove", (event) => {
  const p = press;
  if (p === null) return;
  if ((event.buttons & p.mask) === 0) {
    release(event);
    return;
  }
  if (!p.dragging && Math.hypot(event.clientX - p.x, event.clientY - p.y) <= dragThreshold) return;
  p.dragging = true;
  p.pending = { x: event.clientX, y: event.clientY, target: event.target };
  sendMove(p.view);
}, { passive: true });

window.addEventListener("mouseup", (event) => {
  if (press !== null && buttonNumbers[event.button] === press.button) {
    event.preventDefault();
    release(event);
  } else if (taken) {
    event.preventDefault();
  }
}, true);

window.addEventListener("click", cancel, true);
window.addEventListener("auxclick", cancel, true);
window.addEventListener("contextmenu", cancel, true);

// Elsewhere the browser scrolls, which keeps its momentum and the scroll
// reports; an element that takes the wheel gets a wheel key for each line
// the browser would have scrolled.
const wheelRest = new WeakMap();

function wheelLines(element, event, delta) {
  const lh = lineHeight(element) || 16;
  if (event.deltaMode === WheelEvent.DOM_DELTA_LINE) return delta;
  if (event.deltaMode === WheelEvent.DOM_DELTA_PAGE) return delta * Math.max(1, Math.floor(element.clientHeight / lh));
  return delta / lh;
}

function wheelTurned(event) {
  const element = event.currentTarget;
  if (!(event.target instanceof Element)) return;
  const view = event.target.closest("[data-view]");
  if (view === null || takenWithin(event.target, view, "data-wheel", event) !== element) return;
  event.preventDefault();
  const rest = wheelRest.get(element) ?? { x: 0, y: 0 };
  rest.x += wheelLines(element, event, event.deltaX);
  rest.y += wheelLines(element, event, event.deltaY);
  wheelRest.set(element, rest);
  // A turn names the node the element stands for, as a grid's events
  // do, so a redraw between turns never makes its place stale.
  const grid = takenWithin(event.target, view, "data-grid", event) ?? element;
  const reference = referenceOf(event.target, view, grid);
  const place = placeFor(view, grid, event.target, event.clientX, event.clientY) ?? {};
  const extra = { modifiers: modifierNames(event), ...keymapsField(keymapsOf(event.target, view)), ...pointer(reference, event) };
  for (const [axis, less, more] of [["y", "up", "down"], ["x", "left", "right"]]) {
    while (Math.abs(rest[axis]) >= 1) {
      const step = Math.sign(rest[axis]);
      rest[axis] -= step;
      sendMouse(view, "wheel", place, { direction: step < 0 ? less : more, ...extra });
    }
  }
}

// The browser waits for the page before it scrolls wherever a wheel
// listener may cancel, so only the elements that take the wheel carry one.
function takeWheel(element) {
  if (element.hasAttribute("data-wheel")) element.addEventListener("wheel", wheelTurned, { passive: false });
  else element.removeEventListener("wheel", wheelTurned);
}

function wheelMarksArrived(records) {
  for (const record of records) {
    if (record.type === "attributes") {
      if (record.attributeName === "data-wheel") takeWheel(record.target);
      continue;
    }
    for (const node of record.addedNodes) {
      if (!(node instanceof Element)) continue;
      if (node.hasAttribute("data-wheel")) takeWheel(node);
      for (const element of node.querySelectorAll("[data-wheel]")) takeWheel(element);
    }
  }
}

eachView(stateOf);
scrollersArrived();
for (const element of document.querySelectorAll("[data-wheel]")) takeWheel(element);

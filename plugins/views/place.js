(() => {
  function number(element, name) {
    const text = element?.getAttribute(name);
    const value = Number(text);
    return text != null && text !== "" && Number.isFinite(value) ? value : null;
  }

  // A whole item's wrapper has display: contents and no box of its own,
  // so its box is the union of its children's. An empty child's box has
  // no size but a place, which a range over the content would drop. An
  // element not rendered has no box, and null stands for it.
  function box(element) {
    if (getComputedStyle(element).display !== "contents") {
      return element.getClientRects().length === 0 ? null : element.getBoundingClientRect();
    }
    const boxes = Array.from(element.children, box).filter((b) => b !== null);
    if (boxes.length === 0) {
      const range = document.createRange();
      range.selectNodeContents(element);
      return range.getClientRects().length === 0 ? null : range.getBoundingClientRect();
    }
    const top = Math.min(...boxes.map((b) => b.top));
    const bottom = Math.max(...boxes.map((b) => b.bottom));
    const left = Math.min(...boxes.map((b) => b.left));
    const right = Math.max(...boxes.map((b) => b.right));
    return { top, bottom, left, right, height: bottom - top, width: right - left };
  }

  function viewItems(view) {
    return Array.from(view.querySelectorAll(".line, .node.whole"))
      .filter((item) => item.parentElement.closest(".node.whole, [data-view]") === view);
  }

  function contentTop(view) {
    return view.getBoundingClientRect().top + view.clientTop;
  }

  function contentLeft(view) {
    return view.getBoundingClientRect().left + view.clientLeft;
  }

  function extent(view, element) {
    const b = box(element);
    return b && { top: b.top - contentTop(view) + view.scrollTop, height: b.height,
                  left: b.left - contentLeft(view) + view.scrollLeft, width: b.width };
  }

  function findItem(view, at, line) {
    const all = viewItems(view);
    return (at === null ? undefined : all.find((item) => number(item, "data-at") === at))
      ?? (line === null ? undefined
        : all.find((item) => item.classList.contains("line") && !item.hasAttribute("data-at")
                             && number(item, "data-line") === line));
  }

  function own(view, element) {
    return element !== null && element.closest("[data-view]") === view;
  }

  function marked(view, at) {
    let found = null;
    for (const element of view.querySelectorAll("[data-at][data-to]")) {
      if (!own(view, element)) continue;
      const from = number(element, "data-at");
      const to = number(element, "data-to");
      if (from !== null && to !== null && from <= at && at < to) found = element;
    }
    return found;
  }

  function ownElement(view, selector) {
    return Array.from(view.querySelectorAll(selector)).find((element) => own(view, element)) ?? null;
  }

  // The computed style names a line height of normal only as a keyword;
  // the font's extent it stands for is 1lh in a registered length.
  function lineHeight(view) {
    const style = getComputedStyle(view);
    const height = parseFloat(style.lineHeight);
    return Number.isFinite(height) ? height : parseFloat(style.getPropertyValue("--views-line-height"));
  }

  // The page writes a view's scroll offsets only to carry out what Tuna
  // asked or to hold what is in view still; a scroll event at other
  // offsets is the hand's.
  const written = new WeakMap();
  let writes = 0;

  function setScroll(view, top, left) {
    writes++;
    view.scrollTop = top;
    if (left !== undefined) view.scrollLeft = left;
    written.set(view, { top: view.scrollTop, left: view.scrollLeft });
  }

  function byHand(view) {
    const w = written.get(view);
    return !(w && Math.abs(view.scrollTop - w.top) < 0.5 && Math.abs(view.scrollLeft - w.left) < 0.5);
  }

  function forgetWrite(view) {
    written.delete(view);
  }

  function extentOf(view, selector, at) {
    for (const element of [ownElement(view, selector), at === null ? null : marked(view, at)]) {
      const e = element && extent(view, element);
      if (e) return e;
    }
    return null;
  }

  function sideways(view) {
    return view.classList.contains("nowrap");
  }

  function textLeft(view) {
    return contentLeft(view) + parseFloat(getComputedStyle(view).paddingInlineStart);
  }

  function textRight(view) {
    return contentLeft(view) + view.clientWidth - parseFloat(getComputedStyle(view).paddingInlineEnd);
  }

  function pieces(line) {
    return Array.from(line.children).filter((child) => child.classList.contains("segment") || child.hasAttribute("data-gap"));
  }

  function longLines(view) {
    return Array.from(view.querySelectorAll(".line[data-line]"))
      .filter((line) => own(view, line) && pieces(line).length > 0);
  }

  // A run of raw bytes or control characters draws each position as
  // data-glyphs characters.
  function xAt(element, n) {
    const range = document.createRange();
    let left = n;
    const visit = (node) => {
      if (node.nodeType === Node.TEXT_NODE) {
        const glyphs = number(node.parentElement?.closest("[data-glyphs]"), "data-glyphs") ?? 1;
        let i = 0;
        let k = 0;
        for (const c of node.data) {
          if (left <= 0 && k % glyphs === 0) {
            range.setStart(node, i);
            range.collapse(true);
            const r = range.getClientRects()[0] ?? range.getBoundingClientRect();
            return r.left;
          }
          i += c.length;
          k++;
          if (k % glyphs === 0) left--;
        }
        return null;
      }
      for (const child of node.childNodes) {
        const x = visit(child);
        if (x !== null) return x;
      }
      return null;
    };
    const x = visit(element);
    if (x !== null) return { x, past: 0 };
    return { x: textBox(element).right, past: Math.max(0, left) };
  }

  // A line's own box is as wide as the view; its text may end before or
  // run past it.
  function textBox(line) {
    const range = document.createRange();
    range.selectNodeContents(line);
    const b = range.getBoundingClientRect();
    return b.width > 0 || b.height > 0 ? b : line.getBoundingClientRect();
  }

  // A gap stands for characters of its line never drawn, so its first
  // size is the width that line's drawn characters take on average: a
  // line of wide characters, or of raw bytes drawn four cells each, then
  // needs no correction for them.
  function charWidthOf(view, line) {
    let width = 0;
    let n = 0;
    for (const piece of pieces(line)) {
      if (piece.hasAttribute("data-gap")) continue;
      width += piece.getBoundingClientRect().width;
      n += number(piece, "data-to") - number(piece, "data-at");
    }
    return n > 0 && width > 0 ? width / n : charWidth(view);
  }

  function columnLine(view) {
    const item = number(view, "data-place-column-item");
    return item === null ? null : findItem(view, item, number(view, "data-place-column-line"));
  }

  function leftOf(view, column) {
    const line = columnLine(view);
    if (line === null) return column * charWidth(view);
    const all = pieces(line);
    let x;
    if (all.length === 0) {
      const found = xAt(line, column);
      x = found.x + found.past * charWidth(view);
    } else {
      const offsets = all.map((piece) => number(piece, "data-offset"));
      let i = offsets.findLastIndex((offset) => offset <= column);
      if (i < 0) i = 0;
      const piece = all[i];
      const into = column - offsets[i];
      if (piece.hasAttribute("data-gap")) {
        const b = piece.getBoundingClientRect();
        x = b.left + (into / Math.max(1, number(piece, "data-chars") ?? 0)) * b.width;
      } else {
        const length = number(piece, "data-to") - number(piece, "data-at");
        const found = xAt(piece, Math.min(into, length));
        x = found.x + (into > length ? (into - length) * charWidth(view) : 0);
      }
    }
    return view.scrollLeft + x - textLeft(view);
  }

  // A position is an item and the fraction of its height above the top
  // edge, so each device shows the same part of the item, and the column
  // at the left edge, so each shows the same text sideways.
  function toPosition(view) {
    const item = findItem(view, number(view, "data-place-item"), number(view, "data-place-line"));
    const e = item && extent(view, item);
    if (!e) return false;
    setScroll(view, e.top + (number(view, "data-place-fraction") ?? 0) * e.height);
    if (sideways(view)) setScroll(view, view.scrollTop, leftOf(view, number(view, "data-place-column") ?? 0));
    return true;
  }

  // A cursor on a character is the character's box, a glyph's height
  // inside its row; the bar it draws is a row tall about the glyph's
  // middle, and the row is what must be in view.
  function pointExtent(view) {
    const e = extentOf(view, ".cursor.primary, .cursor-on.primary, .view-point, .node.at-point", null);
    const lh = lineHeight(view);
    if (e === null || e.height >= lh || ownElement(view, ".cursor-on.primary") === null) return e;
    return { ...e, top: e.top + e.height / 2 - lh / 2, height: lh };
  }

  // Emacs keeps the scroll margin under a quarter of the view, so a short
  // view still moves its cursor.
  function margin(view) {
    return Math.min((number(view, "data-scroll-margin") ?? 0) * lineHeight(view), view.clientHeight / 4);
  }

  // Column 0 when the end of point's line fits the view from column 0,
  // as Emacs shows a short line whole; else the least scroll that shows
  // point clear of the padding, so a long line never jumps to its start.
  function followSideways(view, b) {
    if (!sideways(view)) return;
    const style = getComputedStyle(view);
    const left = view.scrollLeft + parseFloat(style.paddingInlineStart);
    const right = view.scrollLeft + view.clientWidth - parseFloat(style.paddingInlineEnd);
    const cursor = ownElement(view, ".cursor.primary, .cursor-on.primary");
    const line = cursor && cursor.closest(".line");
    if (line !== null && own(view, line)) {
      const end = textBox(line).right - contentLeft(view) + view.scrollLeft;
      if (end <= right - left + parseFloat(style.paddingInlineStart) + 0.5) {
        if (view.scrollLeft !== 0) setScroll(view, view.scrollTop, 0);
        return;
      }
    }
    if (b.left < left) setScroll(view, view.scrollTop, view.scrollLeft - (left - b.left));
    else if (b.left + b.width > right) setScroll(view, view.scrollTop, view.scrollLeft + b.left + b.width - right);
  }

  // The edge point was brought to is the one the other devices keep it
  // at.
  function follow(view) {
    const b = pointExtent(view);
    if (b === null) return null;
    followSideways(view, b);
    const height = view.clientHeight;
    const m = margin(view);
    const top = view.scrollTop;
    const bottom = b.top + b.height;
    if (b.height > height - 2 * m) {
      if (bottom > top && b.top < top + height) return null;
    } else if (b.top >= top + m - 0.5 && bottom <= top + height - m + 0.5) {
      return null;
    }
    if (b.top < top + m) {
      if (top + m - b.top <= height) { setScroll(view, b.top - m); return "top"; }
    } else if (bottom - (top + height - m) <= height) {
      setScroll(view, bottom - height + m);
      return "bottom";
    }
    setScroll(view, b.top + b.height / 2 - height / 2);
    return "center";
  }

  // A device that does not lead the view moves only when point passes
  // the edge the leading device keeps it at, so it shows the part of the
  // leading device's view nearest that edge.
  function keepAt(view, edge) {
    const b = pointExtent(view);
    if (b === null) return;
    followSideways(view, b);
    const height = view.clientHeight;
    const m = margin(view);
    const top = view.scrollTop;
    const bottom = b.top + b.height;
    if (edge === "top" && b.top < top + m - 0.5) setScroll(view, b.top - m);
    else if (edge === "bottom" && bottom > top + height - m + 0.5) setScroll(view, bottom - height + m);
    else if (edge === "center" && (bottom <= top || b.top >= top + height)) setScroll(view, b.top + b.height / 2 - height / 2);
  }

  const canvas = document.createElement("canvas").getContext("2d");

  function charWidth(element) {
    canvas.font = getComputedStyle(element).font;
    return canvas.measureText("0".repeat(10)).width / 10 || 8;
  }

  // The view's padding holds no text, so its size for text is its
  // content box, where rows wrap.
  function contentSize(view) {
    const style = getComputedStyle(view);
    return {
      width: Math.max(0, view.clientWidth - parseFloat(style.paddingInlineStart) - parseFloat(style.paddingInlineEnd)),
      height: Math.max(0, view.clientHeight - parseFloat(style.paddingBlockStart) - parseFloat(style.paddingBlockEnd)),
    };
  }

  function charsPerRow(view) {
    return sideways(view) ? Infinity : Math.max(1, Math.floor(contentSize(view).width / charWidth(view)));
  }

  // Chrome lays out in 1/64 px, so a finer size draws nothing different
  // and would only be written again.
  function px(n) {
    return `${Math.round(n * 64) / 64}px`;
  }

  function setBlock(element, n) {
    const size = px(n);
    if (element.style.blockSize !== size) element.style.blockSize = size;
  }

  function setGap(gap, n) {
    const size = px(n);
    if (gap.style.getPropertyValue("--views-gap") !== size) gap.style.setProperty("--views-gap", size);
  }

  function rowGaps(view) {
    return sideways(view) ? []
      : Array.from(view.querySelectorAll(".view-gap")).filter((gap) => own(view, gap) && !gap.closest(".line"));
  }

  // Browsers stop laying out a box at 17.9 million px (Firefox) or 33.5
  // million (Chrome, WebKit), and place positions past about 4 million to
  // no better than half a pixel; past this the spacers shrink. The first
  // screens are never shrunk, so a long scroll up to the start ends on
  // text measured as it came.
  const mostScrollPx = 4000000;
  const unshrunkScreens = 100;

  // Slots are kept in blocks, so a list of millions of rows costs only
  // what was drawn, and a tree of the blocks' sums finds the height above
  // a slot, or the slot at a height, in a walk of one block.
  const blockSize = 256;

  class Heights {
    constructor(count) {
      this.count = count;
      this.blocks = new Map();
      this.size = Math.max(1, Math.ceil(count / blockSize));
      this.sums = new Float64Array(this.size + 1);
      this.counts = new Float64Array(this.size + 1);
      this.measuredSum = 0;
      this.measured = 0;
      // A long line's slot is the sum of its segments, some of them
      // perhaps never drawn: slot -> { count, heights: Map }.
      this.lines = new Map();
    }

    add(block, dh, dc) {
      for (let j = block + 1; j <= this.size; j += j & -j) {
        this.sums[j] += dh;
        this.counts[j] += dc;
      }
      this.measuredSum += dh;
      this.measured += dc;
    }

    get(slot) {
      const block = this.blocks.get(Math.floor(slot / blockSize));
      return block === undefined ? NaN : block[slot % blockSize];
    }

    // NaN forgets the slot's height.
    set(slot, h) {
      if (slot < 0 || slot >= this.count) return;
      const b = Math.floor(slot / blockSize);
      let block = this.blocks.get(b);
      if (block === undefined) {
        if (Number.isNaN(h)) return;
        block = new Float64Array(blockSize).fill(NaN);
        this.blocks.set(b, block);
      }
      const old = block[slot % blockSize];
      if (old === h || (Number.isNaN(old) && Number.isNaN(h))) return;
      block[slot % blockSize] = h;
      this.add(b, (Number.isNaN(h) ? 0 : h) - (Number.isNaN(old) ? 0 : old), (Number.isNaN(h) ? 0 : 1) - (Number.isNaN(old) ? 0 : 1));
    }

    mean(fallback) {
      return this.measured > 0 ? this.measuredSum / this.measured : fallback;
    }

    above(slot, est) {
      slot = Math.max(0, Math.min(this.count, slot));
      const b = Math.floor(slot / blockSize);
      let sum = 0;
      let n = 0;
      for (let j = b; j > 0; j -= j & -j) {
        sum += this.sums[j];
        n += this.counts[j];
      }
      const block = this.blocks.get(b);
      if (block !== undefined) {
        for (let i = b * blockSize; i < slot; i++) {
          const h = block[i % blockSize];
          if (!Number.isNaN(h)) { sum += h; n++; }
        }
      }
      return sum + (slot - n) * est;
    }

    height(slot, est) {
      const h = this.get(slot);
      return Number.isNaN(h) ? est : h;
    }

    slotAt(u, est) {
      if (this.count === 0) return { slot: 0, into: 0 };
      let b = 0;
      let acc = 0;
      let step = 1;
      while (step * 2 <= this.size) step *= 2;
      for (; step > 0; step >>= 1) {
        const next = b + step;
        if (next > this.size) continue;
        const slots = Math.min(next * blockSize, this.count) - b * blockSize;
        const add = this.sums[next] + (slots - this.counts[next]) * est;
        if (acc + add <= u) {
          b = next;
          acc += add;
        }
      }
      let slot = b * blockSize;
      const last = this.count - 1;
      for (; slot < last; slot++) {
        const h = this.height(slot, est);
        if (acc + h > u) break;
        acc += h;
      }
      slot = Math.min(slot, last);
      return { slot, into: Math.max(0, u - acc) };
    }

    entries() {
      const all = [];
      for (const [b, block] of this.blocks) {
        for (let i = 0; i < blockSize; i++) {
          if (!Number.isNaN(block[i])) all.push([b * blockSize + i, block[i]]);
        }
      }
      return all;
    }

    splice(from, removed, inserted) {
      if (removed === inserted) {
        for (let s = from; s < from + removed; s++) {
          this.set(s, NaN);
          this.lines.delete(s);
        }
        return;
      }
      const moved = (s) => (s < from ? s : s >= from + removed ? s + inserted - removed : null);
      const all = this.entries();
      const lines = this.lines;
      Object.assign(this, new Heights(this.count + inserted - removed));
      for (const [s, h] of all) {
        const to = moved(s);
        if (to !== null) this.set(to, h);
      }
      for (const [s, line] of lines) {
        const to = moved(s);
        if (to !== null) this.lines.set(to, line);
      }
    }

    // A long line drawn in part counts its other segments at the mean of
    // those measured.
    setSegment(slot, index, count, h) {
      let line = this.lines.get(slot);
      if (line === undefined || line.count !== count) {
        line = { count, heights: new Map() };
        this.lines.set(slot, line);
      }
      line.heights.set(index, h);
      let sum = 0;
      for (const v of line.heights.values()) sum += v;
      this.set(slot, sum + (count - line.heights.size) * (sum / line.heights.size));
    }

    segmentHeight(slot, index, est) {
      const line = this.lines.get(slot);
      if (line === undefined) return est;
      const h = line.heights.get(index);
      if (h !== undefined) return h;
      let sum = 0;
      for (const v of line.heights.values()) sum += v;
      return sum / line.heights.size;
    }

    segmentsBefore(slot, index, est) {
      let sum = 0;
      for (let i = 0; i < index; i++) sum += this.segmentHeight(slot, i, est);
      return sum;
    }
  }

  // Kept by view number, not by element: the morph may make a view's
  // element anew, and its heights hold for the new one.
  const tables = new Map();

  function laidOut(view) {
    return view.getClientRects().length > 0 && view.clientWidth > 0;
  }

  // A height table holds while the view shows the same buffer, at the same
  // width, wrapping the same way, in the same stylesheets and fonts.
  function tableOf(view) {
    const id = number(view, "data-view");
    const slots = number(view, "data-slots") ?? 0;
    const version = number(view, "data-slot-version");
    const showing = view.getAttribute("data-showing");
    const wrap = !sideways(view);
    const width = laidOut(view) ? contentSize(view).width : null;
    let t = tables.get(id);
    let forgot = t === undefined;
    if (t !== undefined && (t.showing !== showing || t.wrap !== wrap || (width !== null && t.width !== null && t.width !== width))) {
      forgot = t.wrap !== wrap ? "wrap" : true;
    } else if (t !== undefined && t.version !== version) {
      const edits = (view.getAttribute("data-slot-edits") ?? "").split(" ").filter((x) => x !== "").map(Number);
      if (edits.length === 0 || edits[0] !== t.version || (edits.length - 1) % 3 !== 0) {
        forgot = true;
      } else {
        for (let i = 1; i < edits.length; i += 3) t.heights.splice(edits[i], edits[i + 1], edits[i + 2]);
      }
    }
    if (!forgot && t.heights.count !== slots) forgot = true;
    if (forgot) {
      t = { heights: new Heights(slots), showing, wrap, width, version, frozen: null, forgot };
      tables.set(id, t);
    }
    t.version = version;
    if (width !== null) t.width = width;
    return t;
  }

  function forgetTables() {
    tables.clear();
  }

  // The estimate and the scale stay as they were between rests, so an
  // item growing in view does not move the thumb on every frame.
  function freeze(view, t) {
    const est = t.heights.mean(lineHeight(view));
    const total = t.heights.above(t.heights.count, est);
    const unshrunk = Math.min(unshrunkScreens * view.clientHeight, mostScrollPx / 2);
    t.frozen = { est, unshrunk, scale: total <= mostScrollPx ? 1 : (mostScrollPx - unshrunk) / (total - unshrunk) };
  }

  function frozen(view, t) {
    if (t.frozen === null) freeze(view, t);
    return t.frozen;
  }

  function spacerPx(f, u) {
    return u <= f.unshrunk ? u : f.unshrunk + f.scale * (u - f.unshrunk);
  }

  function estimatedPx(f, v) {
    return v <= f.unshrunk ? v : f.unshrunk + (v - f.unshrunk) / f.scale;
  }

  function itemTop(item) {
    if (item.classList.contains("line")) {
      const rects = item.getClientRects();
      return rects.length === 0 ? null : rects[0].top;
    }
    const b = box(item);
    return b && b.top;
  }

  function itemBox(item) {
    return item.classList.contains("line")
      ? (item.getClientRects().length === 0 ? null : item.getBoundingClientRect())
      : box(item);
  }

  function runOf(view, t, f) {
    const items = viewItems(view);
    const first = items[0];
    const last = items[items.length - 1];
    if (first === undefined) return null;
    const slot = (item) => number(item, "data-slot") ?? 0;
    let start = t.heights.above(slot(first), f.est);
    const index = number(first, "data-segment");
    if (index !== null) start += t.heights.segmentsBefore(slot(first), index, f.est);
    let end = t.heights.above(slot(last) + 1, f.est);
    const lastIndex = number(last, "data-segment");
    const count = number(last, "data-segments");
    if (lastIndex !== null && count !== null) {
      end -= t.heights.height(slot(last), f.est) - t.heights.segmentsBefore(slot(last), lastIndex + 1, f.est);
    }
    return { items, start, end, total: t.heights.above(t.heights.count, f.est) };
  }

  // An item's height is its advance, from its top to the next drawn
  // item's top, so the heights of a stretch sum to its height whatever
  // lies between items; an item laid beside the next would advance by
  // nothing or less, and what is less is carried to the next, since a
  // height below 0 would let the sums fall. An item with no box takes no
  // room, so it measures 0.
  function measureInto(view, t) {
    if (!laidOut(view)) return;
    const items = viewItems(view);
    const tops = items.map(itemTop);
    // The last item with a box has no next top, so its own box stands in
    // for its advance and misses the gap before the next item. A slot
    // measured before keeps its height, or the table, and the thumb with
    // it, would change with where each run ends.
    const end = items.findLastIndex((item, i) => tops[i] !== null);
    const endSlot = end < 0 || view.hasAttribute("data-run-at-end") || number(items[end], "data-segment") !== null
      ? null : number(items[end], "data-slot");
    const kept = endSlot !== null && !Number.isNaN(t.heights.get(endSlot)) ? endSlot : null;
    let carry = 0;
    let previous = null;
    let previousSum = 0;
    let previousSegment = false;
    for (let i = 0; i < items.length; i++) {
      const item = items[i];
      const slot = number(item, "data-slot");
      if (slot === null) continue;
      if (previous !== null) for (let s = previous + 1; s < slot; s++) t.heights.set(s, 0);
      if (slot === kept) { previous = slot; continue; }
      let next = null;
      for (let k = i + 1; k < items.length; k++) if (tops[k] !== null) { next = tops[k]; break; }
      let h = tops[i] === null ? 0 : next !== null ? next - tops[i] : itemBox(item).height;
      h += carry;
      carry = Math.min(0, h);
      h = Math.max(0, h);
      const index = number(item, "data-segment");
      const count = number(item, "data-segments");
      if (index !== null && count !== null) {
        t.heights.setSegment(slot, index, count, h);
        previousSegment = true;
      } else {
        previousSum = previous === slot && !previousSegment ? previousSum + h : h;
        t.heights.set(slot, previousSum);
        previousSegment = false;
      }
      previous = slot;
    }
    if (previous === null) return;
    const firstSlot = number(items[0], "data-slot") ?? 0;
    if (view.hasAttribute("data-run-at-start")) for (let s = 0; s < firstSlot; s++) t.heights.set(s, 0);
    if (view.hasAttribute("data-run-at-end")) for (let s = previous + 1; s < t.heights.count; s++) t.heights.set(s, 0);
  }

  function spacers(view) {
    return [view.querySelector(':scope > [data-spacer="above"]'), view.querySelector(':scope > [data-spacer="below"]')];
  }

  // The spacers stand for the slots not drawn, at the table's sums. While
  // the hand owns the offset the page sizes them itself, to hold the text
  // and the scroll height still.
  function sizeSpacers(view, owned, refreeze) {
    const t = tableOf(view);
    measureInto(view, t);
    if (refreeze || t.frozen === null || t.forgot) freeze(view, t);
    t.forgot = false;
    const f = t.frozen;
    const [above, below] = spacers(view);
    const run = runOf(view, t, f);
    sizeGaps(view);
    if (owned) return;
    if (above !== null) setBlock(above, run === null ? 0 : spacerPx(f, run.start));
    if (below === null) return;
    // The run's last item drawn ends at its own box, short of the advance
    // the table may hold for it; the spacer below takes up the difference,
    // or the scroll height would change with which item ends the run.
    const short = run === null || above === null ? 0
      : run.end - run.start - (below.getBoundingClientRect().top - above.getBoundingClientRect().bottom);
    setBlock(below, run === null ? 0 : Math.max(0, spacerPx(f, run.total) - spacerPx(f, run.end) + short));
  }

  function sizeGaps(view) {
    if (!sideways(view)) {
      // A long line's first drawn segment starts on the row that ends the
      // characters before it, so its gap holds only those past whole rows.
      const perRow = charsPerRow(view);
      for (const gap of rowGaps(view)) setGap(gap, ((number(gap, "data-chars") ?? 0) % perRow) * charWidth(view));
      return;
    }
    // Every width is read before any gap is written, or each write would
    // make the next read lay the whole view out again.
    const widths = longLines(view).map((line) => [line, charWidthOf(view, line)]);
    for (const [line, width] of widths) {
      for (const gap of pieces(line)) {
        if (gap.hasAttribute("data-gap")) setGap(gap, Math.round(Math.min(mostScrollPx, (number(gap, "data-chars") ?? 0) * width)));
      }
    }
  }

  function placeAt(view, y) {
    const t = tableOf(view);
    const f = frozen(view, t);
    for (const item of viewItems(view)) {
      const e = extent(view, item);
      if (e !== null && e.top <= y && y < e.top + Math.max(e.height, 0.5)) {
        return { item, slot: number(item, "data-slot") ?? 0, segment: number(item, "data-segment"),
                 fraction: Math.min(1, Math.max(0, (y - e.top) / Math.max(1, e.height))) };
      }
    }
    const run = runOf(view, t, f);
    const [above, below] = spacers(view);
    let u;
    if (run === null) {
      u = 0;
    } else if (above !== null && y < above.offsetHeight) {
      u = estimatedPx(f, (y / Math.max(1, above.offsetHeight)) * spacerPx(f, run.start));
    } else {
      const top = below === null ? 0 : extent(view, below)?.top ?? 0;
      const rest = spacerPx(f, run.total) - spacerPx(f, run.end);
      const share = below === null || below.offsetHeight === 0 ? 1 : Math.min(1, Math.max(0, (y - top) / below.offsetHeight));
      u = estimatedPx(f, spacerPx(f, run.end) + share * rest);
    }
    const { slot, into } = t.heights.slotAt(u, f.est);
    const line = t.heights.lines.get(slot);
    if (line !== undefined) {
      let rest = into;
      for (let i = 0; i < line.count; i++) {
        const h = t.heights.segmentHeight(slot, i, f.est);
        if (rest < h || i === line.count - 1) return { item: null, slot, segment: i, fraction: Math.min(1, rest / Math.max(1, h)) };
        rest -= h;
      }
    }
    const h = t.heights.height(slot, f.est);
    return { item: null, slot, segment: null, fraction: Math.min(1, into / Math.max(1, h)) };
  }

  function slotFrom(view, y, down) {
    const t = tableOf(view);
    const f = frozen(view, t);
    const at = placeAt(view, y);
    let u = t.heights.above(at.slot, f.est);
    const h = at.segment === null ? t.heights.height(at.slot, f.est) : t.heights.segmentHeight(at.slot, at.segment, f.est);
    if (at.segment !== null) u += t.heights.segmentsBefore(at.slot, at.segment, f.est);
    u = Math.max(0, u + at.fraction * h + down);
    const total = t.heights.above(t.heights.count, f.est);
    const found = t.heights.slotAt(Math.min(u, Math.max(0, total - 0.001)), f.est);
    const line = t.heights.lines.get(found.slot);
    if (line === undefined) return { slot: found.slot, segment: null };
    let rest = found.into;
    for (let i = 0; i < line.count; i++) {
      const sh = t.heights.segmentHeight(found.slot, i, f.est);
      if (rest < sh) return { slot: found.slot, segment: i };
      rest -= sh;
    }
    return { slot: found.slot, segment: line.count - 1 };
  }

  function placeView(view, fresh) {
    const kind = view.getAttribute("data-place-kind");
    if (kind === "position") {
      toPosition(view);
      return "top";
    }
    if (kind === "follow") {
      const edge = view.getAttribute("data-place-edge") ?? "top";
      if (fresh) toPosition(view);
      if (!view.hasAttribute("data-lead")) {
        keepAt(view, edge);
        return edge;
      }
      return follow(view) ?? edge;
    }
    if (kind === "top" || kind === "center" || kind === "bottom") {
      const b = extentOf(view, ".view-place", number(view, "data-place-at"));
      if (b !== null) {
        setScroll(view, kind === "top" ? b.top
          : kind === "center" ? b.top + b.height / 2 - view.clientHeight / 2
          : b.top + b.height - view.clientHeight);
      }
      return kind;
    }
    return "top";
  }

  const firstEdges = new WeakMap();

  function firstEdge(view, placement) {
    const first = firstEdges.get(view);
    return first !== undefined && first.placement === placement ? first.edge : null;
  }

  // A classic script cannot import a module, so the views module takes
  // what it shares with the first screen from this global.
  window.tunaViews = { number, box, viewItems, contentTop, extent, own, lineHeight, setScroll, byHand, forgetWrite,
                       sideways, textLeft, textRight, pieces, longLines, textBox, pointExtent, margin, follow, keepAt,
                       charWidth, contentSize, charsPerRow, px, setBlock, setGap, rowGaps, sizeSpacers, placeView,
                       firstEdge, laidOut, tableOf, forgetTables, freeze, frozen, spacers, placeAt, slotFrom, itemBox,
                       measured: (id) => tables.get(id)?.heights.measured ?? 0, writes: () => writes,
                       table: (id) => tables.get(id) };

  // The first screen comes inside the page and is placed by this classic
  // script before the browser paints it; a module runs too late for that.
  document.addEventListener("tuna-first-screen", () => {
    for (const view of document.querySelectorAll(".view[data-placement]")) {
      sizeSpacers(view);
      firstEdges.set(view, { edge: placeView(view, true), placement: number(view, "data-placement") });
    }
  });
})();

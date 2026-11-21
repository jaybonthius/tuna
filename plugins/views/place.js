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

  function setScroll(view, top, left) {
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

  function pointExtent(view) {
    return extentOf(view, ".cursor.primary, .cursor-on.primary", null);
  }

  // Emacs keeps the scroll margin under a quarter of the view, so a short
  // view still moves its cursor.
  function margin(view) {
    return Math.min((number(view, "data-scroll-margin") ?? 0) * lineHeight(view), view.clientHeight / 4);
  }

  function followSideways(view, b) {
    if (!sideways(view)) return;
    const style = getComputedStyle(view);
    const left = view.scrollLeft + parseFloat(style.paddingInlineStart);
    const right = view.scrollLeft + view.clientWidth - parseFloat(style.paddingInlineEnd);
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

  // Firefox lays out nothing past 17,895,697 px and Chrome nothing past
  // 33,554,428, so the spacers of a larger text share what is left.
  const mostSpacerPx = 16000000;

  function charsPerRow(view) {
    return sideways(view) ? Infinity : Math.max(1, Math.floor(contentSize(view).width / charWidth(view)));
  }

  function extraRows(perRow, lines, chars) {
    return perRow === Infinity ? 0 : Math.max(0, Math.ceil((chars - lines * perRow * 0.5) / perRow));
  }

  function rows(view, lines, chars) {
    return lines + extraRows(charsPerRow(view), lines, chars);
  }

  // A spacer stands for text never drawn here, so its height is a guess
  // from its counts, as CodeMirror's height oracle guesses a gap: a row
  // per line, a wrapped line counting a row more for each row of
  // characters past half its first, at the height the drawn text's rows,
  // counted the same way, take on average. It keeps nothing of what was
  // drawn before, so a place in it is always the same share of its
  // counts, and the page holds what is drawn still by the scroll offset.
  function rowHeight(view, spacers) {
    const all = viewItems(view);
    const first = all.length > 0 ? box(all[0]) : null;
    const last = all.length > 0 ? box(all[all.length - 1]) : null;
    if (first === null || last === null) return lineHeight(view);
    let lines = number(view, "data-lines") ?? 0;
    let chars = number(view, "data-chars") ?? 0;
    for (const spacer of spacers) {
      lines -= number(spacer, "data-lines") ?? 0;
      chars -= number(spacer, "data-chars") ?? 0;
    }
    return Math.max(1, last.bottom - first.top) / Math.max(1, rows(view, lines, chars));
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

  // While the hand owns the offset the spacer above keeps its size, and
  // the hold then changes it by what would move the drawn text: sized
  // first from its counts, a smaller spacer could leave the view shorter
  // than its offset for a moment, and the browser would move the offset
  // to fit, away from the hand's.
  function sizeSpacers(view, keepAbove) {
    const spacers = Array.from(view.querySelectorAll(":scope > [data-spacer]"));
    const row = spacers.length > 0 ? rowHeight(view, spacers) : 0;
    const heights = spacers.map((spacer) => row * rows(view, number(spacer, "data-lines") ?? 0, number(spacer, "data-chars") ?? 0));
    const total = heights.reduce((a, b) => a + b, 0);
    const scale = total > mostSpacerPx ? mostSpacerPx / total : 1;
    spacers.forEach((spacer, i) => {
      if (!(keepAbove && spacer.getAttribute("data-spacer") === "above")) setBlock(spacer, Math.round(heights[i] * scale));
    });
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
        if (gap.hasAttribute("data-gap")) setGap(gap, Math.round(Math.min(mostSpacerPx, (number(gap, "data-chars") ?? 0) * width)));
      }
    }
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
                       firstEdge };

  // The first screen comes inside the page and is placed by this classic
  // script before the browser paints it; a module runs too late for that.
  document.addEventListener("tuna-first-screen", () => {
    for (const view of document.querySelectorAll(".view[data-placement]")) {
      sizeSpacers(view);
      firstEdges.set(view, { edge: placeView(view, true), placement: number(view, "data-placement") });
    }
  });
})();

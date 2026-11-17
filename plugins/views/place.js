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

  function items(view) {
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
    const all = items(view);
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

  function placeBox(view, mark, prefix) {
    const at = number(view, `data-${prefix}-at`);
    const marker = Array.from(view.querySelectorAll(mark)).find((element) => own(view, element));
    const candidates = [marker, at === null ? null : marked(view, at),
                        findItem(view, number(view, `data-${prefix}-item`), number(view, `data-${prefix}-line`))];
    for (const element of candidates) {
      const e = element && extent(view, element);
      if (e) return e;
    }
    return null;
  }

  // Another device measured the item at another height, so it gets the
  // same fraction of the item; the same device gets the same pixels.
  function scaled(offset, height, reported) {
    if (Math.abs(height - reported) < 0.5 || height < 1 || reported < 1) return offset;
    return offset * height / reported;
  }

  function position(view, prefix) {
    const item = findItem(view, number(view, `data-${prefix}-item`), number(view, `data-${prefix}-line`));
    const e = item && extent(view, item);
    if (!e) return;
    view.scrollTop = e.top + scaled(number(view, `data-${prefix}-offset`) ?? 0, e.height,
                                     number(view, `data-${prefix}-height`) ?? 0);
    view.scrollLeft = number(view, `data-${prefix}-left`) ?? 0;
  }

  function lineHeight(view) {
    const style = getComputedStyle(view);
    const height = parseFloat(style.lineHeight);
    return Number.isFinite(height) ? height : 1.2 * parseFloat(style.fontSize);
  }

  // Emacs keeps the scroll margin under a quarter of the view, so a short
  // view still moves its cursor.
  function follow(view) {
    const b = placeBox(view, ".cursor.primary", "place");
    if (b === null) return;
    if (view.classList.contains("nowrap")) {
      const style = getComputedStyle(view);
      const left = view.scrollLeft + parseFloat(style.paddingLeft);
      const right = view.scrollLeft + view.clientWidth - parseFloat(style.paddingRight);
      if (b.left < left) view.scrollLeft -= left - b.left;
      else if (b.left + b.width > right) view.scrollLeft += b.left + b.width - right;
    }
    const height = view.clientHeight;
    const margin = Math.min((number(view, "data-scroll-margin") ?? 0) * lineHeight(view), height / 4);
    const top = view.scrollTop;
    const bottom = b.top + b.height;
    if (b.height > height - 2 * margin) {
      if (bottom > top && b.top < top + height) return;
    } else if (b.top >= top + margin - 0.5 && bottom <= top + height - margin + 0.5) {
      return;
    }
    if (b.top < top + margin) {
      view.scrollTop = top + margin - b.top <= height ? b.top - margin : b.top + b.height / 2 - height / 2;
    } else {
      view.scrollTop = bottom - (top + height - margin) <= height ? bottom - height + margin : b.top + b.height / 2 - height / 2;
    }
  }

  // A follow placement is relative to what the view shows, so a new
  // element first takes the position the screen gives as its base.
  function place(view, fresh) {
    const top = view.scrollTop;
    const left = view.scrollLeft;
    const kind = view.getAttribute("data-place-kind");
    if (kind === "position") {
      position(view, "place");
    } else if (kind === "follow") {
      if (fresh && view.hasAttribute("data-base-item")) position(view, "base");
      follow(view);
    } else if (kind === "top" || kind === "center" || kind === "bottom") {
      const b = placeBox(view, ".view-place", "place");
      if (b !== null) {
        view.scrollTop = kind === "top" ? b.top
          : kind === "center" ? b.top + b.height / 2 - view.clientHeight / 2
          : b.top + b.height - view.clientHeight;
      }
    }
    return Math.abs(view.scrollTop - top) > 0.5 || Math.abs(view.scrollLeft - left) > 0.5;
  }

  window.tunaViews = { number, box, items, extent, place, lineHeight };

  // The first screen comes inside the page and is placed by this classic
  // script before the browser paints it; a module runs too late for that.
  document.addEventListener("tuna-first-screen", () => {
    for (const view of document.querySelectorAll(".view[data-placement]")) {
      place(view, true);
      view.tunaPlaced = number(view, "data-placement");
    }
  });
})();

import { define } from "tuna";
import { dragEdges, pressFor, followEdge, lengthOf, cellOf } from "layout";

dragEdges(".split-divider");

function partOf(split, entry, axis) {
  const element = split.children[entry.index];
  const length = lengthOf(element, axis);
  const cell = cellOf(element, axis);
  return { index: entry.index, element, length, cell, counted: entry.counted, minimum: entry.minimum,
           count: Math.round(length / cell) };
}

function room(part) {
  if (part.length <= 0 || part.length <= part.minimum * part.cell) return 0;
  return part.counted ? Math.max(0, part.count - part.minimum) * part.cell : part.length - part.minimum * part.cell;
}

// A counted part that grows takes whole cells, so a counted part gives
// past what is left only first, where a part sizing by weight can give
// the excess back: giving less would leave the edge up to a cell behind
// the pointer.
function given(part, left, whole) {
  const r = room(part);
  if (r <= 0 || left <= 0) return 0;
  if (!part.counted) return Math.min(r, left);
  const cells = left / part.cell;
  return Math.min(r, ({ near: Math.round, under: (n) => Math.floor(n + 1e-9), over: (n) => Math.ceil(n - 1e-9) })[whole](cells) * part.cell);
}

// The nearest part on the other side takes all the travel the parts give,
// so the parts changed keep their total length and no other part moves.
// A counted part that grows takes whole cells.
function lengths(before, after, travel) {
  const [grower, givers] = travel > 0 ? [before[0], after] : [after[0], before];
  const capacity = givers.reduce((sum, part) => sum + room(part), 0);
  const cell = grower.cell;
  let wanted = grower.counted
    ? Math.min(Math.round(Math.abs(travel) / cell), Math.floor(capacity / cell + 1e-9)) * cell
    : Math.min(Math.abs(travel), capacity);
  let whole = grower.counted ? "over" : "near";
  for (;;) {
    const gifts = new Map();
    let left = wanted;
    for (const part of givers) {
      const g = given(part, left, whole);
      if (g > 0) gifts.set(part, g);
      left -= g;
    }
    let total = wanted - left;
    if (grower.counted) {
      let excess = total - Math.floor(total / cell + 1e-9) * cell;
      for (const part of [...givers].reverse()) {
        if (excess <= 1e-9 || part.counted || !gifts.has(part)) continue;
        const back = Math.min(excess, gifts.get(part));
        gifts.set(part, gifts.get(part) - back);
        excess -= back;
        total -= back;
      }
      if (excess > 1e-9) {
        wanted = Math.min(wanted, Math.floor(total / cell + 1e-9) * cell);
        whole = "under";
        continue;
      }
    }
    const result = new Map();
    for (const [part, g] of gifts) if (g > 0) result.set(part, part.length - g);
    if (total > 0) result.set(grower, grower.length + total);
    return result;
  }
}

define("layout-split-drag", (question) => {
  const press = pressFor(question);
  if (press === null) return null;
  const child = press.edge.parentElement;
  const split = child.parentElement;
  if (Array.prototype.indexOf.call(split.children, child) + 1 !== question.index) return null;
  const axis = question.axis;
  const before = question.before.map((entry) => partOf(split, entry, axis));
  const after = question.after.map((entry) => partOf(split, entry, axis));
  return followEdge(press, {
    parts: [...before, ...after],
    property: "--layout-split-flex",
    value: (length) => `0 0 ${length}px`,
    lengthsAt: (dx, dy) => lengths(before, after, axis === "row" ? dx : dy),
  });
});

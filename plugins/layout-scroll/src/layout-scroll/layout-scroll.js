import { define } from "tuna";
import { dragEdges, pressFor, followEdge, lengthOf, cellOf } from "layout";

dragEdges(".strip-handle");

// A column already past a bound, as on a narrow device, is not moved to
// it.
function bounded(length, least, most, start) {
  return Math.min(Math.max(length, Math.min(least, start)), Math.max(most, start));
}

define("layout-scroll-drag", (question) => {
  const press = pressFor(question);
  if (press === null) return null;
  const item = press.edge.parentElement;
  const scroller = item.parentElement;
  const axis = question.axis;
  const column = { index: question.index, element: item, length: lengthOf(item, axis) };
  const cell = cellOf(item, axis);
  const most = axis === "row" ? scroller.clientWidth : scroller.clientHeight;
  return followEdge(press, {
    parts: [column],
    property: "--layout-scroll-size",
    value: (length) => `${length}px`,
    lengthsAt: (dx, dy) => {
      const travel = axis === "row" ? dx : dy;
      const length = question.counted
        ? bounded(Math.round((column.length + travel) / cell), question.minimum, Math.floor(most / cell),
                  Math.round(column.length / cell)) * cell
        : bounded(column.length + travel, question.minimum * cell, most, column.length);
      return new Map([[column, length]]);
    },
    // Snapping would carry the strip to a column's edge while the column's
    // length changes under the pointer.
    holding: (on) => {
      const value = on ? "none" : "";
      if (scroller.style.getPropertyValue("scroll-snap-type") !== value) scroller.style.setProperty("scroll-snap-type", value);
    },
  });
});

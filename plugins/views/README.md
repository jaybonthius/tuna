# views

Shows buffers: a view is one buffer in one place, with its own cursors, scroll position, folds, narrowing and options, drawn as HTML. Every client shows a view at one scroll position, fitted to its own size. The browser scrolls a view natively, by items: lines and nodes drawn whole. `height-map.sls` keeps the heights each device measured; `views.js` reports what the browser measured and applies placements, `place.js` places the first screen before the browser paints it, and `views.css` keeps the view's total height constant while it scrolls.

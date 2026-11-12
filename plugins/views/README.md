# views

Shows buffers: a view is one buffer in one place, with its own cursors, scroll position, folds, narrowing and options, drawn as HTML. Every client shows a view at one scroll position, fitted to its own size. The browser scrolls a view natively; `views.js` reports what it measured and applies placements, and `views.css` keeps the view's total height constant while it scrolls.

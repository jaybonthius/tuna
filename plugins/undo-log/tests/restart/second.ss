(import (tuna) (test) (undo) (buffers) (commands) (files) (session))

(session:wait-for-restart!)

(test "a restart visits the file with the unsaved edit in, before the view binds its cursor, which shows the text it was on"
  (check-equal? '("b.txt" 3 "gamma") (session:shown))
  (check-equal? '("unsaved alpha\nbeta\ngamma\ndelta\n" #t) (list (session:text) (buffers:modified? (session:b)))))

(test "undo goes back to the file's text, unmodified"
  (buffers:with-buffer (session:b) (commands:run undo:undo 1))
  (check-equal? '("alpha\nbeta\ngamma\ndelta\n" #f) (list (session:text) (buffers:modified? (session:b)))))

(commands:run files:save-buffers-kill-tuna)

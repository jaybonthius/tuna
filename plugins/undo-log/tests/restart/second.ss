(import (tuna) (test) (undo) (buffers) (commands) (files) (undo-log-test session))

(undo-log-test/session:wait-for-restart!)

(test "a restart visits the file with the unsaved edit in, before the view binds its cursor, which shows the text it was on"
  (check-equal? '("b.txt" 3 "gamma") (undo-log-test/session:shown))
  (check-equal? '("unsaved alpha\nbeta\ngamma\ndelta\n" #t) (list (undo-log-test/session:text) (buffers:modified? (undo-log-test/session:b)))))

(test "undo goes back to the file's text, unmodified"
  (buffers:with-buffer (undo-log-test/session:b) (commands:run undo:undo 1))
  (check-equal? '("alpha\nbeta\ngamma\ndelta\n" #f) (list (undo-log-test/session:text) (buffers:modified? (undo-log-test/session:b)))))

(commands:run files:save-buffers-kill-tuna)

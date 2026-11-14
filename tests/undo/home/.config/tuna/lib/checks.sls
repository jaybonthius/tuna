#!tuna
(import (buffers) (document) (commands) (undo))

(define (end b) (fx- (document:length (buffers:document b)) 1))

(commands:define-command (type text)
  "Inserts TEXT at the end of the current buffer, joining the previous group as typing does."
  (undo:amalgamate!)
  (let ([b (buffers:current)])
    (buffers:replace! b (end b) (end b) text)))

(commands:define-command (insert position text)
  "Inserts TEXT at POSITION in the current buffer."
  (buffers:replace! (buffers:current) position position text))

(commands:define-command (delete start end)
  "Deletes from START to END in the current buffer."
  (buffers:replace! (buffers:current) start end ""))

(commands:define-command (insert-pausing text)
  "Inserts TEXT at the start, pauses, and inserts it again."
  (let ([b (buffers:current)])
    (buffers:replace! b 1 1 text)
    (sleep-for 0.01)
    (buffers:replace! b 1 1 text)))

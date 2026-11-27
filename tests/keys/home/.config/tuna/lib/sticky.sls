#!tuna
(import (commands) (keys) (layout) (tables))

(tables:define-table keymap "The keys that repeat a window command.")

(define %ended 0)

(define (ended) %ended)

(define %end-repeat #f)

(commands:define-command (other-view-repeat)
  "Selects the next view and lets o select the one after."
  (layout:other-view)
  (set! %end-repeat
    (keys:push-keymap! (layout:current-frame) keymap
      (lambda (found command) (eq? found keymap))
      (lambda () (set! %ended (+ %ended 1))))))

(keys:bind! keymap "o" layout:other-view)

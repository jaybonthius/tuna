(import (tuna) (tuna plugins) (document) (web))
(use-plugin layout)
(use-plugin layout-split)
(use-plugin editing)
(use-plugin docs-at-point
  (config
    (set-option! docs-at-point:delay 0.05)))

(define client (web:add-client! 1))

(define (press! . keys)
  (for-each
    (lambda (key)
      (parameterize ([web:current-client client])
        (views:call-with-view (layout:selected-view) (lambda () (keys:press! client key)))))
    keys))

(define (view) (layout:selected-view))

(define (wait-until done?)
  (let loop ([n 0])
    (unless (or (done?) (= n 300))
      (sleep-for 0.01)
      (loop (+ n 1)))))

(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c) (condition-message c) c))])
    (thunk)))

;; Each call of a display, as the view's number, the docs' texts and
;; whether the user asked.
(define shown '())
(define (note-display view docs asked?)
  (set! shown (cons (list (views:id view) (map docs-at-point:doc-text docs) asked?) shown)))
(add-hook! docs-at-point:displays note-display)
(define (displayed) (let ([s (reverse shown)]) (set! shown '()) s))

(define notes (buffers:make "notes" "one two\nthree\n"))
(layout:switch-to-buffer notes)
(set-idle! #t)
(import (console))

(import (tuna) (test) (test-user) (test-runner) (options) (timers) (buffers) (views) (layout) (layout-split) (pulse) (jump-history-test))

(define pulsed jump-history-test:pulsed)

(define top (layout:selected-view))

(layout:switch-to-buffer (buffers:make "top" "one\ntwo\n"))

(define bottom (layout-split:display-below (buffers:make "bottom" "three\nfour\n")))

(test "a mark is drawn in the one view given, and a mark in another view ends it"
  (pulse:highlight! top '((1 3)))
  (check-equal? '(("on") ()) (list (pulsed top) (pulsed bottom)))
  (pulse:highlight! bottom '((1 3) (7 9)))
  (check-equal? '(() ("th" "fo")) (list (pulsed top) (pulsed bottom))))

(test "a mark goes after pulse:duration, and an earlier mark's timer does not end a later one"
  (options:set! pulse:duration 0.3)
  (pulse:highlight! top '((1 3)))
  ;; The claim is about time: the first mark's timer fires 0.3 s after
  ;; it, while the second mark has 0.1 s left.
  (timers:sleep 0.2)
  (pulse:highlight! bottom '((1 3)))
  (timers:sleep 0.2)
  (check-equal? '("th") (pulsed bottom))
  (test-runner:wait-until (lambda () (null? (pulsed bottom))))
  (options:unset! pulse:duration))

(test "empty ranges mark nothing, and a range outside the buffer raises"
  (pulse:highlight! top '((2 2)))
  (check-equal? '() (pulsed top))
  (check-raises assertion-violation? (pulse:highlight! top '((1 99)))))

(test "a line's range runs from its indentation to its end; a line of only spaces, or an empty one, from its start through its line break"
  (let ([b (buffers:make "blanks" "a\n   \n\nb\n  c d\n")])
    (views:set-buffer! top b)
    (check-equal? '((3 7) (7 8) (12 15))
      (map (lambda (p) (views:set-point! top p) (car (pulse:line-ranges top))) '(4 7 12)))
    (pulse:highlight-line! top)
    (check-equal? '("c d") (pulsed top))))

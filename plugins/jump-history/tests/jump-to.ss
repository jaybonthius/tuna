(import (tuna) (test) (test-user) (hooks) (buffers) (views) (layout) (layout-split) (editing) (jump-history) (jump-history-test))

(define first (buffers:make "first" "one\ntwo\nthree\n"))
(define fifth (buffers:make "fifth" "seven\neight\n"))
(define sixth (buffers:make "sixth" "nine\n"))
(define indented (buffers:make "indented" "  ten\neleven\n"))

(define (here) (let ([v (jump-history-test:view)]) (cons (buffers:name (views:buffer v)) (views:point v))))

(define (newest) (let ([p (car (jump-history:places))]) (cons (buffers:name (car p)) (cdr p))))

(define (raised-by? message)
  (lambda (c) (and (assertion-violation? c) (eq? 'jump-history:jump-to (condition-who c)) (string=? message (condition-message c)))))

(layout:switch-to-buffer first)
(views:set-point! (jump-history-test:view) 2)

(define top (jump-history-test:view))
(define bottom (layout-split:display-below fifth))
(views:set-point! bottom 1)

(test "jump-to a buffer another view shows goes there and selects it, recording the place that view leaves"
  (layout:select! top)
  (let* ([reached '()] [note (lambda (v) (set! reached (cons v reached)))])
    (hooks:add! jump-history:after-jump note)
    (jump-history:jump-to fifth 6)
    (hooks:remove! jump-history:after-jump note)
    (check-equal? (list #t '("fifth" . 6) #t '("fifth" . 1) (list bottom))
                  (list (eq? (jump-history-test:view) bottom) (here) (eq? (views:buffer top) first) (newest) reached))))

(test "jump-to another buffer goes there in the selected view, recording the place it leaves, and marks the line"
  (jump-history:jump-to sixth 2)
  (check-equal? (list #t '("sixth" . 2) '("fifth" . 6) '("nine"))
                (list (eq? (jump-history-test:view) bottom) (here) (newest) (jump-history-test:pulsed bottom))))

(test "a jump marks its ranges; with none, the line from its indentation; an empty list marks nothing"
  (jump-history:jump-to indented 4 '((4 6)))
  (check-equal? '("en") (jump-history-test:pulsed (jump-history-test:view)))
  (jump-history:jump-to indented 4)
  (check-equal? '("ten") (jump-history-test:pulsed (jump-history-test:view)))
  (jump-history:jump-to indented 4 '())
  (check-equal? '() (jump-history-test:pulsed (jump-history-test:view))))

(test "jump-to raises for a position or ranges outside the buffer before anything moves"
  (let ([before (here)])
    (check-raises (raised-by? "not a position in the buffer") (jump-history:jump-to sixth 99))
    (check-raises (raised-by? "not a list of ranges in the buffer") (jump-history:jump-to indented 4 '(5)))
    (check-raises (raised-by? "not a list of ranges in the buffer") (jump-history:jump-to indented 4 '((4 99))))
    (check-raises (raised-by? "not a buffer") (jump-history:jump-to "indented" 4))
    (check-equal? before (here))))

(test "jump-history:place-ranges holds #f or a list of ranges, and raises for anything else"
  (check-equal? #f (jump-history:place-ranges))
  (check-equal? '((1 3)) (parameterize ([jump-history:place-ranges '((1 3))]) (jump-history:place-ranges)))
  (check-raises assertion-violation? (jump-history:place-ranges '(1 3))))

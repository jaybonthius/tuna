(import (tuna) (test) (test-user) (views) (terminal) (terminal-test) (views-test page))

(define desktop (views-test/page:open 200))
(define phone (views-test/page:open 100))

(define (measure! page columns rows)
  (views-test/page:report! page (terminal-test:view) 1 0 #t (cons "columns" columns) (cons "rows" rows)))

(define (body-size page) (call-with-values (lambda () (views:body-size (terminal-test:view) (views-test/page:client page))) list))

(define (fit-size t page) (call-with-values (lambda () (terminal:fit-size t (views-test/page:client page))) list))

(define (type-from! page) (test-user:press! (views-test/page:client page) "SPC DEL"))

(define t (terminal-test:shell!))

(define asked 0)

;; Each answer is numbered, so an earlier one on the screen is not taken
;; for it.
(define (size-now expected)
  (set! asked (+ asked 1))
  (terminal:send! t (format "clear; echo size ~a $(stty size)\r" asked))
  (terminal-test:wait-for t (format "size ~a ~a\n" asked expected)))

(test "a terminal's size is the smallest view showing it on the device whose input reached it last"
  (size-now "24 80")
  (terminal-test:show! t)
  (measure! desktop 40 10)
  (check-equal? '(40 10) (body-size desktop))
  (check-equal? '(40 10) (fit-size t desktop)))

(test "until the device sends the terminal input its size stays; then the terminal takes it"
  (size-now "24 80")
  (type-from! desktop)
  (size-now "10 40"))

(test "the plugin asks again when one of that device's views changes size"
  (measure! desktop 60 15)
  (size-now "15 60")
  (check-equal? '(60 15) (fit-size t desktop)))

(test "a user who wants another rule changes terminal:fit-size"
  (let ([fixed (lambda (fit terminal client) (values 30 12))])
    (advice-add! terminal:fit-size fixed)
    (measure! desktop 61 15)
    (size-now "12 30")
    (advice-remove! terminal:fit-size fixed)
    (type-from! desktop)
    (size-now "15 61")))

(test "another device showing the terminal on a narrower view changes nothing until its input reaches the terminal"
  (measure! phone 20 5)
  (check-equal? '(20 5) (body-size phone))
  (size-now "15 61")
  (type-from! phone)
  (size-now "5 20"))

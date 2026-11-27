(import (tuna) (test) (test-runner) (test-user) (options) (hooks) (buffers) (document) (terminal) (terminal-test))

(define (text-lines t) (terminal-test:lines (terminal-test:text t)))

(test "a program that floods output loses no row, and the scrollback keeps terminal:scrollback-lines lines"
  (let ([t (terminal-test:shell!)])
    (terminal:send! t "seq 1 300000; echo done\r")
    (terminal-test:wait-for t "\n300000\ndone\n$ ")
    (let* ([all (text-lines t)] [numbers (map string->number (list-head all 10021))])
      (check-equal? 10024 (length all))
      (check-equal? '(289979 299999) (list (car numbers) (list-ref numbers 10020)))
      (check (let loop ([ns numbers]) (or (null? (cdr ns)) (and (= (+ (car ns) 1) (cadr ns)) (loop (cdr ns)))))))
    (terminal-test:show! t)
    (terminal:send! t "yes flood\r")
    (terminal-test:wait-for t "flood\nflood\nflood\n")
    (test-user:press! "C-c C-c")
    (test-runner:wait-until (lambda () (equal? "$ " (car (reverse (terminal-test:screen-lines t))))))
    (check-equal? 10024 (length (text-lines t)))
    (terminal:send! t "printf 'w%.0s' $(seq 1 200); echo; seq 1 30\r")
    (terminal-test:wait-for t "\n30\n$ ")
    (check-equal? '(200)
                  (map string-length (filter (lambda (l) (and (> (string-length l) 0) (char=? (string-ref l 0) #\w))) (text-lines t))))
    (buffers:kill! t)))

(test "a change of scrollback-lines trims the scrollback of running terminals at once"
  (let ([t (terminal-test:shell!)])
    (terminal:send! t "seq 1 500\r")
    (terminal-test:wait-for t "\n500\n$ ")
    (check-equal? 502 (length (text-lines t)))
    (options:set! terminal:scrollback-lines 100)
    (check-equal? '(124 "378") (let ([ls (text-lines t)]) (list (length ls) (car ls))))
    (terminal:send! t "seq 501 700\r")
    (terminal-test:wait-for t "\n700\n$ ")
    (check-equal? '(124 "578") (let ([ls (text-lines t)]) (list (length ls) (car ls))))
    (buffers:kill! t)))

;; The line goes before the rows copied after it, at least as many as the
;; scrollback keeps, so the buffer's limit trims it in the same write.
(test "rows that libghostty pruned before the plugin copied them leave a line in the scrollback"
  (let ([t (terminal-test:shell!)] [written '()])
    (hooks:add! buffers:after-edit
      (lambda (b e)
        (when (eq? b t)
          (set! written (cons (document:text (buffers:piece-document (buffers:edit-inserted e))) written)))))
    (terminal:send! t "yes '' | head -n 6000; echo after\r")
    (terminal-test:wait-for t "\nafter\n$ ")
    (check (exists (lambda (w) (terminal-test:index-of w "[Output was lost here.]")) written))))

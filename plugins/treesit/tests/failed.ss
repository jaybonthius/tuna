(import (tuna) (test) (test-runner) (test-user) (tables) (options) (buffers) (views) (web) (layout) (modes)
        (syntax-highlighting) (treesit) (python) (views-test page) (buffers-test) (syntax-highlighting-test) (treesit-test) (treesit-test grammar))

(define python (tables:ref treesit:grammars "python" #f))
(treesit-test/grammar:build-python! (treesit:grammar-commit python) (treesit:grammar-file python))

(options:set! views:scroll-margin 2 views:wrap-lines #f)

(web:close-client! (test-user:client))

(define desktop (views-test/page:open 400))

(define v (layout:selected-view))

(define b (buffers:make "bad.py" (treesit-test:grown-text 60000)))

(define (scroll! top) (views-test/page:report! desktop v top 0 #t))

(define (reported thunk)
  (map (lambda (c) (list (condition-who c) (condition-message c))) (test-runner:reports-during thunk)))

(test "a buffer whose input raises is reported once, and a scroll starts no failed job again"
  (tables:set! treesit:grammars "python" "python")
  (check-equal? '((treesit:grammars "not a grammar"))
                (syntax-highlighting-test:reports-until 1
                  (lambda ()
                    (views:set-buffer! v b)
                    (modes:set-major-mode python:mode b))))
  (check-equal? '() (reported (lambda () (scroll! 300) (scroll! 600) (scroll! 603))))
  (check-equal? '((564 661)) (map (lambda (r) (treesit-test:lines-of b r)) (views:drawn-ranges v)))
  (check-equal? '() (treesit-test:spans b))
  (check-equal? '() (treesit-test:job-events)))

(test "fixing the cause and calling update! colours the buffer"
  (tables:set! treesit:grammars "python" python)
  (syntax-highlighting:update! b)
  (test-runner:wait-until (lambda () (pair? (treesit-test:spans b))))
  (check-equal? '(start) (treesit-test:job-events)))

(test "a scroll reads the input of a running job again, so a grammar entry changed meanwhile reaches it, reported for that buffer once"
  (tables:set! treesit:grammars "python" "python")
  (check-equal? '((treesit:grammars "not a grammar")) (reported (lambda () (scroll! 900))))
  (check-equal? '() (reported (lambda () (scroll! 1200))))
  (check-equal? '() (treesit-test:spans b))
  (check-equal? '(stop) (treesit-test:job-events)))

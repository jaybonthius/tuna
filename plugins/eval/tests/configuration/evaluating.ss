(import (tuna) (test) (caught-reports) (test-user) (plugins) (files) (modes) (buffers) (echo-area) (chez-scheme) (eval) (eval-test))

(define (message) (echo-area:current-message))

(define init-path (eval-test:home-path ".config/tuna/init.ss"))

(define (flag! name) (call-with-output-file (eval-test:home-path name) (lambda (p) (void)) 'replace))

(define (unflag! name) (delete-file (eval-test:home-path name)))

(define (evaluated-init)
  (let* ([shown #f] [reports (caught-reports:during (lambda () (set! shown (eval-test:after-message (lambda () (test-user:press! "C-c C-k"))))))])
    (values shown reports)))

(test "the configuration's file is read again by a new owner of its name, and text with its path evaluates as that owner"
  (let ([before (plugins:configuration-owner)])
    (eval:eval-file "~/.config/tuna/init.ss")
    (let ([after (plugins:configuration-owner)])
      (check-equal? (list #f #t #t) (list (owner-live? before) (owner-live? after) (equal? (owner-name before) (owner-name after))))))
  (eval:eval-text "(define configured (current-owner))" "~/.config/tuna/init.ss")
  (check-equal? (plugins:configuration-owner) (eval:eval-text "configured")))

(define init (eval-test:show! (files:visit init-path)))

(test "C-c C-k in the configuration's file takes back its changes and runs it again, and says so when nothing was reported"
  (check-equal? chez-scheme:mode (modes:major-mode init))
  (let-values ([(shown reports) (evaluated-init)])
    (check-equal? '("Evaluated the init.ss buffer" ()) (list shown reports))))

(test "a form that raises is reported and the forms after it still run, as at start; the report shows, with no Evaluated line"
  (flag! "fail")
  (eval:eval-text "(set! after-fail 'not-yet)")
  (let-values ([(shown reports) (evaluated-init)])
    (check-equal? "1 is not a pair" shown)
    (check-equal? '(car) (map condition-who reports)))
  (check-equal? 'ran (eval:eval-text "after-fail"))
  (unflag! "fail"))

(test "a warning alone shows too, and no Evaluated line covers it"
  (flag! "warn")
  (let-values ([(shown reports) (evaluated-init)])
    (check-equal? '("only a warning" (#t)) (list shown (map warning? reports)))
    (check-equal? 'warning (echo-area:current-face)))
  (unflag! "warn"))

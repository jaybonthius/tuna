(import (test) (test-runner))

(define home (string-append (getenv "HOME") "/restarted"))

(define (passes file)
  (let-values ([(status errors) (test-runner:run-file file home)])
    (check-equal? 0 status)
    (check-equal? "" errors)))

(define (names-echo-area? datum)
  (cond
    [(string? datum) (string=? datum " *Echo Area*")]
    [(pair? datum) (or (names-echo-area? (car datum)) (names-echo-area? (cdr datum)))]
    [(vector? datum) (names-echo-area? (vector->list datum))]
    [else #f]))

(test "the plugin removes its part when it unloads at exit, so the layout is saved without it and a restart shows one echo area"
  (passes "restart/first.ss")
  (let ([saved (string-append home "/.local/share/tuna/saved/tuna/layout/saved-layout.ss")])
    (check (file-exists? saved))
    (check-equal? #f (names-echo-area? (call-with-input-file saved read))))
  (passes "restart/second.ss"))

(import (tuna) (test) (plugins) (fixtures))

(define (lib-file name) (fixtures:home-path ".config" "tuna" "lib" (string-append name ".sls")))

(define (raised form) (guard (c [(condition? c) c]) (fixtures:at-repl form) #f))

(fixtures:write-file! (lib-file "syntax-error")
  "(library (syntax-error)\n  (export f)\n  (import (chezscheme))\n  (define (f) (let ((x)) x)))\n")
(fixtures:write-file! (lib-file "unknown-language")
  "#!lang/nope\n(library (unknown-language)\n  (export)\n  (import (chezscheme)))\n")
(fixtures:write-file! (lib-file "argument-count")
  "(library (argument-count)\n  (export h)\n  (import (chezscheme))\n  (define (g x) x)\n  (define (h) (g 1 2)))\n")

(test "a library that does not compile raises with the place in its file"
  (let ([c (raised '(import (syntax-error)))])
    (check (syntax-violation? c))
    (check-equal? (list (lib-file "syntax-error") 4 15) (fixtures:reported-position c))))

(test "a library in an unknown language raises naming the language, with the place of its language line"
  (let ([c (raised '(import (unknown-language)))])
    (check-equal? 'read-language (condition-who c))
    (check-equal? (list (lib-file "unknown-language") 1 3) (fixtures:reported-position c))))

(test "a compile warning raised twice, as Chez's source optimizer runs twice, is reported once, and the library loads"
  (let ([reports (fixtures:reports-during (lambda () (fixtures:load-configuration! '((import (tuna) (argument-count))))))])
    (check-equal? '(compile) (map condition-who reports))
    (check (warning? (car reports))))
  (check (fixtures:at-repl '(procedure? h))))

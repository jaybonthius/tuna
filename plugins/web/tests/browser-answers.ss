(import (tuna) (test) (test-browser) (test-user) (test-runner) (web) (tables))

(define (home-file path) (string-append (getenv "HOME") "/.config/tuna/" path))

(call-with-output-file (home-file "asker.js")
  (lambda (p)
    (put-string p "import { define } from \"tuna\";\nimport { shared } from \"shared\";\n\n")
    (put-string p "define(\"shared\", () => shared);\n")
    (put-string p "define(\"at-once\", (n) => n + 1);\n")
    (put-string p "define(\"later\", (n) => new Promise((resolve) => setTimeout(() => resolve(n + 1), 50)));\n")
    (put-string p "define(\"refused\", () => Promise.reject(new Error(\"no\")));\n"))
  'replace)

(call-with-output-file (home-file "shared.js") (lambda (p) (put-string p "export const shared = 7;\n")) 'replace)

(tables:set! web:scripts 'asker "asker.js")
(tables:set! web:scripts 'shared "shared.js")
(test-runner:wait-for-batch)

(define page (test-browser:open))

(define client (find (lambda (c) (not (eq? c (test-user:client)))) (web:clients)))

(test "a page procedure's value is the answer"
  (check-equal? 42 (web:ask-page client "at-once" 41)))

(test "a page procedure that returns a promise answers when the promise settles"
  (check-equal? 42 (web:ask-page client "later" 41)))

(test "a promise that rejects answers null"
  (check-equal? 'null (web:ask-page client "refused" 0)))

(test "a page module imports another module of web:scripts by its name"
  (check-equal? 7 (web:ask-page client "shared" #f)))

(test "a script named as a module of the page's own is reported and left out"
  (check-equal? '((web:scripts "the name of a module of the page's own" (tuna)))
                (map (lambda (c) (list (condition-who c) (condition-message c) (condition-irritants c)))
                     (test-runner:reports-during
                       (lambda ()
                         (tables:set! web:scripts 'tuna "shared.js")
                         (test-runner:wait-for-batch)))))
  (tables:remove! web:scripts 'tuna)
  (test-runner:wait-for-batch)
  (check-equal? 7 (web:ask-page client "shared" #f)))

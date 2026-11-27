(import (test) (test-runner))

(define (write-file! path text)
  (let make ([folder (path-parent path)])
    (unless (file-directory? folder) (make (path-parent folder)) (mkdir folder)))
  (call-with-output-file path (lambda (p) (put-string p text)) 'replace))

(test "a worker imports a plain library that an installed plugin holds beside its modules"
  (let* ([home (string-append (getenv "HOME") "/installed")] [plugin (string-append home "/src/fuzzy/src")])
    (test-runner:make-home! home "local-plugin/init.ss")
    (write-file! (string-append plugin "/fuzzy.sls")
      "#!tuna\n(import (jobs))\n\n(jobs:define-worker (match-names query emit)\n  (import (fuzzy match))\n  (emit (score query)))\n")
    (write-file! (string-append plugin "/fuzzy/match.sls")
      "(library (fuzzy match)\n  (export score)\n  (import (chezscheme))\n  (define (score s) (string-length s)))\n")
    (let-values ([(status errors) (test-runner:run-file "local-plugin/match.ss" home)])
      (check-equal? 0 status)
      (check-equal? "" errors))))

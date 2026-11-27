(import (test) (test-runner))

(define home (string-append (getenv "HOME") "/restarted"))

(define saved-file (string-append home "/.local/share/tuna/saved/tuna/kill-ring/texts.ss"))

(define (passes file)
  (let-values ([(status errors) (test-runner:run-file file home)])
    (check-equal? 0 status)
    (check-equal? "" errors)))

(test "the ring's text outlives a restart, and the ring starts with the yank pointer at the newest entry"
  (passes "restart/first.ss")
  (check-equal? '(("newest") ("Hello there" "two!") ("first")) (call-with-input-file saved-file read))
  (passes "restart/second.ss"))

(test "a saved text that fails its check is set aside with a warning, and the ring starts empty"
  (call-with-output-file saved-file (lambda (p) (write '(("ok") (1)) p)) 'replace)
  (passes "restart/rejected.ss")
  (check (file-exists? (string-append saved-file ".rejected"))))

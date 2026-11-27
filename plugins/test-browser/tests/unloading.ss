(import (tuna) (test) (test-browser) (test-runner) (processes))

(define profile (string-append (getenv "HOME") "/chromium"))

(define (browser-running?)
  (let-values ([(status output errors) (processes:run "pgrep" (list "-f" "--" (string-append "--user-data-dir=" profile)))])
    (eqv? status 0)))

(test "the browser runs with its profile in the test's home, and ends when test-browser unloads"
  (test-browser:open)
  (check (browser-running?))
  (check (file-directory? profile))
  (unload-owner! (module-owner '(test-browser)))
  (check (not (browser-running?))))

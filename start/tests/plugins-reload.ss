(import (tuna) (test) (test-runner) (processes) (fixtures))

(test "a reload of the plugin manager ends the task that asked for it and reads the configuration again, whose settings hold"
  (let ([home (fixtures:home-path "reloaded")])
    (test-runner:make-home! home)
    (fixtures:write-file! (string-append home "/.config/tuna/lib/settings.sls")
      (fixtures:module-text '((import (options)) (options:define-option confirm? #f boolean?))))
    (fixtures:write-file! (string-append home "/.config/tuna/init.ss")
      (fixtures:forms-text
        '((import (tuna) (plugins) (options) (timers) (settings))
          (use-plugin kill-ring)
          (options:set! settings:confirm? #t)
          (let* ([reads (string-append (getenv "HOME") "/reads")]
                 [n (if (file-exists? reads) (call-with-input-file reads read) 0)])
            (call-with-output-file reads (lambda (p) (write (+ n 1) p)) 'replace)
            (timers:run-after 0.2
              (if (= n 0)
                  (lambda () (reload-modules! '((plugins))))
                  (lambda ()
                    (call-with-output-file (string-append (getenv "HOME") "/seen") (lambda (p) (write (settings:confirm?) p)) 'replace)
                    (exit))))))))
    (let-values ([(status output errors)
                  (processes:run "timeout" (list "60" (car (command-line))) #f
                    (processes:options [directory home] [environment (test-runner:home-environment home)] [separate-stderr #t]))])
      (check-equal? 0 status)
      (check-equal? "" (utf8->string errors))
      (check-equal? 2 (call-with-input-file (string-append home "/reads") read))
      (check-equal? #t (call-with-input-file (string-append home "/seen") read)))))

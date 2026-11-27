(import (tuna) (test) (test-runner))

(test "a shell's terminal outlasts a restart, and only its screen is kept"
  (let ([home (string-append (getenv "HOME") "/restarted")])
    (test-runner:make-home! home "restart/init.ss")
    (for-each
      (lambda (file)
        (let-values ([(status errors) (test-runner:run-file file home)])
          (check-equal? 0 status)
          (check-equal? "" errors)))
      '("restart/first.ss" "restart/second.ss"))
    (let* ([root (string-append home "/.local/share/tuna/terminal")] [folders (directory-list root)])
      (check-equal? 1 (length folders))
      (check-equal? 1 (length (directory-list (string-append root "/" (car folders))))))))

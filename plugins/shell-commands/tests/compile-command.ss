(import (tuna) (test) (buffers) (layout) (options) (shell-commands) (shell-commands-test))

(define run shell-commands-test:run)

(define (compilation) (buffers:find "*compilation*"))

(define ended shell-commands-test:ended)

(define output shell-commands-test:output)

(advice-add! shell-commands:save-buffers (lambda (next) (void)))

(test "compile sets compile-command where its value came from: a buffer's own value, even one equal to the setting"
  (let ([own (buffers:make "own" "text\n")])
    (buffers:with-buffer own (options:set-local! shell-commands:compile-command (options:setting shell-commands:compile-command)))
    (layout:switch-to-buffer own)
    (run shell-commands:compile "echo first")
    (ended (compilation))
    (check-equal? '("make -k " (#t "echo first"))
                  (list (options:setting shell-commands:compile-command)
                        (buffers:with-buffer own (list (options:local? shell-commands:compile-command) (shell-commands:compile-command)))))))

(test "under options:with compile sets nothing, since the binding would drop it; else it sets the setting"
  (let ([plain (buffers:make "plain" "text\n")])
    (layout:switch-to-buffer plain)
    (options:with ([shell-commands:compile-command "echo bound"])
      (run shell-commands:compile "echo second"))
    (ended (compilation))
    (check-equal? "second" (output (compilation)))
    (check-equal? '("make -k " (#f "make -k ") #f)
                  (list (options:setting shell-commands:compile-command)
                        (buffers:with-buffer plain (list (options:local? shell-commands:compile-command) (shell-commands:compile-command)))
                        (buffers:with-buffer (compilation) (options:local? shell-commands:compile-command))))
    (run shell-commands:compile "echo third")
    (ended (compilation))
    (check-equal? '("echo third" #f "echo first")
                  (list (options:setting shell-commands:compile-command)
                        (buffers:with-buffer plain (options:local? shell-commands:compile-command))
                        (buffers:with-buffer (buffers:find "own") (shell-commands:compile-command))))))

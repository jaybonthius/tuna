(import (test) (test-runner))

(define (passes configuration file name)
  (let ([home (string-append (getenv "HOME") "/" name)])
    (test-runner:make-home! home configuration)
    (let-values ([(status errors) (test-runner:run-file file home)])
      (check-equal? 0 status)
      (check-equal? "" errors))))

(test "the configuration's setting of buffers:revert-function wins over files' global value, across files' reload"
  (passes "configuration/setting.ss" "configuration/setting-wins.ss" "setting"))

(test "an unload of files takes its value back, and the configuration loads files again"
  (passes "configuration/plain.ss" "configuration/unloaded.ss" "plain"))

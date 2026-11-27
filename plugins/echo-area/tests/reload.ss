(import (tuna) (test))

;; A form of its own, so it loads before echo-area.
(import (echo-area-test beneath))

(import (test-user) (layout) (buffers) (keys) (editing) (echo-area) (echo-area-test))

(define echo-buffer (echo-area-test:echo-buffer))

(define (echo-parts) (filter (lambda (attributes) (equal? " *Echo Area*" (cdr (assq 'buffer attributes)))) (echo-area-test:layout-atoms)))

(test "unloading the plugin removes its part and keeps both buffers; a new instance places it again, keeping the log and the message"
  (echo-area:message! "Kept")
  (unload-owner! (module-owner '(echo-area)))
  (check-equal? '() (echo-parts))
  (check-equal? '(" *Echo Area*" "*Messages*")
    (map buffers:name (filter (lambda (b) (member (buffers:name b) '(" *Echo Area*" "*Messages*"))) (buffers:all))))
  (load-module! '(echo-area))
  (check-equal? 1 (length (echo-parts)))
  (check-equal? '("Kept" "Kept\n") (list (echo-area:current-message) (echo-area-test:messages)))
  (check (eq? echo-buffer (buffers:find " *Echo Area*"))))

(test "reloading it does the same, and the count of an equal message, read from the log, goes on"
  (reload-modules! '((echo-area)))
  (check-equal? 1 (length (echo-parts)))
  (check-equal? '("Kept" "Kept\n") (list (echo-area:current-message) (echo-area-test:messages)))
  (echo-area:message! "Kept")
  (check-equal? "Kept [2 times]\n" (echo-area-test:messages)))

(test "its advice and bindings came back with it"
  (check-equal? '(car) (map condition-who (echo-area-test:reports-during (lambda () (spawn-task (lambda (restore) (car '()))) (test-user:settle)))))
  (check-equal? "() is not a pair" (echo-area:current-message))
  (check-equal? '("end of buffer") (map condition-message (echo-area-test:reports-during (lambda () (test-user:press! "C-f")))))
  (check-equal? "end of buffer" (echo-area:current-message))
  (check (eq? echo-area:show-messages (keys:lookup (test-user:client) "C-h e"))))

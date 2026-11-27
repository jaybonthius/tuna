(import (tuna) (test) (test-user) (keys) (commands) (options))

(define read-key #f)

(commands:define-command (read-one)
  "Reads a key and keeps it."
  (set! read-key (keys:read-key)))

(keys:bind! keys:global "C-c r" read-one)

(test "keys:page-quit-keys gives the quit keys, and none while a command of the client reads a key"
  (check-equal? '("C-g" "ESC") (keys:page-quit-keys (test-user:client)))
  (options:with ([keys:quit-keys '("C-g")])
    (check-equal? '("C-g") (keys:page-quit-keys (test-user:client))))
  (test-user:press! "C-c r")
  (check-equal? '() (keys:page-quit-keys (test-user:client)))
  (test-user:press! "C-g")
  (check-equal? "C-g" read-key)
  (check-equal? '("C-g" "ESC") (keys:page-quit-keys (test-user:client))))

(test "keys:page-quit-keys takes a client"
  (check-raises (lambda (e) (and (who-condition? e) (eq? 'keys:page-quit-keys (condition-who e))))
    (keys:page-quit-keys 'client)))

(import (tuna) (testing) (tuna plugins) (document))
;; ask's own writer raises each message as a warning, whose handler runs
;; outside the guards of the code that said it; the tests keep the
;; messages to read them.
(define said '())
(use-plugin ask
  (config
    (set-option! ask:message-writer (lambda (text) (set! said (cons text said))))))
(define (take-said!) (let ([s (reverse said)]) (set! said '()) s))
(use-plugin files
  (config
    (set-option! files:require-final-newline #t)))
(import (disk-checks) (buffers))

(when (equal? (getenv "TRANSCRIPT") "revert-setting")
  (set-option! buffers:revert-function files:not-modified))

(define (text b) (document:text (buffers:document b)))

(import (console))

#!tuna
(import (processes))


;; A server is not Tuna's to ship, but a test that needs one fails without
;; it, so a machine missing it shows a failure rather than a pass.
(define (require-programs! programs)
  (for-each
    (lambda (program)
      (unless (processes:program-path program)
        (error 'lsp-test/installed:require-programs! "not installed, which this test needs" program)))
    programs))

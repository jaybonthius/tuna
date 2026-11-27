(import (tuna) (test) (modes) (buffers) (hooks) (tables) (modes-test text) (modes-test fill))

(define (column b) (buffers:with-buffer b (modes-test/fill:column)))

(test "modes the configuration defines are named as written"
  (check-equal? 'spelling (modes:name (getprop 'modes-test 'spelling)))
  (check (hooks:hook? (tables:ref modes:hooks 'notes-mode #f)))
  (check-equal? '(notes-mode modes-test/text:mode) (modes:ancestry 'notes-mode)))

(test "the configuration's lighter wins over the defining module's, also once that module reloads"
  (check-equal? "Tx" (modes:lighter modes-test/text:mode))
  (reload-modules! '((modes-test text)))
  (check-equal? "Tx" (modes:lighter modes-test/text:mode)))

(test "after the configuration is read again, the mode hooks run again, so its local values come back"
  (let ([b (buffers:make "notes" "x")])
    (modes:set-major-mode modes-test/text:mode b)
    (check-equal? 33 (column b))
    (reload-modules! '((modes-test text)))
    (check-equal? 33 (column b))
    (reload-modules! '((modes-test fill)))
    (check-equal? 33 (column b))))

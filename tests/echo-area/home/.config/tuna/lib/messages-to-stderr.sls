#!tuna
(import (echo-area) (faces))

(define (also-to-stderr message format-string . vs)
  (apply message format-string vs)
  (let ([text (echo-area:current-message)])
    (when text
      (fprintf (console-error-port) "~a~a\n"
        (if (eq? (echo-area:face) faces:error) "error: " "")
        text))))

(advice-add! echo-area:message! also-to-stderr)

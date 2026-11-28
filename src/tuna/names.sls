(library (tuna names)
  (export module-name? prefixed-symbol)
  (import (chezscheme))

  (define (module-name? x)
    (and (pair? x) (list? x) (for-all symbol? x)))

  (define (prefixed-symbol module name)
    (string->symbol
      (call-with-string-output-port
        (lambda (p)
          (let loop ([parts module])
            (display (car parts) p)
            (unless (null? (cdr parts))
              (put-char p #\/)
              (loop (cdr parts))))
          (put-char p #\:)
          (display name p))))))

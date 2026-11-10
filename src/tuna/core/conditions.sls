(library (tuna core conditions)
  (export condition-text write-condition warning-only?)
  (import (chezscheme))

  (define (warning-only? c)
    (and (warning? c) (not (serious-condition? c))))

  (define (message-text c)
    (let ([message (condition-message c)]
          [irritants (if (irritants-condition? c) (condition-irritants c) '())])
      (or (and (format-condition? c)
               (guard (e [#t #f]) (apply format message irritants)))
          (case (and (list? irritants) (length irritants))
            [(0) (format "~a" message)]
            [(1) (format "~a with irritant ~s" message (car irritants))]
            [else (format "~a with irritants ~s" message irritants)]))))

  ;; A form can be a whole library body; Chez's own report cuts it short the
  ;; same way.
  (define (form-text form)
    (parameterize ([print-level 3] [print-length 6])
      (format " ~s" (syntax->datum form))))

  (define (position-text form)
    (let ([a (syntax->annotation form)])
      (and a
           (let ([src (annotation-source a)])
             (call-with-values
               (lambda () (locate-source-object-source src #t #t))
               (case-lambda
                 [(path line char) (format " at line ~a, char ~a of ~a" line char path)]
                 [() (format " at char ~a of ~a" (source-object-bfp src)
                       (source-file-descriptor-path (source-object-sfd src)))]))))))

  (define (source-text c)
    (cond
      [(source-condition? c)
       (let ([form (source-condition-form c)])
         (string-append (form-text form) (or (position-text form) "")))]
      [(syntax-violation? c)
       (let ([form (syntax-violation-form c)] [subform (syntax-violation-subform c)])
         (string-append
           (if subform
               (string-append (form-text subform) " in" (form-text form))
               (form-text form))
           (or (and subform (position-text subform)) (position-text form) "")))]
      [else ""]))

  (define (raw-condition-text c)
    (cond
      [(not (condition? c)) (format "non-condition value ~s" c)]
      [(message-condition? c)
       (string-append
         (if (who-condition? c) (format "~a: " (condition-who c)) "")
         (message-text c)
         (source-text c))]
      [else (call-with-string-output-port (lambda (p) (display-condition c p)))]))

  ;; A condition's irritants or a record's writer can raise, and the caller
  ;; is often the code that reports a raise.
  (define (condition-text c)
    (guard (e [#t "condition that cannot be printed"])
      (raw-condition-text c)))

  ;; Standard output is flushed first, so that text written before the raise
  ;; comes before the report when both streams go to one file.
  (define (write-condition c)
    (let ([out (current-output-port)] [err (console-error-port)])
      (fresh-line out)
      (flush-output-port out)
      (fprintf err "! ~a\n" (condition-text c))
      (flush-output-port err))))

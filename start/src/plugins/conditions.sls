(library (plugins conditions)
  (export condition-text)
  (import (chezscheme))

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

  ;; Chez's display-condition lists a condition without a message over
  ;; several lines; a report is one line, so the types stand in for it.
  (define (types-text c)
    (format "~{~a~^ ~}"
      (append
        (map (lambda (simple) (record-type-name (record-rtd simple)))
             (remp (lambda (simple)
                     (or (who-condition? simple) (irritants-condition? simple) (source-condition? simple)))
                   (simple-conditions c)))
        (if (irritants-condition? c)
            (list (format "with irritants ~s" (condition-irritants c)))
            '()))))

  (define (raw-condition-text c)
    (cond
      [(not (condition? c)) (format "non-condition value ~s" c)]
      [else
       (string-append
         (if (who-condition? c) (format "~a: " (condition-who c)) "")
         (if (message-condition? c) (message-text c) (types-text c))
         (source-text c))]))

  ;; A condition's irritants or a record's writer can raise, and the caller
  ;; is often the code that reports a raise.
  (define (condition-text c)
    (guard (e [#t "condition that cannot be printed"])
      (parameterize ([print-graph #t])
        (raw-condition-text c)))))

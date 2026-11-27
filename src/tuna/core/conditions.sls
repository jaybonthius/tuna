(library (tuna core conditions)
  (export
    condition-text write-condition warning-only? call-with-only-handler
    &cancelled make-cancelled cancelled? cancelled-reason
    &unloaded make-unloaded unloaded? unloaded-owner)
  (import (chezscheme))

  ;; Both are raised into a task from outside, so a handler must be able to
  ;; tell them from an error; neither is the other, or a hook runner that
  ;; lets a cancel end the task would end it for a turned-off plugin's entry.
  (define-condition-type &cancelled &serious make-cancelled cancelled? (reason cancelled-reason))
  (define-condition-type &unloaded &serious make-unloaded unloaded? (owner unloaded-owner))

  ;; with-exception-handler runs its handler with the handlers outside it,
  ;; so a cancel landing while the handler reports a raise would escape to
  ;; them. The only handler of a fresh exception state takes the raises in
  ;; itself too.
  (define (call-with-only-handler handler thunk)
    (let ([state (create-exception-state handler)])
      (define (swap!)
        (let ([outer (current-exception-state)])
          (current-exception-state state)
          (set! state outer)))
      (dynamic-wind #t swap! thunk swap!)))

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
  ;; Printed with labels, so a cyclic irritant does not make the whole
  ;; report unprintable.
  (define (condition-text c)
    (guard (e [#t "condition that cannot be printed"])
      (parameterize ([print-graph #t])
        (raw-condition-text c))))

  ;; Standard output is flushed first, so that text written before the raise
  ;; comes before the report when both streams go to one file.
  (define (write-condition c module)
    (let ([out (current-output-port)] [err (console-error-port)])
      (fresh-line out)
      (flush-output-port out)
      (if module
          (fprintf err "! ~s ~a\n" module (condition-text c))
          (fprintf err "! ~a\n" (condition-text c)))
      (flush-output-port err))))

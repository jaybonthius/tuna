;;; A library, so that both bin/tuna.sps and the executable's boot file can
;;; run the program.
(library (tuna main)
  (export main)
  (import (chezscheme) (chez-lang loader) (tuna version))

  ;; Exit status 2 marks a usage error, as in most command-line programs.
  (define (main arguments)
    (cond
      [(null? arguments)
       (let ([home (getenv "HOME")])
         (unless home
           (fprintf (console-error-port) "tuna: HOME is not set\n")
           (exit 1))
         (start-console home))
       (repl)
       (exit 0)]
      [(equal? arguments '("--version"))
       (printf "tuna ~a\n" tuna-version)
       (exit 0)]
      [else
       (fprintf (console-error-port) "tuna: unknown arguments ~s\nusage: tuna [--version]\n"
         arguments)
       (exit 2)]))

  (define (start-console home)
    (install-loader!)
    (compile-file-message #f)
    (library-directories
      (list (cons (string-append home "/.config/tuna/lib")
                  (string-append home "/.cache/tuna/lib")))))

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

  (define (condition-text c)
    (cond
      [(not (condition? c)) (format "non-condition value ~s" c)]
      [(message-condition? c)
       (string-append
         (if (who-condition? c) (format "~a: " (condition-who c)) "")
         (message-text c)
         (source-text c))]
      [else (call-with-string-output-port (lambda (p) (display-condition c p)))]))

  ;; Printing runs outside the REPL's handler, where a raise would end Tuna,
  ;; and a condition's irritants or a record's writer can raise.
  (define (printable-text c)
    (guard (e [#t "condition that cannot be printed"])
      (condition-text c)))

  ;; Standard output is flushed first, so that text a form wrote before it
  ;; raised comes before the error when both streams go to one file.
  (define (print-error text)
    (let ([out (current-output-port)] [err (console-error-port)])
      (fresh-line out)
      (flush-output-port out)
      (fprintf err "! ~a\n" text)
      (flush-output-port err)))

  (define (print-values . results)
    (let ([out (current-output-port)])
      (for-each
        (lambda (v)
          (unless (eq? v (void))
            (fresh-line out)
            (write v out)
            (newline out)))
        results)
      (fresh-line out)
      (flush-output-port out)))

  (define (warning-only? c)
    (and (warning? c) (not (serious-condition? c))))

  ;; Chez runs its source optimizer twice by default, so one compile warning
  ;; can be raised twice; print each text once per form.
  (define (repl)
    (let ([warned '()])
      (unless (eof-object?
                (guard (c [#t (print-error (printable-text c))])
                  (with-exception-handler
                    (lambda (c)
                      (if (warning-only? c)
                          (let ([text (printable-text c)])
                            (unless (member text warned)
                              (set! warned (cons text warned))
                              (print-error text)))
                          (raise-continuable c)))
                    (lambda ()
                      (let ([form (read)])
                        (unless (eof-object? form)
                          (call-with-values (lambda () (eval form)) print-values))
                        form)))))
        (repl)))))

(library (tuna top-level)
  (export
    start-top-level!
    load-configuration!
    eval-top-level
    call-reporting
    eval-text)
  (import (chezscheme) (tuna core changes) (tuna core definitions) (tuna core modules)
          (tuna core conditions) (only (chez-lang body) definition-form? form-defined-names))

  (define home #f)
  (define configuration-file #f)
  (define repl-environment #f)
  (define check-keyword (gensym "check-top-level-form"))

  (define imported (make-hashtable equal-hash equal?))
  (define exporters (make-eq-hashtable))

  ;; Prefixed names defined at the top level, so that a module load that
  ;; replaces one can say so.
  (define top-level-definitions (make-eq-hashtable))

  (define (start-top-level! home-folder configuration)
    (set! home home-folder)
    (set! configuration-file configuration)
    (set! repl-environment (copy-environment (scheme-environment) #t))
    (define-top-level-syntax check-keyword check-top-level-form repl-environment))

  (define (prefixed? symbol)
    (let ([s (symbol->string symbol)])
      (let loop ([i 0])
        (and (fx< i (string-length s))
             (or (char=? (string-ref s i) #\:) (loop (fx+ i 1)))))))

  (define (definition-violation who symbol)
    (let ([module (hashtable-ref exporters symbol #f)])
      (raise
        (condition
          (make-violation)
          (make-who-condition who)
          (make-message-condition
            (if (changeable-symbol? symbol)
                (format "~s is ~s's definition; override it with (set! ~s value)" symbol module symbol)
                (format "~s is ~s's definition and cannot be defined again" symbol module)))))))

  (define (defined-names form lookup)
    (syntax-case form ()
      [(d . rest)
       (and (identifier? #'d) (free-identifier=? #'d #'define-public))
       (form-defined-names #'(define . rest) lookup)]
      [_ (if (definition-form? form lookup) (form-defined-names form lookup) '())]))

  (define (check-definition! form lookup)
    (for-each
      (lambda (id)
        (let ([symbol (syntax->datum id)])
          (when (hashtable-contains? exporters symbol)
            (definition-violation (syntax-case form () [(head . rest) (syntax->datum #'head)]) symbol))
          (when (prefixed? symbol)
            (hashtable-set! top-level-definitions symbol #t))))
      (defined-names form lookup)))

  ;; Chez's set! of an unbound name makes a variable, so a prefixed name set
  ;; before its module loads would silently miss the module. In a mutable
  ;; environment top-level-syntax? holds for every name, so a name defined
  ;; at the top level is known by the definition check. A module imported
  ;; earlier in the same form has not run yet, but its names are bound.
  (define (check-assignment! form lookup)
    (syntax-case form ()
      [(s id v)
       (and (identifier? #'s) (free-identifier=? #'s #'set!) (identifier? #'id)
            (let ([symbol (syntax->datum #'id)])
              (and (prefixed? symbol)
                   (not (hashtable-contains? exporters symbol))
                   (not (changeable-identifier? #'id lookup))
                   (not (hashtable-contains? top-level-definitions symbol))
                   (not (top-level-bound? symbol repl-environment)))))
       (raise
         (condition
           (make-violation)
           (make-who-condition 'set!)
           (make-message-condition
             (format "no loaded module exports ~s" (syntax->datum #'id)))))]
      [_ (void)]))

  ;; Only forms written at the top level are checked: no documented means
  ;; shows what a macro's expansion defines.
  (define (check-top-level-form x)
    (lambda (lookup)
      (syntax-case x ()
        [(k form)
         (syntax-case #'form ()
           [(b sub ...)
            (and (identifier? #'b) (free-identifier=? #'b #'begin))
            #'(begin (k sub) ...)]
           [_ (begin
                (check-definition! #'form lookup)
                (check-assignment! #'form lookup)
                #'form)])])))

  (define (import-module! name)
    (let ([exports (library-exports name)])
      (for-each
        (lambda (symbol)
          (when (hashtable-contains? top-level-definitions symbol)
            (hashtable-delete! top-level-definitions symbol)
            (report-safely
              (condition
                (make-warning)
                (make-who-condition 'import)
                (make-message-condition
                  (format "~s replaces the top-level definition of ~s" name symbol))))))
        exports)
      (eval `(import ,name) repl-environment)
      (hashtable-set! imported name #t)
      (for-each (lambda (symbol) (hashtable-set! exporters symbol name)) exports)))

  (define (import-loaded-modules!)
    (for-each
      (lambda (name)
        (unless (hashtable-contains? imported name)
          (import-module! name)))
      (loaded-modules)))

  (define (unwrap x)
    (if (annotation? x) (annotation-stripped x) x))

  (define (top-level-imports form)
    (let ([form (unwrap form)])
      (cond
        [(and (pair? form) (eq? (car form) 'import) (list? form))
         (filter values (map import-spec-library (cdr form)))]
        [(and (pair? form) (eq? (car form) 'begin) (list? form))
         (apply append (map top-level-imports (cdr form)))]
        [else '()])))

  ;; Chez runs a library's body only when code refers to one of its
  ;; variables; Tuna runs every imported module's body. Without inspector
  ;; information a procedure defined in the configuration prints as one
  ;; typed at the REPL does, with no source position. A module's body sets
  ;; the owner until it ends, so the owner is restored when one raises.
  (define (eval-top-level form)
    (import-loaded-modules!)
    (parameterize ([current-owner (current-owner)])
      (call-with-values
        (lambda ()
          (parameterize ([generate-inspector-information #f])
            (eval (list check-keyword form) repl-environment)))
        (lambda results
          (run-modules! (top-level-imports form))
          (apply values results)))))

  (define (report-safely c)
    (guard (e [#t (write-condition c) (write-condition e)])
      (report c)))

  ;; Chez runs its source optimizer twice, so one compile warning can be
  ;; raised twice; each text is reported once per call.
  (define (call-reporting thunk)
    (let ([warned '()])
      (guard (c [#t (report-safely c)])
        (with-exception-handler
          (lambda (c)
            (if (and (warning? c) (not (serious-condition? c)))
                (let ([text (condition-text c)])
                  (unless (member text warned)
                    (set! warned (cons text warned))
                    (report-safely c)))
                (raise-continuable c)))
          thunk))))

  (define (read-annotated-forms path consume)
    (let ([sfd (call-with-port (open-file-input-port path) (lambda (p) (make-source-file-descriptor path p)))])
      (call-with-port (open-input-file path)
        (lambda (p)
          (let loop ([position 0])
            (let-values ([(form end) (get-datum/annotations p sfd position)])
              (unless (eof-object? form)
                (consume form)
                (loop end))))))))

  ;; A read error ends the configuration: after it, where the next form
  ;; starts is unknown.
  (define (load-configuration!)
    (when (file-exists? configuration-file)
      (as-module '(init)
        (call-reporting
          (lambda ()
            (read-annotated-forms configuration-file
              (lambda (form) (call-reporting (lambda () (eval-top-level form))))))))))

  (define (expand-home path)
    (if (and (fx>= (string-length path) 2) (string=? (substring path 0 2) "~/"))
        (string-append home (substring path 1 (string-length path)))
        path))

  (define (read-all text)
    (let ([p (open-input-string text)])
      (let loop ([forms '()])
        (let ([form (read p)])
          (if (eof-object? form)
              (reverse forms)
              (loop (cons form forms)))))))

  (define eval-text
    (case-lambda
      [(text) (eval-text text #f)]
      [(text path)
       (unless (string? text) (assertion-violation 'eval-text "not a string" text))
       (unless (or (not path) (string? path)) (assertion-violation 'eval-text "not a path" path))
       (let* ([path (and path (expand-home path))]
              [module (and path (source-module path))]
              [eval-form (cond
                           [module (lambda (form) (eval-in-module form module))]
                           [(and path (string=? path configuration-file))
                            (lambda (form) (as-module '(init) (eval-top-level form)))]
                           [else (lambda (form) (as-module '(repl) (eval-top-level form)))])])
         (let loop ([forms (read-all text)] [results (list (void))])
           (if (null? forms)
               (apply values results)
               (loop (cdr forms) (call-with-values (lambda () (eval-form (car forms))) list)))))])))

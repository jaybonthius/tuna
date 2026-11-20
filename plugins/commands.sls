#!tuna

(define-hook before-command
  "Called with the command before each outermost run, before its interactive expressions.")

(define-hook after-command
  "Called with the command that ended last in each outermost run, also after a raise or a quit.")

(define-table command-modes
  "Maps a command to the list of modes it is for; an empty list marks a command for no mode.")

(define-table region-commands
  "Maps a command that acts on each cursor's region, when it has one, to #t, so that an action runs it on its target as the region.")

(module %internals
  (check-main-thread registry register! command-entry entry-procedure entry-reader
   command-name-of call-outermost call-inner running-command running-previous running-outermost
   outermost-kept?-set! prefix?)

  (define main-thread (get-thread-id))

  (define (main-thread?) (fx= (get-thread-id) main-thread))

  (define (check-main-thread who)
    (unless (main-thread?)
      (assertion-violation who "not on the main thread")))

  ;; Keyed by name, not procedure: every procedure has the same equal-hash,
  ;; so a table keyed by procedures is searched one key at a time.
  (define-table registry)

  ;; The registry keeps the configuration's and the REPL's entries across
  ;; a reload of this module, so the record type stays the same while its
  ;; shape does.
  (define-record-type entry
    (nongenerative commands:entry/procedure/reader)
    (sealed #t)
    (fields procedure reader))

  (define (command-entry name) (table-ref registry name #f))

  ;; Weak, since a command the configuration or the REPL defines again
  ;; leaves its previous procedure behind. Only the main thread adds to
  ;; it, holding the mutex, and reads it without; other threads take the
  ;; mutex, since a hashtable read while another thread adds to it can see
  ;; it half changed.
  (define names-mutex (make-mutex))

  (define names
    (let ([names (make-weak-eq-hashtable)])
      (for-each
        (lambda (entry) (eq-hashtable-set! names (entry-procedure (cdr entry)) (car entry)))
        (table-entries registry))
      names))

  (define (exported-name owner id)
    (if (member owner '((init) (repl)))
        id
        (string->symbol (format "~{~a~^/~}:~a" owner id))))

  ;; The index is written first: a quit landing between the two writes
  ;; leaves an index entry that command-name-of ignores, never a registry
  ;; entry run and command? refuse.
  (define (register! procedure id reader)
    (let ([name (exported-name (current-owner) id)])
      (with-mutex names-mutex (eq-hashtable-set! names procedure name))
      (table-set! registry name (make-entry procedure reader))))

  (define (command-name-of v)
    (let ([name (and (procedure? v)
                     (if (main-thread?)
                         (eq-hashtable-ref names v #f)
                         (with-mutex names-mutex (eq-hashtable-ref names v #f))))])
      (and name
           (let ([entry (command-entry name)])
             (and entry (eq? (entry-procedure entry) v)))
           name)))

  (define last #f)

  (define-record-type outermost
    (sealed #t)
    (fields previous (mutable ended) (mutable kept?)))

  (define current-command (make-thread-parameter #f))
  (define current-outermost (make-thread-parameter #f))

  ;; A thread forked in a command inherits its thread parameters, but runs
  ;; no command.
  (define (running-command)
    (and (main-thread?) (current-command)))

  (define (running-outermost)
    (and (main-thread?) (current-outermost)))

  (define (running-previous)
    (let ([o (running-outermost)])
      (if o (outermost-previous o) last)))

  (define (prefix? v)
    (define (count? v) (and (integer? v) (exact? v)))
    (or (not v) (count? v) (eq? v '-) (and (pair? v) (count? (car v)) (null? (cdr v)))))

  (define (warning-only? c)
    (and (warning? c) (not (serious-condition? c))))

  (define (call-in-exception-state state thunk)
    (define (swap!)
      (let ([outer (current-exception-state)])
        (current-exception-state state)
        (set! state outer)))
    (dynamic-wind #t swap! thunk swap!))

  ;; The hooks run in dynamic-wind's in and out, where quits wait, so a
  ;; quit landing as the command ends cannot skip after-command. A paused
  ;; task leaves and enters again, so in calls the hook only the first
  ;; time and out only once the command has ended and its raise has been
  ;; reported, since report may pause too. The hooks run inside the run,
  ;; or an after-command entry that runs a command would call the hooks
  ;; again without end; a command a before-command entry runs is not the
  ;; one the user ran, so neither the command that ended last nor a
  ;; kept last command comes from it.
  ;; The raise is reported where it was raised, before the stack unwinds,
  ;; as the core reports one no handler takes; a warning goes on to the
  ;; caller's handler, which reports it and lets the command continue.
  ;; with-exception-handler runs its handler with the handlers outside
  ;; it, so a quit landing while the handler reports would escape to the
  ;; caller. The only handler of a fresh exception state takes a raise from
  ;; report, or a quit landing while it reports, too; that one is reported
  ;; as well, but no third, so a report that always raises cannot loop.
  (define (call-outermost command thunk)
    (let ([o (make-outermost last #f #f)] [started? #f] [results #f] [reporting #f])
      (parameterize ([current-command command] [current-outermost o])
        (dynamic-wind
          (lambda ()
            (unless started?
              (set! started? #t)
              (before-command command)
              (outermost-ended-set! o #f)
              (outermost-kept?-set! o #f)))
          (lambda ()
            (call/cc
              (lambda (k)
                (let ([caller (current-exception-state)])
                  (call-in-exception-state
                    (create-exception-state
                      (lambda (c)
                        (cond
                          [(warning-only? c)
                           (call-in-exception-state caller (lambda () (raise-continuable c)))]
                          [else
                           (unless results (set! results '()))
                           (case reporting
                             [(#f) (set! reporting 'raise) (report c)]
                             [(raise) (set! reporting 'report) (report c)])
                           (set! reporting #f)
                           (k)])))
                    (lambda () (set! results (call-with-values thunk list))))))))
          (lambda ()
            (when (and results (not reporting))
              (let ([ended (or (outermost-ended o) command)])
                (unless (outermost-kept? o) (set! last ended))
                (current-command ended)
                (after-command ended))))))
      (apply values results)))

  (define (call-inner command thunk)
    (let ([o (current-outermost)])
      (call-with-values
        (lambda ()
          (with-exception-handler
            (lambda (c)
              (unless (warning-only? c) (outermost-ended-set! o command))
              (raise-continuable c))
            (lambda ()
              (parameterize ([current-command command])
                (thunk)))))
        (lambda results
          (outermost-ended-set! o command)
          (apply values results))))))

(import %internals)

(define-syntax define-command
  (lambda (x)
    (define (parameter-names p)
      (syntax-case p ()
        [id (identifier? #'id) (list #'id)]
        [(id expr) (identifier? #'id) (list #'id)]
        [((id ...) expr) (for-all identifier? #'(id ...)) #'(id ...)]
        [_ (syntax-violation 'commands:define-command
             "not an identifier, [id expr] or [(id ...) expr]" x p)]))
    (define (interactive-expression p)
      (syntax-case p ()
        [(names expr) #'expr]
        [_ #f]))
    (syntax-case x ()
      [(_ (id parameter ...) doc body1 body2 ...)
       (and (identifier? #'id) (string? (syntax->datum #'doc)))
       (let ([names (map parameter-names #'(parameter ...))])
         (with-syntax ([(formal ...) (apply append names)])
           (let ([exprs (map interactive-expression #'(parameter ...))])
             (with-syntax ([reader
                            (if (for-all values exprs)
                                (with-syntax ([(expr ...) exprs]
                                              [((t ...) ...) (map generate-temporaries names)])
                                  #'(lambda () (let*-values ([(t ...) expr] ...) (list t ... ...))))
                                #'#f)])
               ;; Registering in a definition lets definitions follow the
               ;; form in a module's body.
               #'(begin
                   (define-public (id formal ...) doc body1 body2 ...)
                   (define-values () (begin (register! id 'id reader) (values))))))))]
      [_ (syntax-violation 'commands:define-command
           "expected (commands:define-command (id parameter ...) doc-string body ...+)" x)])))

(define (command? v)
  (and (command-name-of v) #t))

(define (command-name command)
  (or (command-name-of command)
      (assertion-violation 'commands:command-name "not a command" command)))

(define (command-named name)
  (unless (symbol? name)
    (assertion-violation 'commands:command-named "not a symbol" name))
  (let ([entry (command-entry name)])
    (and entry (entry-procedure entry))))

(define (command-names)
  (map car (table-entries registry)))

(define (%private-name? name)
  (let* ([s (symbol->string name)] [n (string-length s)])
    (let loop ([i (fx- n 1)])
      (cond
        [(fx< i 0) (and (fx> n 0) (char=? (string-ref s 0) #\%))]
        [(char=? (string-ref s i) #\:) (and (fx< (fx+ i 1) n) (char=? (string-ref s (fx+ i 1)) #\%))]
        [else (loop (fx- i 1))]))))

(define (public-command-names)
  (remp %private-name? (command-names)))

(define (run command . args)
  (check-main-thread 'commands:run)
  (let ([name (command-name-of command)])
    (unless name
      (assertion-violation 'commands:run "not a command" command))
    (let ([thunk (if (null? args)
                     (let ([reader (entry-reader (command-entry name))])
                       (unless reader
                         (assertion-violation 'commands:run
                           "a parameter has no interactive expression; pass the arguments" name))
                       (lambda () (as-module '(repl) (apply command (reader)))))
                     (lambda () (as-module '(repl) (apply command args))))])
      (if (running-command)
          (call-inner command thunk)
          (call-outermost command thunk)))))

(define (this-command) (running-command))

(define (last-command) (running-previous))

(define (keep-last-command!)
  (check-main-thread 'commands:keep-last-command!)
  (let ([o (running-outermost)])
    (unless o
      (assertion-violation 'commands:keep-last-command! "no command is running"))
    (outermost-kept?-set! o #t)))

(define prefix-argument
  (make-thread-parameter #f
    (lambda (v)
      (unless (prefix? v)
        (assertion-violation 'commands:prefix-argument "not a prefix argument" v))
      v)))

(define (prefix-number)
  (let ([p (prefix-argument)])
    (cond
      [(not p) 1]
      [(eq? p '-) -1]
      [(pair? p) (car p)]
      [else p])))

(library (tuna options)
  (export
    define-option
    with-options
    set-option!
    remove-option!
    set-option-local!
    remove-option-local!
    option-default
    option-setting
    option-settings
    option?
    option-changed
    option-documentation)
  (import (chezscheme) (tuna core changes) (tuna core definitions) (tuna core modules) (tuna scopes)
          (only (tuna hooks) make-hook))

  (define-record-type layer
    (nongenerative)
    (sealed #t)
    (fields owner value change))

  ;; settings and a scope's local values are replaced, never changed in
  ;; place, since other threads read them. An option no scope has held a
  ;; local value of is read without looking at the current scope, which
  ;; would cost as much as the rest of the read.
  (define-record-type option-state
    (nongenerative)
    (sealed #t)
    (fields symbol module key
            (mutable default) (mutable check) (mutable doc) (mutable on-change)
            (mutable settings) (mutable localized?) (mutable defined?) (mutable procedure)))

  (define (setting st)
    (let ([layers (option-state-settings st)])
      (if (null? layers) (option-state-default st) (layer-value (car layers)))))

  (define (scope-value st s)
    (let ([layers (scope-local s (option-state-key st))])
      (if layers (layer-value (car layers)) (setting st))))

  (define (unbound-value st)
    (if (option-state-localized? st)
        (let ([s (current-scope)])
          (if s (scope-value st s) (setting st)))
        (setting st)))

  ;; A thread forked inside a binding holds its parent's record until it
  ;; takes its own, and sees none of its parent's bindings.
  (define (bound-value ts st)
    (if (fx= (thread-state-thread ts) (get-thread-id))
        (let ([bindings (thread-state-bindings ts)] [key (option-state-key st)])
          (if (fx< key (vector-length bindings))
              (let ([v (vector-ref bindings key)])
                (if (eq? v no-binding) (unbound-value st) v))
              (unbound-value st)))
        (unbound-value st)))

  (define (option-value st)
    (let ([ts (current-thread-state)])
      (if (fx= (thread-state-bound ts) 0)
          (unbound-value st)
          (bound-value ts st))))

  (define (option? v)
    (and (wrapper-procedure? v) (option-state? (wrapper-procedure-data v))))

  ;; wrapper-procedure-data checks its argument again, which costs as much
  ;; as the rest of with-options' checks, so it is called once.
  (define (option-state-of who o)
    (let ([st (and (wrapper-procedure? o) (wrapper-procedure-data o))])
      (unless (option-state? st)
        (assertion-violation who "not an option" o))
      st))

  (define (changing-option who o)
    (let ([st (option-state-of who o)])
      (unless (option-state-defined? st)
        (raise-unloaded (option-state-symbol st) (option-state-module st)))
      st))

  (define (checked who st v)
    (unless ((option-state-check st) v)
      (assertion-violation who
        (format "~s is not a valid value for ~s" v (option-state-symbol st))))
    v)

  ;; Keyed by the defined name, not the owner: the configuration and the
  ;; REPL define the same names, so either evaluating the other's form
  ;; keeps the settings.
  (define option-states (make-eq-hashtable))

  (define (make-option name default check doc on-change)
    (check-main-thread 'define-option)
    (unless (procedure? check)
      (assertion-violation 'define-option "not a procedure" check))
    (unless (or (not doc) (string? doc))
      (assertion-violation 'define-option "not a documentation string" doc))
    (unless (or (not on-change) (procedure? on-change))
      (assertion-violation 'define-option "not a procedure" on-change))
    (let* ([module (owner-name (current-owner))] [symbol (definition-symbol module name)])
      (unless (check default)
        (assertion-violation 'define-option
          (format "the default ~s is not a valid value for ~s" default symbol)))
      (cond
        [(hashtable-ref option-states symbol #f)
         => (lambda (st)
              (option-state-default-set! st default)
              (option-state-check-set! st check)
              (option-state-doc-set! st doc)
              (option-state-on-change-set! st on-change)
              (option-state-procedure st))]
        [else
         (let* ([st (make-option-state symbol module (make-local-key) default check doc on-change '() #f #t #f)]
                [o (make-wrapper-procedure
                     (case-lambda
                       [() (option-value st)]
                       [(v) (assertion-violation symbol
                              "an option is bound with with-options, not parameterize")])
                     3
                     st)])
           (option-state-procedure-set! st o)
           (hashtable-set! option-states symbol st)
           o)])))

  (define-syntax define-option
    (lambda (x)
      (syntax-case x ()
        [(_ id default check) (identifier? #'id) #'(define-option id default check #f #f)]
        [(_ id default check doc) (identifier? #'id) #'(define-option id default check doc #f)]
        [(_ id default check doc on-change)
         (identifier? #'id)
         #'(define-exported id (make-option 'id default check doc on-change))])))

  (define option-changed
    (make-hook 'option-changed '(tuna) "Called with an option and its new value whenever its on-change procedure would be."))

  ;; parameterize costs more than the rest of a notification, so the scope
  ;; is bound only when it is not already current.
  (define (notify st s v)
    (define (run)
      (let ([on-change (option-state-on-change st)])
        (when on-change
          (call-module-code (lambda () (on-change v)))))
      (option-changed (option-state-procedure st) v))
    (if (eq? (current-scope) s)
        (run)
        (parameterize ([current-scope s]) (run))))

  (define (notify-if-changed st s before)
    (let ([after (value-of st s)])
      (unless (eqv? after before)
        (notify st s after))))

  (define (layer>? a b)
    (> (owner-rank (layer-owner a)) (owner-rank (layer-owner b))))

  (define (own-layer layers owner)
    (find (lambda (l) (eq? (layer-owner l) owner)) layers))

  (define (option-pairs who arguments)
    (let loop ([arguments arguments] [pairs '()])
      (cond
        [(null? arguments) (reverse pairs)]
        [(null? (cdr arguments))
         (assertion-violation who "an option without a value" (car arguments))]
        [else
         (let ([st (changing-option who (car arguments))])
           (loop (cddr arguments) (cons (cons st (checked who st (cadr arguments))) pairs)))])))

  (define (sorted-layers layers) (list-sort layer>? layers))

  (define (layers-of st s)
    (if s (or (scope-local s (option-state-key st)) '()) (option-state-settings st)))

  (define (layers-set! st s layers)
    (cond
      [s (when (pair? layers) (option-state-localized?-set! st #t))
         (scope-local-set! s (option-state-key st) (and (pair? layers) layers))]
      [else (option-state-settings-set! st layers)]))

  (define (value-of st s)
    (if s (scope-value st s) (setting st)))

  ;; A change in a scope holds the scope weakly, so that the ledger does
  ;; not keep it alive; once it is collected, its changes are forgotten.
  (define (with-held-scope held proc)
    (let ([s (and held (car held))])
      (unless (bwp-object? s) (proc s))))

  (define (set-layers! who kind s arguments)
    (check-main-thread who)
    (let* ([owner (check-current-owner who)]
           [pairs (option-pairs who arguments)]
           [states (fold-right (lambda (p sts) (if (memq (car p) sts) sts (cons (car p) sts))) '() pairs)]
           [before (map (lambda (st) (value-of st s)) states)])
      (for-each
        (lambda (p)
          (let ([st (car p)])
            (with-interrupts-disabled
              (let ([previous (own-layer (layers-of st s) owner)])
                (when previous
                  (if s
                      (forget-scope-change! s (layer-change previous))
                      (forget-change! (layer-change previous)))
                  (layers-set! st s (remq previous (layers-of st s)))))
              (letrec* ([held (and s (weak-cons s '()))]
                        [undo (lambda ()
                                (with-held-scope held
                                  (lambda (s)
                                    (let ([before (value-of st s)])
                                      (layers-set! st s (remq layer (layers-of st s)))
                                      (notify-if-changed st s before)))))]
                        [reorder (lambda ()
                                   (with-held-scope held
                                     (lambda (s) (layers-set! st s (sorted-layers (layers-of st s))))))]
                        [change (if s
                                    (record-scope-change! s who kind (option-state-symbol st) #f undo reorder)
                                    (record-change! who kind (option-state-symbol st) #f undo reorder))]
                        [layer (make-layer owner (cdr p) change)])
                (layers-set! st s (sorted-layers (cons layer (layers-of st s))))))))
        pairs)
      (for-each (lambda (st before) (notify-if-changed st s before)) states before)))

  (define (remove-layers! who s options)
    (check-main-thread who)
    (let ([owner (check-current-owner who)])
      (for-each
        (lambda (o)
          (let ([layer (own-layer (layers-of (changing-option who o) s) owner)])
            (when layer (take-back! (layer-change layer)))))
        options)))

  (define (set-option! . arguments)
    (set-layers! 'set-option! 'setting #f arguments))

  (define (remove-option! . options)
    (remove-layers! 'remove-option! #f options))

  (define (set-option-local! . arguments)
    (set-layers! 'set-option-local! 'local-value (the-current-scope 'set-option-local!) arguments))

  (define (remove-option-local! . options)
    (remove-layers! 'remove-option-local! (the-current-scope 'remove-option-local!) options))

  (define (option-default o)
    (option-state-default (option-state-of 'option-default o)))

  (define (option-setting o)
    (setting (option-state-of 'option-setting o)))

  (define (option-settings o)
    (map (lambda (l) (list (owner-name (layer-owner l)) (layer-value l)))
         (option-state-settings (option-state-of 'option-settings o))))

  (define (option-documentation o)
    (option-state-doc (option-state-of 'documentation o)))

  (define (ensure-room! ts key)
    (let ([bindings (thread-state-bindings ts)])
      (unless (fx< key (vector-length bindings))
        (let ([longer (make-vector (fxmax (fx+ key 1) (fx* 2 (vector-length bindings))) no-binding)])
          (do ([i 0 (fx+ i 1)]) ((fx= i (vector-length bindings)))
            (vector-set! longer i (vector-ref bindings i)))
          (thread-state-bindings-set! ts longer)))))

  ;; Nothing assigns a binding while it is in effect, so the winders need
  ;; not swap, as parameterize's do: entering, also again through a
  ;; continuation, puts the binding in place, and leaving puts back the
  ;; value it hid. Critical, since a quit landing between a winder and
  ;; Chez recording it would leave the binding in place for good.
  (define (call-with-binding st v thunk)
    (let* ([ts (this-thread-state)] [key (option-state-key st)])
      (ensure-room! ts key)
      (let* ([outer (vector-ref (thread-state-bindings ts) key)] [delta (if (eq? outer no-binding) 1 0)])
        (dynamic-wind #t
          (lambda ()
            (vector-set! (thread-state-bindings ts) key v)
            (thread-state-bound-set! ts (fx+ (thread-state-bound ts) delta)))
          thunk
          (lambda ()
            (vector-set! (thread-state-bindings ts) key outer)
            (thread-state-bound-set! ts (fx- (thread-state-bound ts) delta)))))))

  (define (bind-option o v thunk)
    (let ([st (option-state-of 'with-options o)])
      (call-with-binding st (checked 'with-options st v) thunk)))

  ;; Every option and value is checked before any is bound. The first
  ;; binding of an option named twice wins, as the innermost.
  (define-syntax with-options
    (lambda (x)
      (syntax-case x ()
        [(_ ([o v]) b1 b2 ...) #'(bind-option o v (lambda () b1 b2 ...))]
        [(_ ([o v] ...) b1 b2 ...)
         (with-syntax ([(st ...) (generate-temporaries #'(o ...))]
                       [(value ...) (generate-temporaries #'(o ...))])
           #'(let* ([st (option-state-of 'with-options o)] ...)
               (let* ([value (checked 'with-options st v)] ...)
                 (bind-options ((st value) ...) (lambda () b1 b2 ...)))))])))

  (define-syntax bind-options
    (syntax-rules ()
      [(_ () thunk) (thunk)]
      [(_ ((st v) more ...) thunk)
       (bind-options (more ...) (lambda () (call-with-binding st v thunk)))]))

  (define (module-unloaded! name)
    (let-values ([(symbols states) (hashtable-entries option-states)])
      (vector-for-each
        (lambda (symbol st)
          (when (equal? (option-state-module st) name)
            (hashtable-delete! option-states symbol)
            (option-state-defined?-set! st #f)
            (for-each (lambda (l) (forget-change! (layer-change l))) (option-state-settings st))
            (option-state-settings-set! st '())
            (for-each
              (lambda (s)
                (let ([layers (scope-local s (option-state-key st))])
                  (when layers
                    (for-each (lambda (l) (forget-scope-change! s (layer-change l))) layers)
                    (scope-local-set! s (option-state-key st) #f))))
              (scopes-with-locals))))
        symbols states)))

  (add-module-unloaded-handler! module-unloaded!))

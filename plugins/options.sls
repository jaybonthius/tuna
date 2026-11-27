#!tuna
(import (scopes) (owned) (hooks))

;; Settings live in owned's set of the option's full name, one per owner,
;; so they outlive a reload of the defining module or of options. The
;; setting in effect is worked out at each change, so a read costs a field
;; read.
(define-record-type (%option %make-option %option?)
  (nongenerative)
  (sealed #t)
  (fields symbol (mutable owner) (mutable default) (mutable check) (mutable doc) (mutable on-change)
          (mutable set) key slot (mutable setting) (mutable setting-owner) (mutable localized?)
          (mutable procedure)))

;; Local values are kept in the scopes, which outlive a reload of this
;; module, so the record type stays the same while its shape does.
(define-record-type (%local %make-local %local?)
  (nongenerative options:local/owner/value)
  (sealed #t)
  (fields owner value))

(define %options (make-eq-hashtable))
(define %by-procedure (make-weak-eq-hashtable))

;; Bindings are slots of a vector each thread writes alone: a write to a
;; thread parameter takes Chez's thread-context mutex, which costs more
;; than the rest of a binding. A thread forked inside a binding holds its
;; parent's vector until it takes its own, and sees none of its parent's
;; bindings. %bound counts the slots holding a binding on every thread, so
;; a read while none does, the common case, reads no thread parameter,
;; which costs more than the rest of a read; a thread always sees its own
;; changes to the count.
(define %unbound (string->uninterned-symbol "unbound"))
(define %slots (make-thread-parameter (cons #f '#())))
(define %next-slot (box 0))
(define %bound (box 0))

;; In a module, so Chez may inline these calls, as it never does a call of
;; a changeable procedure: a read makes several.
(module %internals (%checked %refresh! %setting %on-main-thread? %local-in-effect %value %value-in %option-of %bind)
  (define (%count-bound! delta)
    (let retry ()
      (let ([n (unbox %bound)])
        (unless (box-cas! %bound n (fx+ n delta)) (retry)))))

  (define (%own-slots)
    (let ([s (%slots)])
      (if (eqv? (car s) (get-thread-id))
          s
          (let ([own (cons (get-thread-id) (make-vector 8 %unbound))])
            (%slots own)
            own))))

  (define (%slot-value slot)
    (let ([s (%slots)])
      (if (eqv? (car s) (get-thread-id))
          (let ([v (cdr s)]) (if (fx< slot (vector-length v)) (vector-ref v slot) %unbound))
          %unbound)))

  (define (%checked who o v)
    (unless ((%option-check o) v)
      (assertion-violation who (format "~s is not a valid value for ~s" v (%option-symbol o))))
    v)

  (define (%in-effect o)
    (let ([es (owned:key-entries (%option-set o) 'setting)])
      (if (null? es)
          (values (%option-default o) #f)
          (let ([e (car (last-pair es))])
            (values (owned:entry-value e) (owned:entry-owner e))))))

  (define (%refresh! o)
    (let-values ([(v owner) (%in-effect o)])
      (%option-setting-set! o v)
      (%option-setting-owner-set! o owner)))

  ;; A setting's owner may have begun to unload since the last change, and
  ;; its setting is out of effect from then on. The kept value is left as it
  ;; is until the unload drops the setting, which then notifies of the
  ;; change.
  (define (%setting o)
    (let ([owner (%option-setting-owner o)])
      (if (and owner (not (owner-live? owner)) (%on-main-thread?))
          (let-values ([(v owner) (%in-effect o)]) v)
          (%option-setting o))))

  (define %main-thread (get-thread-id))
  (define (%on-main-thread?) (eqv? (get-thread-id) %main-thread))

  (define (%local-in-effect items counts?)
    (let loop ([items items] [best #f])
      (cond
        [(null? items) best]
        [(and (counts? (%local-owner (car items)))
              (or (not best) (owner<? (%local-owner best) (%local-owner (car items)))))
         (loop (cdr items) (car items))]
        [else (loop (cdr items) best)])))

  (define (%scope-value o s)
    (let* ([items (scopes:ref s (%option-key o))] [l (and items (%local-in-effect items owner-live?))])
      (if l (%local-value l) (%setting o))))

  (define (%value o)
    (let ([v (if (fx= (unbox %bound) 0) %unbound (%slot-value (%option-slot o)))])
      (cond
        [(not (eq? v %unbound)) v]
        [(%option-localized? o)
         (let ([s (scopes:current)])
           (if s (%scope-value o s) (%setting o)))]
        [else (%setting o)])))

  (define (%value-in o s)
    (if s (%scope-value o s) (%setting o)))

  (define (%option-of who o)
    (or (and (procedure? o) (hashtable-ref %by-procedure o #f))
        (assertion-violation who "not an option" o)))

  (define (%ensure-slot! s slot)
    (let ([vec (cdr s)])
      (unless (fx< slot (vector-length vec))
        (let ([longer (make-vector (fxmax (fx+ slot 1) (fx* 2 (vector-length vec))) %unbound)])
          (do ([i 0 (fx+ i 1)]) ((fx= i (vector-length vec))) (vector-set! longer i (vector-ref vec i)))
          (set-cdr! s longer)))))

  ;; A swap, as parameterize's winders do, so a binding survives a task's
  ;; pause and resume. The other value is boxed, since this module defines
  ;; set! for options.
  (define (%bind o v thunk)
    (let ([slot (%option-slot o)] [other (box v)])
      (define (swap!)
        (let ([s (%own-slots)])
          (%ensure-slot! s slot)
          (let* ([vec (cdr s)] [old (vector-ref vec slot)] [new (unbox other)])
            (vector-set! vec slot new)
            (set-box! other old)
            (cond
              [(eq? old %unbound) (%count-bound! 1)]
              [(eq? new %unbound) (%count-bound! -1)]))))
      (dynamic-wind swap! thunk swap!))))

(import %internals)

(define (%full-symbol module name)
  (if (member module '((init) (repl)))
      name
      (string->symbol (format "~{~a~^/~}:~a" module name))))

;; A check that raises rejects the value, but a cancel goes through, so a
;; check that never returns can be ended.
(define (%accepts? check v)
  (guard (c [(not (cancelled? c)) #f])
    (check v)))

(define (%define-option module name default check doc on-change)
  (unless (procedure? check) (assertion-violation 'options:define-option "not a procedure" check))
  (unless (or (not doc) (string? doc)) (assertion-violation 'options:define-option "not a documentation string" doc))
  (unless (or (not on-change) (procedure? on-change))
    (assertion-violation 'options:define-option "not a procedure" on-change))
  (let ([symbol (%full-symbol module name)])
    (unless (check default)
      (assertion-violation 'options:define-option
        (format "the default ~s is not a valid value for ~s" default symbol)))
    (let ([o (or (hashtable-ref %options symbol #f)
                 (let ([slot (unbox %next-slot)] [key (scopes:make-key symbol)])
                   (set-box! %next-slot (fx+ slot 1))
                   (let ([o (%make-option symbol #f default check doc on-change #f key slot default #f
                              (pair? (scopes:holding key)) #f)])
                     (hashtable-set! %options symbol o)
                     o)))])
      (%option-owner-set! o (current-owner))
      (%option-default-set! o default)
      (%option-check-set! o check)
      (%option-doc-set! o doc)
      (%option-on-change-set! o on-change)
      (%option-set-set! o (owned:make symbol (lambda () (%dropped! o))))
      (%refresh! o)
      (%reject-kept-values! o)
      (case-lambda
        [() (%value o)]
        [(v) (assertion-violation symbol "an option is bound with options:with, not parameterize")]))))

(define (%register! procedure module name)
  (let ([o (hashtable-ref %options (%full-symbol module name) #f)])
    (%option-procedure-set! o procedure)
    (hashtable-set! %by-procedure procedure o)))

;; Settings and local values kept from before were checked only with the
;; previous check.
(define (%reject-kept-values! o)
  (define (rejected what value owner)
    (report (condition (make-warning) (make-who-condition 'options:define-option)
              (make-message-condition
                (format "~a ~s of ~s made by ~s fails its check; it is taken back"
                  what value (%option-symbol o) (owner-name owner))))))
  (for-each
    (lambda (e)
      (unless (%accepts? (%option-check o) (owned:entry-value e))
        (call-as-owner (owned:entry-owner e) (lambda () (owned:withdraw! (%option-set o) 'setting)))
        (rejected "the setting" (owned:entry-value e) (owned:entry-owner e))))
    (owned:key-entries (%option-set o) 'setting))
  (for-each
    (lambda (s)
      (let-values ([(kept failed) (partition (lambda (l) (or (not (owner-live? (%local-owner l)))
                                                             (%accepts? (%option-check o) (%local-value l))))
                                             (or (scopes:ref s (%option-key o)) '()))])
        (unless (null? failed)
          (scopes:set! s (%option-key o) kept)
          (for-each (lambda (l) (rejected "the local value" (%local-value l) (%local-owner l))) failed))))
    (scopes:holding (%option-key o)))
  (%refresh! o))

(define-syntax define-option
  (lambda (x)
    (syntax-case x ()
      [(_ id default check) (identifier? #'id) #'(define-option id default check #f #f)]
      [(_ id default check doc) (identifier? #'id) #'(define-option id default check doc #f)]
      [(_ id default check doc on-change)
       (identifier? #'id)
       #'(begin
           (define-public id (%define-option (owner-name (current-owner)) 'id default check doc on-change))
           (define-values () (begin (%register! id (owner-name (current-owner)) 'id) (values))))]
      [_ (syntax-violation 'options:define-option "invalid syntax" x)])))

(define (option? v) (and (procedure? v) (hashtable-ref %by-procedure v #f) #t))

(hooks:define-hook changed "Called with an option and its new value whenever its on-change procedure would be.")

;; on-change runs as the option's module, which raises &unloaded if that
;; module is the one unloading; that is skipped.
(define (%notify o s v)
  (define (run)
    (let ([on-change (%option-on-change o)] [owner (%option-owner o)])
      (when on-change
        (guard (c [(cancelled? c) (raise c)] [#t (unless (unloaded? c) (report c))])
          (call-as-owner owner (lambda () (on-change v))))))
    (changed (%option-procedure o) v))
  (if (eq? (scopes:current) s)
      (run)
      (parameterize ([scopes:current s]) (run))))

(define (%dropped! o)
  (let ([before (%option-setting o)])
    (%refresh! o)
    (unless (eqv? before (%option-setting o))
      (%notify o #f (%option-setting o)))))

(define (%pairs who arguments)
  (let loop ([arguments arguments] [pairs '()])
    (cond
      [(null? arguments) (reverse pairs)]
      [(null? (cdr arguments)) (assertion-violation who "an option without a value" (car arguments))]
      [else
       (let ([o (%option-of who (car arguments))])
         (loop (cddr arguments) (cons (cons o (%checked who o (cadr arguments))) pairs)))])))

(define (%current-scope who)
  (or (scopes:current) (assertion-violation who "the current scope is #f")))

(define (%live-owner who)
  (let ([o (current-owner)])
    (unless (and o (owner-live? o)) (assertion-violation who "this code acts for no live owner" o))
    o))

;; Every option is set before any on-change runs, so each sees the others'
;; new values.
(define (%change! who s pairs change!)
  (unless (%on-main-thread?) (assertion-violation who "only the main thread makes changes"))
  (let* ([options (fold-right (lambda (p os) (if (memq (car p) os) os (cons (car p) os))) '() pairs)]
         [before (map (lambda (o) (%value-in o s)) options)])
    (call-with-cancellation-masked
      (lambda (restore)
        (for-each change! pairs)
        (for-each (lambda (o) (unless s (%refresh! o))) options)))
    (for-each (lambda (o before)
                (let ([after (%value-in o s)])
                  (unless (eqv? before after) (%notify o s after))))
              options before)))

(define (set! . arguments)
  (%change! 'options:set! #f (%pairs 'options:set! arguments)
    (lambda (p) (owned:add! (%option-set (car p)) 'setting (cdr p)))))

(define (unset! . options)
  (%change! 'options:unset! #f (map (lambda (o) (cons (%option-of 'options:unset! o) #f)) options)
    (lambda (p) (owned:withdraw! (%option-set (car p)) 'setting))))

(define (%put-local! s o item)
  (%option-localized?-set! o #t)
  (let ([owner (%live-owner 'options:set-local!)])
    (scopes:set! s (%option-key o)
      (let ([kept (remp (lambda (l) (eq? (%local-owner l) owner)) (or (scopes:ref s (%option-key o)) '()))])
        (if item (cons item kept) kept)))))

(define (set-local! . arguments)
  (let ([s (%current-scope 'options:set-local!)] [owner (%live-owner 'options:set-local!)])
    (%change! 'options:set-local! s (%pairs 'options:set-local! arguments)
      (lambda (p) (%put-local! s (car p) (%make-local owner (cdr p)))))))

(define (unset-local! . options)
  (let ([s (%current-scope 'options:unset-local!)])
    (%change! 'options:unset-local! s (map (lambda (o) (cons (%option-of 'options:unset-local! o) #f)) options)
      (lambda (p) (%put-local! s (car p) #f)))))

(define (default o) (%option-default (%option-of 'options:default o)))

(define (setting o) (%setting (%option-of 'options:setting o)))

(define (settings o)
  (map (lambda (e) (list (owner-name (owned:entry-owner e)) (owned:entry-value e)))
       (reverse (owned:key-entries (%option-set (%option-of 'options:settings o)) 'setting))))

(define (local? o)
  (let ([opt (%option-of 'options:local? o)] [s (scopes:current)])
    (and s
         (let ([items (scopes:ref s (%option-key opt))])
           (and items (exists (lambda (l) (owner-live? (%local-owner l))) items) #t)))))

(define (documentation o) (%option-doc (%option-of 'options:documentation o)))

;; Every option and value is checked before any is bound. The first
;; binding of an option named twice wins, as the innermost.
(define (%with options values thunk)
  (let* ([os (map (lambda (o) (%option-of 'options:with o)) options)]
         [vs (map (lambda (o v) (%checked 'options:with o v)) os values)])
    ((fold-left (lambda (inner o v) (lambda () (%bind o v inner))) thunk os vs))))

;; One binding, by far the most common, needs no lists.
(define (%with-one o v thunk)
  (let ([o (%option-of 'options:with o)])
    (%bind o (%checked 'options:with o v) thunk)))

(define-syntax with
  (syntax-rules ()
    [(_ ([o v]) b1 b2 ...) (%with-one o v (lambda () b1 b2 ...))]
    [(_ ([o v] ...) b1 b2 ...)
     (%with (list o ...) (list v ...) (lambda () b1 b2 ...))]))

;; Local values are not in owned's sets, so they are dropped here, after
;; the owner's own clean-up. A scope whose value the drop changes is
;; told, as a take-back of a setting is.
(advice-add! owner-unloading
  (lambda (next owner)
    (next owner)
    (vector-for-each
      (lambda (o)
        (when (%option-localized? o)
          (for-each
            (lambda (s)
              (let ([items (scopes:ref s (%option-key o))])
                (when (exists (lambda (l) (eq? (%local-owner l) owner)) items)
                  (let ([before (%local-in-effect items (lambda (x) (or (eq? x owner) (owner-live? x))))])
                    (scopes:set! s (%option-key o) (remp (lambda (l) (eq? (%local-owner l) owner)) items))
                    (when (eq? (%local-owner before) owner)
                      (let ([after (%value-in o s)])
                        (unless (eqv? (%local-value before) after)
                          (%notify o s after))))))))
            (scopes:holding (%option-key o)))))
      (hashtable-values %options))))

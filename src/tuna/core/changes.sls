(library (tuna core changes)
  (export
    module-name?
    prefixed-symbol
    definition-symbol

    owner-name
    owner-rank
    owner-instance
    current-instance
    find-owner
    loaded-owner
    current-owner
    set-current-owner!
    call-as-owner
    this-module
    as-module
    rank-module!
    unrank-module!
    move-before-importers!

    change-owner
    change-kind
    change-thing
    change-detail
    change-sequence
    check-current-owner
    record-change!
    forget-change!
    take-back!
    owner-changes
    module-changes

    on-main-thread?
    check-main-thread
    quits-allowed
    set-quits-allowed!
    with-quits-allowed
    with-quit-safe-mutex

    make-thread-state
    current-thread-state
    this-thread-state
    thread-state-thread
    thread-state-owner
    thread-state-owner-set!
    thread-state-quits-allowed
    thread-state-quits-allowed-set!
    thread-state-bound
    thread-state-bound-set!
    thread-state-bindings
    thread-state-bindings-set!
    no-binding)
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
          (display name p)))))

  (define (fixed-owner-name? name)
    (member name '((init) (repl) (tuna))))

  ;; The configuration, the REPL and Tuna itself define their names at the
  ;; top level, where names carry no prefix.
  (define (definition-symbol module name)
    (if (fixed-owner-name? module) name (prefixed-symbol module name)))

  (define main-thread-id (get-thread-id))

  (define (on-main-thread?) (fx= (get-thread-id) main-thread-id))

  (define (check-main-thread who)
    (unless (on-main-thread?)
      (assertion-violation who "only the main thread makes changes")))

  ;; A band is wider than the number of ranks one process takes.
  (define outside-band 0)
  (define lib-band (expt 2 40))
  (define init-rank (expt 2 41))
  (define repl-rank (+ init-rank 1))

  ;; An owner outlives its rank: a module that unloads keeps its record, so
  ;; a module loaded again has the same owner with a fresh rank. instance
  ;; counts those loads, so that work posted before an unload never runs
  ;; under the next instance; the rank cannot tell, since moving a module
  ;; before its importers changes it too. Its changes are a list linked
  ;; both ways through the changes themselves, so taking one back costs the
  ;; same however many the owner has.
  (define-record-type owner
    (nongenerative)
    (sealed #t)
    (fields name (mutable rank) (mutable instance) (mutable newest-change))
    (protocol (lambda (new) (lambda (name rank) (new name rank 0 #f)))))

  (define owners
    (let ([owners (make-hashtable equal-hash equal?)])
      (for-each (lambda (name rank) (hashtable-set! owners name (make-owner name rank)))
                '((tuna) (init) (repl))
                (list 0 init-rank repl-rank))
      owners))

  ;; Any thread looks owners up. The main thread, their only writer, reads
  ;; them without the lock.
  (define owners-mutex (make-mutex))

  (define (find-owner name)
    (if (on-main-thread?)
        (hashtable-ref owners name #f)
        (with-quit-safe-mutex owners-mutex (hashtable-ref owners name #f))))

  (define (loaded-owner name)
    (let ([o (find-owner name)])
      (and o (owner-rank o) o)))

  ;; A thread's owner, its quits-allowed flag and its option bindings are
  ;; fields of one record, so switching one is a field write: writing a
  ;; thread parameter takes Chez's thread-context mutex, which costs more
  ;; than the rest of a switch. bound counts the options bound, so that a
  ;; read outside any binding looks at no vector. A thread forked by Tuna
  ;; acts for the instance its owner had at the fork, so that what it posts
  ;; once that instance has unloaded never runs under the next; a thread
  ;; forked by Chez cannot know it.
  (define-record-type thread-state
    (nongenerative)
    (sealed #t)
    (fields thread (mutable owner) forked-owner forked-instance (mutable quits-allowed)
            (mutable bound) (mutable bindings))
    (protocol
      (lambda (new)
        (case-lambda
          [(owner) (new (get-thread-id) owner #f #f #f 0 (make-vector 8 no-binding))]
          [(owner instance) (new (get-thread-id) owner owner instance #f 0 (make-vector 8 no-binding))]))))

  (define no-binding (string->uninterned-symbol "no-binding"))

  ;; Written once per thread: fork-thread gives a new thread its parent's
  ;; record, which only the parent may change.
  (define current-thread-state
    (make-thread-parameter (make-thread-state (hashtable-ref owners '(repl) #f))))

  ;; A thread forked with Chez's own fork-thread acts for the owner its
  ;; parent has when the thread first needs a record, not at the fork.
  (define (this-thread-state)
    (let ([s (current-thread-state)])
      (if (fx= (thread-state-thread s) (get-thread-id))
          s
          (let ([own (make-thread-state (thread-state-owner s))])
            (current-thread-state own)
            own))))

  (define (current-owner)
    (thread-state-owner (this-thread-state)))

  (define (current-instance owner)
    (let ([s (this-thread-state)])
      (if (eq? owner (thread-state-forked-owner s))
          (thread-state-forked-instance s)
          (owner-instance owner))))

  ;; For a module's body, which cannot be wrapped: the code that runs
  ;; bodies puts back the owner around them.
  (define (set-current-owner! owner)
    (thread-state-owner-set! (this-thread-state) owner))

  ;; A module's body sets its owner and quits-allowed directly, so the
  ;; winders swap, as parameterize's do: code left and re-entered gets back
  ;; the value it had. Critical, since a quit landing between a switch and
  ;; Chez recording it would leave the switch in place.
  (define (call-swapping field field-set! value thunk)
    (let ([s (this-thread-state)] [other value])
      (define (swap!)
        (let ([outer (field s)])
          (field-set! s other)
          (set! other outer)))
      (dynamic-wind #t swap! thunk swap!)))

  (define (call-as-owner owner thunk)
    (call-swapping thread-state-owner thread-state-owner-set! owner thunk))

  (define-syntax this-module
    (syntax-rules ()
      [(_) (owner-name (current-owner))]))

  ;; A quit lands only where this is true: in a module's own code, never in
  ;; the bookkeeping of changes and modules, which a raise half way through
  ;; would leave inconsistent. A request made meanwhile waits. An update
  ;; that takes no lock and runs no module's code disables interrupts
  ;; instead, which costs less and keeps tick's advice out of it too.
  (define (quits-allowed)
    (thread-state-quits-allowed (this-thread-state)))

  (define (set-quits-allowed! allowed)
    (thread-state-quits-allowed-set! (this-thread-state) allowed))

  (define (call-with-quits-allowed allowed thunk)
    (call-swapping thread-state-quits-allowed thread-state-quits-allowed-set! allowed thunk))

  (define-syntax with-quits-allowed
    (syntax-rules ()
      [(_ allowed e1 e2 ...) (call-with-quits-allowed allowed (lambda () e1 e2 ...))]))

  ;; with-mutex is not atomic: a quit raised just after it takes the mutex,
  ;; or just before it lets it go, would leave the mutex held. One wind
  ;; does both, since posting to the main thread takes a mutex this way.
  (define-syntax with-quit-safe-mutex
    (syntax-rules ()
      [(_ m e1 e2 ...)
       (let* ([s (this-thread-state)] [allowed (thread-state-quits-allowed s)])
         (dynamic-wind
           (lambda () (thread-state-quits-allowed-set! s #f) (mutex-acquire m))
           (lambda () e1 e2 ...)
           (lambda () (mutex-release m) (thread-state-quits-allowed-set! s allowed))))]))

  (define next-rank 1)

  (define (take-rank! band)
    (let ([rank (+ band next-rank)])
      (set! next-rank (+ next-rank 1))
      rank))

  (define (rank-module! name lib?)
    (unless (or (fixed-owner-name? name) (loaded-owner name))
      (let ([rank (take-rank! (if lib? lib-band outside-band))] [o (find-owner name)])
        (if o
            (begin
              (owner-rank-set! o rank)
              (owner-instance-set! o (+ (owner-instance o) 1)))
            (with-quit-safe-mutex owners-mutex
              (hashtable-set! owners name (make-owner name rank)))))))

  (define (unrank-module! name)
    (unless (fixed-owner-name? name)
      (let ([o (find-owner name)])
        (when o (owner-rank-set! o #f)))))

  ;; An importer takes its rank only after its imports have run, so a fresh
  ;; rank puts the import before it.
  (define (move-before-importers! name)
    (let ([o (and (not (fixed-owner-name? name)) (loaded-owner name))])
      (when (and o (>= (owner-rank o) lib-band))
        (owner-rank-set! o (take-rank! outside-band))
        (for-each (lambda (c) ((change-reorder c))) (owner-changes name)))))

  (define (call-as-module name thunk)
    (unless (module-name? name)
      (assertion-violation 'as-module "not a module name" name))
    (let ([owner (loaded-owner name)])
      (unless (and owner (not (equal? name '(tuna))))
        (assertion-violation 'as-module "not a loaded module" name))
      (call-as-owner owner thunk)))

  (define-syntax as-module
    (syntax-rules ()
      [(_ module-expr body1 body2 ...)
       (call-as-module module-expr (lambda () body1 body2 ...))]))

  (define-record-type change
    (nongenerative)
    (sealed #t)
    (fields owner kind thing detail sequence undo reorder (mutable newer) (mutable older))
    (protocol
      (lambda (new)
        (lambda (owner kind thing detail sequence undo reorder)
          (new owner kind thing detail sequence undo reorder #f (owner-newest-change owner))))))

  (define next-sequence 0)

  ;; Newest first, the order they are taken back in.
  (define (owner-changes name)
    (let ([o (find-owner name)])
      (let loop ([c (and o (owner-newest-change o))])
        (if c (cons c (loop (change-older c))) '()))))

  ;; A task of an unloaded module that catches &quit goes on running on its
  ;; behalf; a change it made would never be taken back.
  (define (check-current-owner who)
    (let ([owner (current-owner)])
      (unless (owner-rank owner)
        (assertion-violation who "not a loaded module" (owner-name owner)))
      owner))

  ;; The timer interrupt runs tick's advice, which may change things too,
  ;; so the ledger is updated with interrupts disabled, never half.
  (define (record-change! who kind thing detail undo reorder)
    (check-main-thread who)
    (let ([owner (check-current-owner who)])
      (with-interrupts-disabled
        (set! next-sequence (+ next-sequence 1))
        (let ([c (make-change owner kind thing detail next-sequence undo reorder)])
          (let ([older (change-older c)])
            (when older (change-newer-set! older c)))
          (owner-newest-change-set! owner c)
          c))))

  ;; A change already forgotten has no newer change and is not its owner's
  ;; newest.
  (define (forget-change! c)
    (with-interrupts-disabled
      (let ([o (change-owner c)] [newer (change-newer c)] [older (change-older c)])
        (when (or newer (eq? (owner-newest-change o) c))
          (if newer (change-older-set! newer older) (owner-newest-change-set! o older))
          (when older (change-newer-set! older newer))
          (change-newer-set! c #f)
          (change-older-set! c #f)))))

  (define (take-back! c)
    (with-quits-allowed #f
      (forget-change! c)
      ((change-undo c))))

  (define (module-changes name)
    (unless (module-name? name)
      (assertion-violation 'module-changes "not a module name" name))
    (map (lambda (c) (list (change-kind c) (change-thing c) (change-detail c)))
         (owner-changes name))))

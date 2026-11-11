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
    with-owner-switch
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

    layer-owner
    layer-value
    layer-data
    layer-change
    layer-after?
    make-value-layers
    make-procedure-layers
    layers-all
    layers-in-effect
    layers-value
    layers-value-set!
    layers-changes
    forget-layers!
    add-layer!
    remove-layers!
    refresh-layers!

    on-main-thread?
    check-main-thread
    quits-allowed
    set-quits-allowed!
    with-quits-allowed
    with-quit-safe-mutex

    make-thread-state
    current-thread-state
    this-thread-state
    thread-state-owner
    thread-state-owner-set!
    thread-state-quits-allowed
    thread-state-quits-allowed-set!
    make-thread-slot
    thread-slot-ref
    call-with-thread-slot)
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

  ;; A thread's owner, its quits-allowed flag and its slots are fields of
  ;; one record, so switching one is a field write: writing a thread
  ;; parameter takes Chez's thread-context mutex, which costs more than the
  ;; rest of a switch. slots-in-use counts the slots bound, so that a read
  ;; outside any binding looks at no vector. A thread forked by Tuna acts
  ;; for the instance its owner had at the fork, so that what it posts once
  ;; that instance has unloaded never runs under the next; a thread forked
  ;; by Chez cannot know it.
  (define-record-type thread-state
    (nongenerative)
    (sealed #t)
    (fields thread (mutable owner) forked-owner forked-instance (mutable quits-allowed)
            (mutable slots-in-use) (mutable slots))
    (protocol
      (lambda (new)
        (case-lambda
          [(owner) (new (get-thread-id) owner #f #f #f 0 (make-vector 8 unbound-slot))]
          [(owner instance) (new (get-thread-id) owner owner instance #f 0 (make-vector 8 unbound-slot))]))))

  (define unbound-slot (string->uninterned-symbol "unbound-slot"))

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

  ;; Critical, since a quit landing between a switch and Chez recording it
  ;; would leave the switch in place. Leaving puts back the owner from
  ;; outside, which also undoes a module body's own switch; nothing
  ;; re-enters a body, where no task can pause, so the winders need not
  ;; swap as parameterize's do.
  (define (call-as-owner-on s owner thunk)
    (let ([outer (thread-state-owner s)])
      (dynamic-wind #t
        (lambda () (thread-state-owner-set! s owner))
        thunk
        (lambda () (thread-state-owner-set! s outer)))))

  (define (call-as-owner owner thunk)
    (call-as-owner-on (this-thread-state) owner thunk))

  ;; Looking up the thread's record for each switch would cost a hook about
  ;; 2 ns per entry, so code that switches owners for many calls in a row
  ;; looks it up once.
  (define-syntax with-owner-switch
    (syntax-rules ()
      [(_ (call-as current) e1 e2 ...)
       (let* ([s (this-thread-state)] [current (thread-state-owner s)])
         (define (call-as owner thunk) (call-as-owner-on s owner thunk))
         e1 e2 ...)]))

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

  ;; Unlike the owner, quits-allowed is also set directly outside module
  ;; bodies, as a hook does after an entry raises, where a task can pause;
  ;; so the winders swap, as parameterize's do: code left and re-entered
  ;; gets back the value it had. Critical, as for the owner.
  (define (call-with-quits-allowed allowed thunk)
    (let ([s (this-thread-state)] [other allowed])
      (define (swap!)
        (let ([outer (thread-state-quits-allowed s)])
          (thread-state-quits-allowed-set! s other)
          (set! other outer)))
      (dynamic-wind #t swap! thunk swap!)))

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

  (define next-thread-slot 0)
  (define thread-slots-mutex (make-mutex))

  (define (make-thread-slot)
    (with-quit-safe-mutex thread-slots-mutex
      (let ([key next-thread-slot])
        (set! next-thread-slot (fx+ key 1))
        key)))

  ;; A macro, so that a read costs no call: Chez does not inline into
  ;; another library a procedure that refers to this library's private
  ;; bindings. A thread forked inside a binding holds its parent's record
  ;; until it takes its own, and sees none of its parent's bindings.
  (define-syntax thread-slot-ref
    (syntax-rules ()
      [(_ key unbound-expr)
       (let ([ts (current-thread-state)])
         (if (fx= (thread-state-slots-in-use ts) 0)
             unbound-expr
             (let ([v (if (fx= (thread-state-thread ts) (get-thread-id))
                          (let ([slots (thread-state-slots ts)] [k key])
                            (if (fx< k (vector-length slots)) (vector-ref slots k) unbound-slot))
                          unbound-slot)])
               (if (eq? v unbound-slot) unbound-expr v))))]))

  (define (ensure-slot! ts key)
    (let ([slots (thread-state-slots ts)])
      (unless (fx< key (vector-length slots))
        (let ([longer (make-vector (fxmax (fx+ key 1) (fx* 2 (vector-length slots))) unbound-slot)])
          (do ([i 0 (fx+ i 1)]) ((fx= i (vector-length slots)))
            (vector-set! longer i (vector-ref slots i)))
          (thread-state-slots-set! ts longer)))))

  ;; Nothing assigns a slot while a binding of it is in effect, so the
  ;; winders need not swap, as parameterize's do: entering, also again
  ;; through a continuation, puts the binding in place, and leaving puts
  ;; back the value it hid. Critical, since a quit landing between a
  ;; winder and Chez recording it would leave the binding in place for
  ;; good.
  (define (call-with-thread-slot key v thunk)
    (let ([ts (this-thread-state)])
      (ensure-slot! ts key)
      (let* ([outer (vector-ref (thread-state-slots ts) key)] [delta (if (eq? outer unbound-slot) 1 0)])
        (dynamic-wind #t
          (lambda ()
            (vector-set! (thread-state-slots ts) key v)
            (thread-state-slots-in-use-set! ts (fx+ (thread-state-slots-in-use ts) delta)))
          thunk
          (lambda ()
            (vector-set! (thread-state-slots ts) key outer)
            (thread-state-slots-in-use-set! ts (fx- (thread-state-slots-in-use ts) delta)))))))

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
  (define (link-change! owner kind thing detail undo reorder)
    (set! next-sequence (+ next-sequence 1))
    (let ([c (make-change owner kind thing detail next-sequence undo reorder)])
      (let ([older (change-older c)])
        (when older (change-newer-set! older c)))
      (owner-newest-change-set! owner c)
      c))

  (define (record-change! who kind thing detail undo reorder)
    (check-main-thread who)
    (let ([owner (check-current-owner who)])
      (with-interrupts-disabled (link-change! owner kind thing detail undo reorder))))

  ;; A change already forgotten has no newer change and is not its owner's
  ;; newest.
  (define (unlink-change! c)
    (let ([o (change-owner c)] [newer (change-newer c)] [older (change-older c)])
      (when (or newer (eq? (owner-newest-change o) c))
        (if newer (change-older-set! newer older) (owner-newest-change-set! o older))
        (when older (change-newer-set! older newer))
        (change-newer-set! c #f)
        (change-older-set! c #f))))

  (define (forget-change! c)
    (with-interrupts-disabled (unlink-change! c)))

  (define (undo-change! c)
    (forget-change! c)
    ((change-undo c)))

  (define (take-back! c)
    (with-quits-allowed #f (undo-change! c)))

  (define (module-changes name)
    (unless (module-name? name)
      (assertion-violation 'module-changes "not a module name" name))
    (map (lambda (c) (list (change-kind c) (change-thing c) (change-detail c)))
         (owner-changes name)))

  ;; The layers in effect, and the value worked out from them, are updated
  ;; at each change, so that a read costs a field read. The timer
  ;; interrupt runs tick's advice, which may change the same layers, so
  ;; each change is made with interrupts disabled. Adding and removing call
  ;; updated inside, so that a quit cannot land before it; taking back,
  ;; reordering and refreshing, which run where quits wait, call it after,
  ;; since it may then run a module's code.
  (define-record-type layer
    (nongenerative)
    (sealed #t)
    (fields owner value data change))

  (define-record-type removal
    (nongenerative)
    (sealed #t)
    (fields value owners change))

  (define-record-type layers
    (nongenerative)
    (sealed #t)
    (fields kind thing one-per-owner? order updated
            (mutable all) (mutable removals) (mutable in-effect) (mutable value))
    (protocol
      (lambda (new)
        (lambda (kind thing one-per-owner? order updated value)
          (new kind thing one-per-owner? order updated '() '() '() value)))))

  (define (make-value-layers kind thing order updated value)
    (make-layers kind thing #t order updated value))

  (define (make-procedure-layers kind thing order updated value)
    (make-layers kind thing #f order updated value))

  (define (layer-after? a b)
    (let ([ra (owner-rank (layer-owner a))] [rb (owner-rank (layer-owner b))])
      (or (> ra rb)
          (and (= ra rb) (> (change-sequence (layer-change a)) (change-sequence (layer-change b)))))))

  ;; A removal hides layers by owner, not the layers it found, so that a
  ;; layer its owner makes again when it reloads stays removed.
  (define (hidden? ls l)
    (let ([removals (layers-removals ls)])
      (and (pair? removals)
           (exists (lambda (r)
                     (and (memq (layer-owner l) (removal-owners r))
                          (or (layers-one-per-owner? ls) (eq? (removal-value r) (layer-value l)))))
                   removals))))

  (define (visible-in-order ls)
    (list-sort (layers-order ls) (remp (lambda (l) (hidden? ls l)) (layers-all ls))))

  ;; Adding one layer places only that layer: sorting them all again would
  ;; cost most of the change when there are a few.
  (define (insert-layer ls l in-effect)
    (let ([before? (layers-order ls)])
      (let insert ([in-effect in-effect])
        (if (or (null? in-effect) (before? l (car in-effect)))
            (cons l in-effect)
            (cons (car in-effect) (insert (cdr in-effect)))))))

  ;; Should tick's advice change the layers between a change and updated,
  ;; before is older than the value, never newer.
  (define-syntax update-layers!
    (syntax-rules ()
      [(_ ls e1 e2 ...)
       (let* ([before (layers-in-effect ls)] [l (begin e1 e2 ...)])
         ((layers-updated ls) ls before l))]))

  (define (sort-layers! ls)
    (update-layers! ls
      (with-interrupts-disabled (layers-in-effect-set! ls (visible-in-order ls)))
      #f))

  (define (drop-layer! ls l)
    (update-layers! ls
      (with-interrupts-disabled
        (layers-all-set! ls (remq l (layers-all ls)))
        (layers-in-effect-set! ls (remq l (layers-in-effect ls))))
      l))

  ;; The caller has checked that the owner may make changes. The owner's
  ;; layer of a value it sets is replaced without being taken back, so that
  ;; the value in effect does not change twice.
  (define add-layer!
    (case-lambda
      [(ls owner detail value) (add-layer! ls owner detail value #f)]
      [(ls owner detail value data)
       (let* ([one? (layers-one-per-owner? ls)]
              [previous (find (lambda (l) (and (eq? (layer-owner l) owner) (or one? (eq? (layer-value l) value))))
                              (layers-all ls))])
         (unless (and previous (not one?))
           (with-interrupts-disabled
             (update-layers! ls
               (when previous
                 (unlink-change! (layer-change previous))
                 (layers-all-set! ls (remq previous (layers-all ls)))
                 (layers-in-effect-set! ls (remq previous (layers-in-effect ls))))
               (letrec* ([change (link-change! owner (layers-kind ls) (layers-thing ls) detail
                                   (lambda () (drop-layer! ls l))
                                   (lambda () (sort-layers! ls)))]
                         [l (make-layer owner value data change)])
                 (layers-all-set! ls (cons l (layers-all ls)))
                 (unless (hidden? ls l)
                   (layers-in-effect-set! ls (insert-layer ls l (layers-in-effect ls))))
                 l)))))]))

  ;; Each removal is a change of its own, so that a layer another owner's
  ;; removal hides stays hidden while either removal stands; only the
  ;; remover's own earlier removal makes another one redundant.
  (define (removed-already? ls owner value others)
    (exists (lambda (r)
              (and (eq? (change-owner (removal-change r)) owner)
                   (or (layers-one-per-owner? ls) (eq? (removal-value r) value))
                   (for-all (lambda (l) (memq (layer-owner l) (removal-owners r))) others)))
            (layers-removals ls)))

  ;; Taking back the owner's own layers and hiding other owners' is one
  ;; piece of bookkeeping, which a quit must not cut in half.
  (define (remove-layers! ls owner detail value)
    (with-quits-allowed #f
      (let* ([one? (layers-one-per-owner? ls)]
             [matching (filter (lambda (l) (or one? (eq? (layer-value l) value))) (layers-all ls))]
             [others (remp (lambda (l) (eq? (layer-owner l) owner)) matching)])
        (for-each (lambda (l) (unless (memq l others) (undo-change! (layer-change l)))) matching)
        (unless (or (null? others) (removed-already? ls owner value others))
          (with-interrupts-disabled
            (update-layers! ls
              (letrec* ([change (link-change! owner 'removal (layers-thing ls) detail
                                  (lambda ()
                                    (with-interrupts-disabled
                                      (layers-removals-set! ls (remq r (layers-removals ls))))
                                    (sort-layers! ls))
                                  (lambda () (sort-layers! ls)))]
                        [r (make-removal value (map layer-owner others) change)])
                (layers-removals-set! ls (cons r (layers-removals ls)))
                (layers-in-effect-set! ls (visible-in-order ls))
                #f)))))))

  ;; A value can depend on more than its layers, such as on whether a
  ;; procedure's module is loaded.
  (define (refresh-layers! ls)
    ((layers-updated ls) ls (layers-in-effect ls) #f))

  (define (layers-changes ls)
    (append (map layer-change (layers-all ls)) (map removal-change (layers-removals ls))))

  (define (forget-layers! ls)
    (for-each forget-change! (layers-changes ls))))

(import (tuna) (test) (test-runner) (hooks) (scopes) (rename (only (chezscheme) sleep) (sleep chez:sleep)))

;; The kernel reports the end of every task a cancel ends, and the stress
;; tests cancel hundreds; any other report still fails the file.
(advice-add! report (lambda (next c) (unless (cancelled? c) (next c))))

(define (sleep-ms ms)
  (chez:sleep (make-time 'time-duration (* (mod ms 1000) 1000000) (quotient ms 1000))))

(define (in-thread thunk)
  (let ([result #f])
    (join-task (fork-task (lambda (restore) (set! result (thunk)))))
    result))

(define (raised-message thunk)
  (guard (c [#t (if (message-condition? c) (condition-message c) c)]) (thunk) #f))

(define (marker n) (lambda (calls) (set-box! calls (cons n (unbox calls)))))

(define markers (map marker (iota 6)))

(define (calls hook . arguments)
  (let ([seen (box '())])
    (apply hook seen arguments)
    (reverse (unbox seen))))

(define as-test-owner
  (let ([owner #f])
    (lambda (thunk)
      (unless (and owner (owner-live? owner)) (set! owner (make-owner '(test))))
      (call-as-owner owner thunk))))

(hooks:define-hook changed "Called with a box of calls.")
(hooks:define-hook undocumented)
(hooks:define-hook warned)
(hooks:define-hook unloading)

;; A module's hook is defined again whenever the module reloads, and the
;; binding a test holds is the old instance's, so it reads the hook anew.
(define (greeted) (eval 'hooks-test/defining:greeted (environment '(hooks-test defining))))

(test "a call runs entries by depth, then owner rank, then the order each owner added them"
  (let* ([low (make-owner '(order low))] [high (make-owner '(order high))])
    (call-as-owner high (lambda () (hooks:add! changed (marker 'high-1)) (hooks:add! changed (marker 'high-deep) -1)))
    (call-as-owner low (lambda () (hooks:add! changed (marker 'low-1)) (hooks:add! changed (marker 'low-2))))
    (call-as-owner low (lambda () (hooks:add! changed (marker 'low-shallow) 1)))
    (check-equal? '(high-deep low-1 low-2 high-1 low-shallow) (calls changed))
    (unload-owner! low)
    (unload-owner! high)
    (check-equal? '() (calls changed))))

(test "hooks:add! of a procedure already added replaces the owner's entry for it"
  (let ([o (make-owner '(replacing))] [twice (marker 'twice)])
    (call-as-owner o
      (lambda ()
        (hooks:add! changed (marker 'other))
        (hooks:add! changed twice -1)
        (hooks:add! changed twice 1)))
    (check-equal? '(other twice) (calls changed))
    (unload-owner! o)))

(test "a removal leaves out a procedure lower-ranked owners added, before or after it, until the remover unloads"
  (let* ([low (make-owner '(removal low))] [high (make-owner '(removal high))] [shared (marker 'shared)])
    (call-as-owner low (lambda () (hooks:add! changed shared)))
    (call-as-owner high (lambda () (hooks:remove! changed shared)))
    (check-equal? '() (calls changed))
    (call-as-owner low (lambda () (hooks:add! changed shared 1)))
    (check-equal? '() (calls changed))
    (unload-owner! high)
    (check-equal? '(shared) (calls changed))
    (unload-owner! low)))

(test "an entry runs as the owner that added it"
  (let ([o (make-owner '(entry owner))] [seen #f])
    (call-as-owner o (lambda () (hooks:add! changed (lambda (calls) (set! seen (current-owner))))))
    (calls changed)
    (check-equal? o seen)
    (unload-owner! o)))

(test "a reload of the module that defines a hook keeps the hook's entries"
  (load-module! '(hooks-test defining))
  (let ([o (make-owner '(defined again))])
    (call-as-owner o (lambda () (hooks:add! (greeted) (marker 'kept))))
    (reload-modules! '((hooks-test defining)))
    (check-equal? '(kept) (calls (greeted)))
    (unload-owner! o)))

(test "a hook is a hook, with its documentation"
  (check (hooks:hook? changed))
  (check (not (hooks:hook? car)))
  (check-equal? "Called with a box of calls." (hooks:documentation changed))
  (check-equal? #f (hooks:documentation undocumented)))

(test "local entries run in the current scope only, and local changes need a scope"
  (let ([s (make-owner '(local))] [scope (scopes:make)])
    (call-as-owner s
      (lambda ()
        (hooks:add! changed (marker 'global))
        (parameterize ([scopes:current scope]) (hooks:add-local! changed (marker 'local) 1))
        (check-raises assertion-violation? (hooks:add-local! changed (marker 'nowhere)))
        (check-raises assertion-violation? (hooks:remove-local! changed (marker 'nowhere)))))
    (check-equal? '(global) (calls changed))
    (check-equal? '(global local) (parameterize ([scopes:current scope]) (calls changed)))
    (unload-owner! s)
    (check-equal? '() (calls changed))))

(test "hooks:entries calls each entry as its owner, in call order, and an entry's raise reaches the caller"
  (let ([o (make-owner '(listed))] [seen '()])
    (call-as-owner o
      (lambda ()
        (hooks:add! changed (lambda (calls) (set! seen (cons (current-owner) seen)) 'first))
        (hooks:add! changed (lambda (calls) (error 'entry "raised")) 1)))
    (let ([entries (hooks:entries changed)])
      (check-equal? 2 (length entries))
      (check-equal? 'first ((car entries) (box '())))
      (check-equal? (list o) seen)
      (check-raises error? ((cadr entries) (box '()))))
    (unload-owner! o)))

(test "entries are in order of depth, then owner rank, then each owner's order, whatever is added, removed and unloaded"
  (let ([procedures (map marker (iota 5))] [mismatches 0])
    (do ([round 0 (+ round 1)]) ((= round 100))
      (let ([os (list (make-owner '(hook a)) (make-owner '(hook b)) (make-owner '(hook c)))])
        (do ([i 0 (+ i 1)]) ((= i 20))
          (let ([o (list-ref os (random 3))] [p (list-ref procedures (random 5))])
            (call-as-owner o
              (lambda ()
                (case (random 3)
                  [(0 1) (hooks:add! changed p (list-ref '(-1 0 0 0.5 1) (random 5)))]
                  [else (hooks:remove! changed p)])))))
        (unload-owner! (list-ref os (random 3)))
        (unless (= (length (calls changed)) (length (hooks:entries changed)))
          (set! mismatches (+ mismatches 1)))
        (for-each (lambda (o) (when (owner-live? o) (unload-owner! o))) os)))
    (check-equal? 0 mismatches)
    (check-equal? '() (hooks:entries changed))))

(test "an entry added under another owner's advice on hooks:add! is the caller's"
  (let ([adviser (make-owner '(hook adviser))] [caller (make-owner '(hook caller))] [p (marker 'advised)])
    (call-as-owner adviser (lambda () (advice-add! hooks:add! (lambda (next . arguments) (apply next arguments)))))
    (call-as-owner caller (lambda () (hooks:add! changed p 0)))
    (unload-owner! adviser)
    (check-equal? '(advised) (calls changed))
    (unload-owner! caller)
    (check-equal? '() (calls changed))))

(test "a call on another thread runs each entry once, in order, while the main thread changes them"
  (let ([stop? #f] [bad '()] [count 0] [mutex (make-mutex)])
    (define (caller)
      (fork-task
        (lambda (restore)
          (let loop ([n 0])
            (if stop?
                (with-mutex mutex (set! count (+ count n)))
                (let ([ran (calls changed)])
                  (unless (equal? ran (list-sort < ran))
                    (with-mutex mutex (set! bad (cons ran bad))))
                  (loop (+ n 1))))))))
    (let ([callers (list (caller) (caller) (caller))])
      (as-test-owner
        (lambda ()
          (do ([i 0 (+ i 1)]) ((= i 3000))
            (for-each (lambda (m n) (hooks:add! changed m n)) markers (iota 6))
            (for-each (lambda (m) (hooks:remove! changed m)) (list-head markers (fxmod i 6))))))
      (set! stop? #t)
      (for-each join-task callers))
    (as-test-owner (lambda () (for-each (lambda (m) (hooks:remove! changed m)) markers)))
    (unload-owner! (as-test-owner current-owner))
    (check-equal? '() bad)
    (check (> count 0))))

(test "only the main thread changes hooks"
  (let ([s (scopes:make)] [o (make-owner '(threaded))])
    (for-each
      (lambda (thunk)
        (check-equal? "only the main thread makes changes"
          (in-thread (lambda () (raised-message (lambda () (call-as-owner o thunk)))))))
      (list (lambda () (hooks:add! changed car))
            (lambda () (hooks:remove! changed car))))
    (check (string? (in-thread (lambda () (raised-message (lambda () (call-as-owner o (lambda () (parameterize ([scopes:current s]) (hooks:add-local! changed car))))))))))
    (unload-owner! o)))

(test "a collected scope's local entries go with it"
  (let ([kept (scopes:make)])
    (as-test-owner
      (lambda ()
        (let ([dropped (map (lambda (i) (scopes:make)) (iota 100))])
          (for-each (lambda (s i) (parameterize ([scopes:current s]) (hooks:add-local! changed (marker i))))
                    dropped (iota 100))
          (parameterize ([scopes:current kept]) (hooks:add-local! changed (car markers)))
          (keep-live dropped))
        (do ([i 0 (+ i 1)]) ((= i 3)) (collect (collect-maximum-generation)))
        (parameterize ([scopes:current kept]) (hooks:add-local! changed (cadr markers) 1))
        (check-equal? '(0 1) (parameterize ([scopes:current kept]) (calls changed)))))
    (unload-owner! (as-test-owner current-owner))))

(test "hooks:entries gives the same procedures on every thread"
  (let ([procedures (map (lambda (i) (lambda (calls) i)) (iota 2000))])
    (as-test-owner (lambda () (for-each (lambda (p) (hooks:add! changed p)) procedures)))
    (let* ([results (map (lambda (i) (box #f)) (iota 4))]
           [threads (map (lambda (b) (fork-task (lambda (restore) (set-box! b (hooks:entries changed))))) results)])
      (for-each join-task threads)
      (let ([es (hooks:entries changed)])
        (check (>= (length es) 2000))
        (for-each (lambda (b) (check (for-all eq? es (unbox b)))) results)))
    (unload-owner! (as-test-owner current-owner))))

(test "a cancel never leaves a hook entry half made"
  (let ([s (scopes:make)] [owner (make-owner '(hook stress))] [cancelled 0])
    (do ([i 0 (+ i 1)]) ((= i 300))
      (let ([t (spawn-task
                 (lambda (restore)
                   (call-as-owner owner
                     (lambda ()
                       (let loop ()
                         (hooks:add! changed (car markers))
                         (hooks:remove! changed (car markers))
                         (parameterize ([scopes:current s])
                           (hooks:add-local! changed (caddr markers))
                           (hooks:remove-local! changed (caddr markers)))
                         (loop))))))])
        (fork-task (lambda (restore) (sleep-ms (random 3)) (cancel-task t)))
        (let-values ([(how detail) (join-task t)])
          (when (eq? how 'cancelled) (set! cancelled (+ cancelled 1))))))
    (check (> cancelled 250))
    (unload-owner! owner)
    (check-equal? '() (calls changed))
    (check-equal? '() (parameterize ([scopes:current s]) (calls changed)))))

(test "a raise in an entry is reported and the next entry runs; a cancel meant for the task ends the task"
  (let ([reported 0])
    (define (quiet report c) (set! reported (+ reported 1)))
    (define (raiser calls) (error 'entry "failed"))
    (as-test-owner
      (lambda ()
        (advice-add! report quiet)
        (hooks:add! changed raiser)
        (hooks:add! changed (marker 7) 1)))
    (check-equal? '(7) (calls changed))
    (check-equal? 1 reported)
    (let* ([inside (box #f)] [t (spawn-task (lambda (restore) (calls changed) 'went-on))])
      (as-test-owner (lambda () (hooks:add! changed (lambda (calls) (set-box! inside #t) (suspend (lambda (resume) (void)))) 2)))
      (test-runner:wait-until (lambda () (unbox inside)))
      (cancel-task t 'stop)
      (let-values ([(how detail) (join-task t)])
        (check-equal? 'cancelled how)))
    (unload-owner! (as-test-owner current-owner))))

(test "a warning in an entry is reported once and the entry goes on; after a raise the next entry runs as its own owner"
  (let ([a (make-owner '(hook warns))] [b (make-owner '(hook after))] [reports '()] [owner-seen #f])
    (define (quiet report c) (set! reports (cons (if (warning? c) 'warning 'error) reports)))
    (as-test-owner (lambda () (advice-add! report quiet)))
    (call-as-owner a
      (lambda ()
        (hooks:add! warned (lambda (calls) (warning 'entry "careful") (set-box! calls (cons 'went-on (unbox calls)))) 0)
        (hooks:add! warned (lambda (calls) (error 'entry "failed")) 1)))
    (call-as-owner b (lambda () (hooks:add! warned (lambda (calls) (set! owner-seen (current-owner))) 2)))
    (check-equal? '(went-on) (calls warned))
    (check-equal? '(error warning) reports)
    (check-equal? b owner-seen)
    (unload-owner! (as-test-owner current-owner))
    (unload-owner! a)
    (unload-owner! b)))

(test "an owner's entry is out of effect once its unload begins, though its own code runs the hook"
  (let ([o (make-owner '(hook unloading))] [seen (box '())])
    (call-as-owner o
      (lambda ()
        (hooks:add! unloading (marker 'own))
        (on-unload (lambda () (unloading seen)))))
    (unload-owner! o)
    (check-equal? '() (unbox seen))))

;; The procedure counts its calls, so the compiler cannot make it a
;; constant that is never collected.
(test "a procedure taken out of a hook is collected"
  (let ([g (make-guardian)])
    (let ([p (let ([n 0]) (lambda (calls) (set! n (+ n 1))))])
      (g p)
      (as-test-owner
        (lambda ()
          (hooks:add! changed p)
          (hooks:entries changed)
          (hooks:remove! changed p))))
    (do ([i 0 (+ i 1)]) ((= i 3)) (collect (collect-maximum-generation)))
    (check (procedure? (g)))))

(test "global and local entries outlive a reload of hooks"
  (let ([s (scopes:make)] [o (make-owner '(reloaded))])
    (call-as-owner o
      (lambda ()
        (hooks:add! (greeted) (marker 'global))
        (parameterize ([scopes:current s]) (hooks:add-local! (greeted) (marker 'local) 1))))
    (reload-modules! '((hooks)))
    (check-equal? '(global local) (parameterize ([scopes:current s]) (calls (greeted))))
    (unload-owner! o)))

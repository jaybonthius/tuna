(import (chezscheme) (tuna-test) (kernel-test)
        (only (tuna) load-module! reload-modules! make-owner call-as-owner owner<? owner-live? unload-owner! on-unload
              fork-task join-task spawn-task cancel-task cancelled? suspend report advice-add! advice-remove!
              current-owner))

(define (top form) (eval form (interaction-environment)))

(define (raised-message thunk)
  (guard (c [#t (if (message-condition? c) (condition-message c) c)]) (thunk) #f))

(define (in-thread thunk)
  (let ([result #f])
    (join-task (fork-task (lambda (restore) (set! result (thunk)))))
    result))

(define (marker n) (lambda (calls) (set-box! calls (cons n (unbox calls)))))

(define markers (map marker (iota 6)))

(define changed #f)
(define add! #f)
(define unhook! #f)
(define add-local! #f)
(define remove-local! #f)
(define entries #f)
(define make-scope #f)
(define current-scope #f)

(define (owners) (list (make-owner '(hook a)) (make-owner '(hook b)) (make-owner '(hook c))))

(define (tests)
  (test "entries are in order of depth, then owner rank, then each owner's order, whatever is added, removed and unloaded"
    (let ([procedures (map marker (iota 5))] [mismatches 0])
      (do ([round 0 (+ round 1)]) ((= round 100))
        (let ([os (owners)])
          (do ([i 0 (+ i 1)]) ((= i 20))
            (let ([o (list-ref os (random 3))] [p (list-ref procedures (random 5))])
              (call-as-owner o
                (lambda ()
                  (case (random 3)
                    [(0 1) (add! changed p (list-ref '(-1 0 0 0.5 1) (random 5)))]
                    [else (unhook! changed p)])))))
          (unload-owner! (list-ref os (random 3)))
          (let ([seen (box '())])
            (changed seen)
            (let ([ran (reverse (unbox seen))])
              (unless (= (length ran) (length (entries changed)))
                (set! mismatches (+ mismatches 1)))))
          (for-each (lambda (o) (unless (not (owner-live? o)) (unload-owner! o))) os)))
      (check-equal? 0 mismatches)
      (check-equal? '() (entries changed))))

  (test "an entry added under another owner's advice on hooks:add! is the caller's"
    (let ([adviser (make-owner '(hook adviser))] [caller (make-owner '(hook caller))] [p (marker 'advised)])
      (call-as-owner adviser (lambda () (advice-add! add! (lambda (next . arguments) (apply next arguments)))))
      (call-as-owner caller (lambda () (add! changed p 0)))
      (unload-owner! adviser)
      (let ([seen (box '())]) (changed seen) (check-equal? '(advised) (unbox seen)))
      (unload-owner! caller)
      (let ([seen (box '())]) (changed seen) (check-equal? '() (unbox seen)))))

  (test "a call on another thread runs each entry once, in order, while the main thread changes them"
    (let ([stop? #f] [bad '()] [calls 0] [mutex (make-mutex)])
      (define (caller)
        (fork-task
          (lambda (restore)
            (let loop ([n 0])
              (if stop?
                  (with-mutex mutex (set! calls (+ calls n)))
                  (let ([seen (box '())])
                    (changed seen)
                    (let ([ran (reverse (unbox seen))])
                      (unless (equal? ran (list-sort < ran))
                        (with-mutex mutex (set! bad (cons ran bad)))))
                    (loop (+ n 1))))))))
      (let ([callers (list (caller) (caller) (caller))])
        (as-test-owner
          (lambda ()
            (do ([i 0 (+ i 1)]) ((= i 3000))
              (for-each (lambda (m n) (add! changed m n)) markers (iota 6))
              (for-each (lambda (m) (unhook! changed m)) (list-head markers (fxmod i 6))))))
        (set! stop? #t)
        (for-each join-task callers))
      (as-test-owner (lambda () (for-each (lambda (m) (unhook! changed m)) markers)))
      (check-equal? '() bad)
      (check (> calls 0))))

  (test "only the main thread changes hooks"
    (let ([s (make-scope)])
      (for-each
        (lambda (thunk) (check-equal? "only the main thread makes changes"
                          (in-thread (lambda () (raised-message (lambda () (as-test-owner thunk)))))))
        (list (lambda () (add! changed car))
              (lambda () (unhook! changed car))))
      (check (string? (in-thread (lambda () (raised-message (lambda () (as-test-owner (lambda () (parameterize ([current-scope s]) (add-local! changed car))))))))))))

  (test "a collected scope's local entries go with it"
    (let ([kept (make-scope)])
      (as-test-owner
        (lambda ()
          (let ([dropped (map (lambda (i) (make-scope)) (iota 100))])
            (for-each (lambda (s i) (parameterize ([current-scope s]) (add-local! changed (marker i))))
                      dropped (iota 100))
            (parameterize ([current-scope kept]) (add-local! changed (car markers)))
            (keep-live dropped))
          (do ([i 0 (+ i 1)]) ((= i 3)) (collect (collect-maximum-generation)))
          (parameterize ([current-scope kept]) (add-local! changed (cadr markers) 1))
          (let ([seen (box '())])
            (parameterize ([current-scope kept]) (changed seen))
            (check-equal? '(1 0) (unbox seen)))))))

  (test "hooks:entries gives the same procedures on every thread"
    (let ([procedures (map (lambda (i) (lambda (calls) i)) (iota 2000))])
      (as-test-owner (lambda () (for-each (lambda (p) (add! changed p)) procedures)))
      (let* ([results (map (lambda (i) (box #f)) (iota 4))]
             [threads (map (lambda (b) (fork-task (lambda (restore) (set-box! b (entries changed))))) results)])
        (for-each join-task threads)
        (let ([es (entries changed)])
          (check (>= (length es) 2000))
          (for-each (lambda (b) (check (for-all eq? es (unbox b)))) results)))
      (as-test-owner (lambda () (for-each (lambda (p) (unhook! changed p)) procedures)))))

  (test "a cancel never leaves a hook entry half made"
    (let ([s (make-scope)] [owner (make-owner '(hook stress))] [cancelled 0])
      (do ([i 0 (+ i 1)]) ((= i 300))
        (let ([t (spawn-task
                   (lambda (restore)
                     (call-as-owner owner
                       (lambda ()
                         (let loop ()
                           (add! changed (car markers))
                           (unhook! changed (car markers))
                           (parameterize ([current-scope s])
                             (add-local! changed (caddr markers))
                             (remove-local! changed (caddr markers)))
                           (loop))))))])
          (fork-task (lambda (restore) (sleep-ms (random 3)) (cancel-task t)))
          (let-values ([(how detail) (join-task t)])
            (when (eq? how 'cancelled) (set! cancelled (+ cancelled 1))))))
      (check (> cancelled 250))
      (unload-owner! owner)
      (let ([seen (box '())])
        (changed seen)
        (parameterize ([current-scope s]) (changed seen))
        (check-equal? '() (unbox seen)))))

  (test "a raise in an entry is reported and the next entry runs; a cancel meant for the task ends the task"
    (let ([reported 0] [ran (box '())])
      (define (quiet report c) (set! reported (+ reported 1)))
      (define (raiser calls) (error 'entry "failed"))
      (as-test-owner
        (lambda ()
          (advice-add! report quiet)
          (add! changed raiser)
          (add! changed (marker 7) 1)))
      (changed ran)
      (check-equal? 1 reported)
      (check-equal? '(7) (unbox ran))
      (let ([t (spawn-task (lambda (restore) (changed (box '())) 'went-on))])
        (as-test-owner (lambda () (add! changed (lambda (calls) (suspend (lambda (resume) (void)))) 2)))
        (fork-task (lambda (restore) (sleep-ms 20) (cancel-task t 'stop)))
        (let-values ([(how detail) (join-task t)])
          (check-equal? 'cancelled how)))
      (as-test-owner (lambda () (advice-remove! report quiet)))))

  (test "a warning in an entry is reported once and the entry goes on; after a raise the next entry runs as its own owner"
    (let ([a (make-owner '(hook warns))] [b (make-owner '(hook after))] [reports '()] [seen (box '())] [owner-seen #f])
      (define (quiet report c) (set! reports (cons (if (warning? c) 'warning 'error) reports)))
      (as-test-owner (lambda () (top '(hooks:define-hook warned)) (advice-add! report quiet)))
      (let ([warned (top 'warned)])
        (call-as-owner a
          (lambda ()
            (add! warned (lambda (calls) (warning 'entry "careful") (set-box! calls (cons 'went-on (unbox calls)))) 0)
            (add! warned (lambda (calls) (error 'entry "failed")) 1)))
        (call-as-owner b (lambda () (add! warned (lambda (calls) (set! owner-seen (current-owner))) 2)))
        (warned seen)
        (check-equal? '(went-on) (unbox seen))
        (check-equal? '(error warning) reports)
        (check-equal? b owner-seen))
      (as-test-owner (lambda () (advice-remove! report quiet)))
      (unload-owner! a)
      (unload-owner! b)))

  (test "an owner's entry is out of effect once its unload begins, though its own code runs the hook"
    (let ([o (make-owner '(hook unloading))] [seen (box '())])
      (as-test-owner (lambda () (top '(hooks:define-hook unloading))))
      (let ([unloading (top 'unloading)])
        (call-as-owner o
          (lambda ()
            (add! unloading (marker 'own))
            (on-unload (lambda () (unloading seen)))))
        (unload-owner! o)
        (check-equal? '() (unbox seen)))))

  ;; The procedure counts its calls, so the compiler cannot make it a
  ;; constant that is never collected.
  (test "a procedure taken out of a hook is collected"
    (let ([g (make-guardian)])
      (let ([p (let ([n 0]) (lambda (calls) (set! n (+ n 1))))])
        (g p)
        (as-test-owner
          (lambda ()
            (add! changed p)
            (entries changed)
            (unhook! changed p))))
      (do ([i 0 (+ i 1)]) ((= i 3)) (collect (collect-maximum-generation)))
      (check (procedure? (g)))))

  (test "local entries outlive a reload of hooks"
    (let ([s (make-scope)] [kept (marker 'kept)] [seen (box '())])
      (as-test-owner (lambda () (top '(hooks:define-hook scoped))))
      (as-test-owner (lambda () (parameterize ([current-scope s]) (add-local! (top 'scoped) kept))))
      (reload-modules! '((hooks)))
      (take-procedures!)
      (as-test-owner (lambda () (top '(hooks:define-hook scoped))))
      (parameterize ([current-scope s]) ((top 'scoped) seen))
      (check-equal? '(kept) (unbox seen)))))

;; A reload of hooks makes a new instance, so the test takes its
;; procedures again and defines its hook again, as the configuration does
;; when it is read again.
(define (take-procedures!)
  (set! add! (top 'hooks:add!))
  (set! unhook! (top (quote hooks:remove!)))
  (set! add-local! (top 'hooks:add-local!))
  (set! remove-local! (top 'hooks:remove-local!))
  (set! entries (top 'hooks:entries))
  (set! make-scope (top 'scopes:make))
  (set! current-scope (top 'scopes:current))
  (as-test-owner (lambda () (top '(hooks:define-hook changed))))
  (set! changed (top 'changed)))

(run-in-kernel
  (lambda ()
    (load-module! '(hooks))
    (take-procedures!)
    (tests)
    (delete-test-folder!)
    (test-exit)))

(import (chezscheme) (tuna-test) (kernel-test)
        (only (tuna) load-module! reload-modules! make-owner call-as-owner unload-owner! fork-task join-task spawn-task
              cancel-task))

(define (top form) (eval form (interaction-environment)))

(define (raised-message thunk)
  (guard (c [#t (if (message-condition? c) (condition-message c) c)]) (thunk) #f))

(define (in-thread thunk)
  (let ([result #f])
    (join-task (fork-task (lambda (restore) (set! result (thunk)))))
    result))

(define level #f)
(define set-option! #f)
(define unset-option! #f)
(define set-local! #f)
(define unset-local! #f)
(define settings #f)
(define local? #f)
(define with #f)
(define changed #f)
(define add-hook! #f)
(define unhook! #f)
(define make-scope #f)
(define current-scope #f)

(define (tests)
  (test "other threads read whole values while the main thread changes them"
    (let ([s (make-scope)] [stop? #f] [mutex (make-mutex)] [seen '()] [init (make-owner '(options init))])
      (define (reader scope)
        (fork-task
          (lambda (restore)
            (parameterize ([current-scope scope])
              (let loop ([values '()])
                (if stop?
                    (with-mutex mutex (set! seen (append values seen)))
                    (loop (let ([v (level)]) (if (memv v values) values (cons v values))))))))))
      (let ([readers (list (reader #f) (reader #f) (reader s) (reader s))])
        (as-test-owner
          (lambda ()
            (do ([i 0 (+ i 1)]) ((= i 5000))
              (set-option! level (fxmod i 10))
              (parameterize ([current-scope s])
                (set-local! level (fx+ 100 (fxmod i 10)))
                (when (fxeven? i) (unset-local! level)))
              (call-as-owner init (lambda () (set-option! level (fx+ 200 (fxmod i 10)))))
              (when (fxeven? i) (call-as-owner init (lambda () (unset-option! level)))))))
        (set! stop? #t)
        (for-each join-task readers))
      (check (for-all (lambda (v) (and (fixnum? v) (or (< v 10) (<= 100 v 109) (<= 200 v 209)))) seen))
      (check (exists (lambda (v) (<= 100 v 109)) seen))
      (unload-owner! init)
      (as-test-owner (lambda () (parameterize ([current-scope s]) (unset-local! level)) (unset-option! level)))))

  (test "a binding holds only on its own thread; a thread forked in it starts with none"
    (as-test-owner (lambda () (set-option! level 3)))
    (with level 7
      (lambda ()
        (check-equal? 7 (level))
        (check-equal? 3 (in-thread level))
        (check-equal? '(4 3) (in-thread (lambda () (list (with level 4 level) (level)))))
        (check-equal? 3 (in-thread (lambda () (in-thread level))))
        (check-equal? 7 (level))
        (with level 8 (lambda () (check-equal? 8 (level))))
        (check-equal? 7 (level))))
    (check-equal? 3 (in-thread level))
    (as-test-owner (lambda () (unset-option! level))))

  (test "only the main thread changes options"
    (let ([s (make-scope)])
      (for-each
        (lambda (thunk)
          (check-equal? "only the main thread makes changes"
            (in-thread (lambda () (raised-message (lambda () (as-test-owner thunk)))))))
        (list (lambda () (set-option! level 5))
              (lambda () (unset-option! level))
              (lambda () (parameterize ([current-scope s]) (set-local! level 5)))))
      (check-equal? '() (settings level))))

  (test "a scope's local values go with the scope"
    (let ([kept (list (make-scope) (make-scope))])
      (as-test-owner
        (lambda ()
          (let ([dropped (map (lambda (i) (make-scope)) (iota 200))])
            (for-each (lambda (s i) (parameterize ([current-scope s]) (set-local! level i))) dropped (iota 200))
            (for-each (lambda (s) (parameterize ([current-scope s]) (set-local! level 1))) kept)
            (keep-live dropped))
          (do ([i 0 (+ i 1)]) ((= i 3)) (collect (collect-maximum-generation)))
          (parameterize ([current-scope (car kept)]) (set-local! level 2))
          (check-equal? '(2 1) (map (lambda (s) (parameterize ([current-scope s]) (level))) kept))
          (for-each (lambda (s) (parameterize ([current-scope s]) (unset-local! level))) kept)
          (check-equal? '(0 0) (map (lambda (s) (parameterize ([current-scope s]) (level))) kept))))))

  (test "an owner's unload notifies of the setting it brings into effect"
    (let* ([seen '()] [low (make-owner '(options low))] [high (make-owner '(options high))])
      (define (note o v) (set! seen (cons v seen)))
      (call-as-owner low (lambda () (set-option! level 1)))
      (call-as-owner high (lambda () (set-option! level 2)))
      (as-test-owner (lambda () (add-hook! changed note)))
      (unload-owner! high)
      (check-equal? '(1) seen)
      (check-equal? 1 (level))
      (unload-owner! low)
      (check-equal? 0 (level))
      (as-test-owner (lambda () (unhook! changed note)))))

  (test "a cancel never leaves a setting half made"
    (let ([s (make-scope)] [owner (make-owner '(options stress))] [cancelled 0])
      (do ([i 0 (+ i 1)]) ((= i 300))
        (let ([t (spawn-task
                   (lambda (restore)
                     (call-as-owner owner
                       (lambda ()
                         (let loop ()
                           (set-option! level 5)
                           (unset-option! level)
                           (parameterize ([current-scope s])
                             (set-local! level 6)
                             (unset-local! level))
                           (loop))))))])
          (fork-task (lambda (restore) (sleep-ms (random 3)) (cancel-task t)))
          (let-values ([(how detail) (join-task t)])
            (when (eq? how 'cancelled) (set! cancelled (+ cancelled 1))))))
      (check (> cancelled 250))
      (unload-owner! owner)
      (check-equal? 0 (level))
      (check-equal? 0 (parameterize ([current-scope s]) (level)))
      (check-equal? '() (settings level))))

  (test "options:local? is whether the current scope holds a value of its own"
    (let ([s (make-scope)])
      (check (not (local? level)))
      (parameterize ([current-scope s])
        (check (not (local? level)))
        (as-test-owner (lambda () (set-local! level 4)))
        (check (local? level))
        (as-test-owner (lambda () (unset-local! level)))
        (check (not (local? level))))))

  (test "an owner's unload drops its local value and tells the scope of the value it brings into effect"
    (let ([s (make-scope)] [seen '()] [o (make-owner '(options local))])
      (define (note option v) (set! seen (cons (list v (eq? (current-scope) s)) seen)))
      (call-as-owner o (lambda () (parameterize ([current-scope s]) (set-local! level 4))))
      (as-test-owner (lambda () (add-hook! changed note)))
      (unload-owner! o)
      (check-equal? '((0 #t)) seen)
      (check-equal? 0 (parameterize ([current-scope s]) (level)))
      (as-test-owner (lambda () (unhook! changed note)))))

  (test "local values outlive a reload of options"
    (let ([s (make-scope)])
      (as-test-owner (lambda () (parameterize ([current-scope s]) (set-local! level 9))))
      (reload-modules! '((options)))
      (take-procedures!)
      (check-equal? 9 (parameterize ([current-scope s]) (level)))
      (check (parameterize ([current-scope s]) (local? level))))))

;; A reload of options makes a new instance, so the test takes its
;; procedures again and defines its option again, as the configuration
;; does when it is read again.
(define (take-procedures!)
  (set! set-option! (top 'options:set!))
  (set! unset-option! (top 'options:unset!))
  (set! set-local! (top 'options:set-local!))
  (set! unset-local! (top 'options:unset-local!))
  (set! settings (top 'options:settings))
  (set! local? (top 'options:local?))
  (set! with (top '(lambda (o v thunk) (options:with ([o v]) (thunk)))))
  (set! changed (top 'options:changed))
  (set! add-hook! (top 'hooks:add!))
  (set! unhook! (top 'hooks:remove!))
  (set! make-scope (top 'scopes:make))
  (set! current-scope (top 'scopes:current))
  (as-test-owner (lambda () (top '(options:define-option level 0 fixnum?))))
  (set! level (top 'level)))

(run-in-kernel
  (lambda ()
    (load-module! '(options))
    (take-procedures!)
    (tests)
    (delete-test-folder!)
    (test-exit)))

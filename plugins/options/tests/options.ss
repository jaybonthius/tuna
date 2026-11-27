(import (tuna) (test) (options) (hooks) (scopes) (rename (only (chezscheme) sleep) (sleep chez:sleep)))

;; The kernel reports the end of every task a cancel ends, and the stress
;; test cancels hundreds; any other report still fails the file.
(advice-add! report (lambda (next c) (unless (cancelled? c) (next c))))

(define (sleep-ms ms)
  (chez:sleep (make-time 'time-duration (* (mod ms 1000) 1000000) (quotient ms 1000))))

(define (raised-message thunk)
  (guard (c [#t (if (message-condition? c) (condition-message c) c)]) (thunk) #f))

(define (in-thread thunk)
  (let ([result #f])
    (join-task (fork-task (lambda (restore) (set! result (thunk)))))
    result))

(define as-test-owner
  (let ([owner #f])
    (lambda (thunk)
      (unless (and owner (owner-live? owner)) (set! owner (make-owner '(test))))
      (call-as-owner owner thunk))))

(define changes '())

(options:define-option level 0 fixnum?)
(options:define-option width 70 fixnum? "Width of filled lines."
  (lambda (v) (set! changes (cons (list v (scopes:current) (current-owner)) changes))))
(options:define-option name "x" string?)

;; A module's option is defined again whenever the module reloads, and the
;; binding a test holds is the old instance's, so it reads the option anew.
(define (margin) (eval 'margins:margin (environment '(margins))))

;; Chez finds a module stale when its source is newer than its object, and
;; file times step with the kernel's clock tick, 1 to 10 ms, so a rewrite
;; in the tick of the last compile would look unchanged.
(define (write-module! name text)
  (suspend (lambda (resume) (fork-task (lambda (restore) (sleep-ms 10) (resume void)))))
  (call-with-output-file (string-append (getenv "HOME") "/.config/tuna/lib/" name ".sls")
    (lambda (p) (put-string p text))
    'replace))

(test "a read gives the innermost binding, else the local value, else the setting, else the default"
  (let ([o (make-owner '(read order))] [s (scopes:make)])
    (check-equal? 0 (level))
    (call-as-owner o (lambda () (options:set! level 1)))
    (check-equal? 1 (level))
    (parameterize ([scopes:current s])
      (call-as-owner o (lambda () (options:set-local! level 2)))
      (check-equal? 2 (level))
      (options:with ([level 3])
        (check-equal? 3 (level))
        (check-equal? 1 (options:setting level))))
    (check-equal? 1 (level))
    (unload-owner! o)
    (check-equal? 0 (level))
    (check-equal? 0 (options:default level))))

(test "the highest-ranked owner's setting is in effect, and settings lists each owner's, that one first"
  (let* ([low (make-owner '(rank low))] [high (make-owner '(rank high))])
    (call-as-owner high (lambda () (options:set! level 2)))
    (call-as-owner low (lambda () (options:set! level 1)))
    (check-equal? 2 (level))
    (check-equal? '(((rank high) 2) ((rank low) 1)) (options:settings level))
    (call-as-owner high (lambda () (options:unset! level)))
    (check-equal? 1 (level))
    (unload-owner! low)
    (unload-owner! high)))

(test "options:set! takes several options, and checks every value before setting any"
  (let ([o (make-owner '(several))])
    (call-as-owner o (lambda () (options:set! level 5 name "y")))
    (check-equal? '(5 "y") (list (level) (name)))
    (call-as-owner o (lambda () (check-raises assertion-violation? (options:set! level 6 name 'not-a-string))))
    (check-equal? '(5 "y") (list (level) (name)))
    (call-as-owner o (lambda () (options:unset! level name)))
    (check-equal? '(0 "x") (list (level) (name)))
    (unload-owner! o)))

(test "options:unset! takes back only the caller's own setting"
  (let* ([plugin (make-owner '(plugin setting))] [user (make-owner '(user setting))])
    (call-as-owner plugin (lambda () (options:set! level 4)))
    (call-as-owner user (lambda () (options:unset! level)))
    (check-equal? 4 (level))
    (unload-owner! user)
    (unload-owner! plugin)))

(test "a change of value calls on-change as the defining module, with the scope bound, then options:changed"
  (let ([o (make-owner '(changing))] [s (scopes:make)] [told '()])
    (define (note option v) (set! told (cons (list option v) told)))
    (as-test-owner (lambda () (hooks:add! options:changed note)))
    (set! changes '())
    (call-as-owner o (lambda () (options:set! width 80)))
    (call-as-owner o (lambda () (options:set! width 80)))
    (call-as-owner o (lambda () (parameterize ([scopes:current s]) (options:set-local! width 90))))
    (check-equal? (list (list 80 #f (current-owner)) (list 90 s (current-owner))) (reverse changes))
    (check-equal? (list (list width 80) (list width 90)) (reverse told))
    (unload-owner! o)
    (unload-owner! (as-test-owner current-owner))))

(test "a reload with a new check keeps the settings it accepts and takes back the rest with a warning"
  (write-module! "margins" "#!tuna\n(import (options))\n(options:define-option margin 0 fixnum?)\n")
  (load-module! '(margins))
  (let* ([kept (make-owner '(kept setting))] [failed (make-owner '(failed setting))] [warnings '()])
    (define (keep next c) (set! warnings (cons c warnings)))
    (call-as-owner kept (lambda () (options:set! (margin) 60)))
    (call-as-owner failed (lambda () (options:set! (margin) 90)))
    (advice-add! report keep)
    (write-module! "margins" "#!tuna\n(import (options))\n(options:define-option margin 0 (lambda (v) (and (fixnum? v) (< v 80))))\n")
    (reload-modules! '((margins)))
    (advice-remove! report keep)
    (check-equal? 1 (length warnings))
    (check (warning? (car warnings)))
    (check-equal? '(((kept setting) 60)) (options:settings (margin)))
    (check-equal? 60 ((margin)))
    (unload-owner! failed)
    (unload-owner! kept)))

(test "a default that fails the check is refused"
  (write-module! "odd-default" "#!tuna\n(import (options))\n(options:define-option odd-default 'x fixnum?)\n")
  (check-raises assertion-violation? (load-module! '(odd-default))))

(test "options:with checks its values, survives a pause, and parameterize refuses an option"
  (check-raises assertion-violation? (options:with ([level 'x]) (level)))
  (options:with ([level 7])
    (suspend (lambda (resume) (fork-task (lambda (restore) (sleep-ms 1) (resume void)))))
    (check-equal? 7 (level)))
  (check-raises assertion-violation? (parameterize ([level 3]) (level))))

(test "options:set-local! needs a current scope, and local? says whether the scope holds a value of its own"
  (let ([s (scopes:make)])
    (check-raises assertion-violation? (as-test-owner (lambda () (options:set-local! level 4))))
    (check (not (options:local? level)))
    (parameterize ([scopes:current s])
      (check (not (options:local? level)))
      (options:with ([level 5]) (check (not (options:local? level))))
      (as-test-owner (lambda () (options:set-local! level 4)))
      (check (options:local? level))
      (as-test-owner (lambda () (options:unset-local! level)))
      (check (not (options:local? level))))))

(test "an option is an option, with its documentation"
  (check (options:option? level))
  (check (not (options:option? car)))
  (check-equal? "Width of filled lines." (options:documentation width))
  (check-equal? #f (options:documentation level)))

(test "an option a module defines is a changeable procedure: advice on it changes what a read gives, past settings and bindings, until its owner unloads"
  (let ([o (make-owner '(advising))] [margin (margin)])
    (call-as-owner o (lambda () (advice-add! margin (lambda (next) (+ (next) 1)))))
    (as-test-owner (lambda () (options:set! margin 10)))
    (check-equal? '(11 21) (list (margin) (options:with ([margin 20]) (margin))))
    (unload-owner! o)
    (check-equal? 10 (margin))
    (as-test-owner (lambda () (options:unset! margin)))))

(test "other threads read whole values while the main thread changes them"
  (let ([s (scopes:make)] [stop? #f] [mutex (make-mutex)] [seen '()] [init (make-owner '(options init))])
    (define (reader scope)
      (fork-task
        (lambda (restore)
          (parameterize ([scopes:current scope])
            (let loop ([values '()])
              (if stop?
                  (with-mutex mutex (set! seen (append values seen)))
                  (loop (let ([v (level)]) (if (memv v values) values (cons v values))))))))))
    (let ([readers (list (reader #f) (reader #f) (reader s) (reader s))])
      (as-test-owner
        (lambda ()
          (do ([i 0 (+ i 1)]) ((= i 5000))
            (options:set! level (fxmod i 10))
            (parameterize ([scopes:current s])
              (options:set-local! level (fx+ 100 (fxmod i 10)))
              (when (fxeven? i) (options:unset-local! level)))
            (call-as-owner init (lambda () (options:set! level (fx+ 200 (fxmod i 10)))))
            (when (fxeven? i) (call-as-owner init (lambda () (options:unset! level)))))))
      (set! stop? #t)
      (for-each join-task readers))
    (check (for-all (lambda (v) (and (fixnum? v) (or (< v 10) (<= 100 v 109) (<= 200 v 209)))) seen))
    (check (exists (lambda (v) (<= 100 v 109)) seen))
    (unload-owner! init)
    (unload-owner! (as-test-owner current-owner))))

(test "a binding holds only on its own thread; a thread forked in it starts with none"
  (as-test-owner (lambda () (options:set! level 3)))
  (options:with ([level 7])
    (check-equal? 7 (level))
    (check-equal? 3 (in-thread level))
    (check-equal? '(4 3) (in-thread (lambda () (list (options:with ([level 4]) (level)) (level)))))
    (check-equal? 3 (in-thread (lambda () (in-thread level))))
    (check-equal? 7 (level))
    (options:with ([level 8]) (check-equal? 8 (level)))
    (check-equal? 7 (level)))
  (check-equal? 3 (in-thread level))
  (unload-owner! (as-test-owner current-owner)))

(test "only the main thread changes options"
  (let ([s (scopes:make)] [o (make-owner '(threaded))])
    (for-each
      (lambda (thunk)
        (check-equal? "only the main thread makes changes"
          (in-thread (lambda () (raised-message (lambda () (call-as-owner o thunk)))))))
      (list (lambda () (options:set! level 5))
            (lambda () (options:unset! level))
            (lambda () (parameterize ([scopes:current s]) (options:set-local! level 5)))))
    (check-equal? '() (options:settings level))
    (unload-owner! o)))

(test "a scope's local values go with the scope"
  (let ([kept (list (scopes:make) (scopes:make))])
    (as-test-owner
      (lambda ()
        (let ([dropped (map (lambda (i) (scopes:make)) (iota 200))])
          (for-each (lambda (s i) (parameterize ([scopes:current s]) (options:set-local! level i))) dropped (iota 200))
          (for-each (lambda (s) (parameterize ([scopes:current s]) (options:set-local! level 1))) kept)
          (keep-live dropped))
        (do ([i 0 (+ i 1)]) ((= i 3)) (collect (collect-maximum-generation)))
        (parameterize ([scopes:current (car kept)]) (options:set-local! level 2))
        (check-equal? '(2 1) (map (lambda (s) (parameterize ([scopes:current s]) (level))) kept))
        (for-each (lambda (s) (parameterize ([scopes:current s]) (options:unset-local! level))) kept)
        (check-equal? '(0 0) (map (lambda (s) (parameterize ([scopes:current s]) (level))) kept))))))

(test "an owner's unload notifies of the setting it brings into effect"
  (let* ([seen '()] [low (make-owner '(options low))] [high (make-owner '(options high))])
    (define (note o v) (set! seen (cons v seen)))
    (call-as-owner low (lambda () (options:set! level 1)))
    (call-as-owner high (lambda () (options:set! level 2)))
    (as-test-owner (lambda () (hooks:add! options:changed note)))
    (unload-owner! high)
    (check-equal? '(1) seen)
    (check-equal? 1 (level))
    (unload-owner! low)
    (check-equal? 0 (level))
    (unload-owner! (as-test-owner current-owner))))

(test "a cancel never leaves a setting half made"
  (let ([s (scopes:make)] [owner (make-owner '(options stress))] [cancelled 0])
    (do ([i 0 (+ i 1)]) ((= i 300))
      (let ([t (spawn-task
                 (lambda (restore)
                   (call-as-owner owner
                     (lambda ()
                       (let loop ()
                         (options:set! level 5)
                         (options:unset! level)
                         (parameterize ([scopes:current s])
                           (options:set-local! level 6)
                           (options:unset-local! level))
                         (loop))))))])
        (fork-task (lambda (restore) (sleep-ms (random 3)) (cancel-task t)))
        (let-values ([(how detail) (join-task t)])
          (when (eq? how 'cancelled) (set! cancelled (+ cancelled 1))))))
    (check (> cancelled 250))
    (unload-owner! owner)
    (check-equal? 0 (level))
    (check-equal? 0 (parameterize ([scopes:current s]) (level)))
    (check-equal? '() (options:settings level))))

(test "an owner's unload drops its local value and tells the scope of the value it brings into effect"
  (let ([s (scopes:make)] [seen '()] [o (make-owner '(options local))])
    (define (note option v) (set! seen (cons (list v (eq? (scopes:current) s)) seen)))
    (call-as-owner o (lambda () (parameterize ([scopes:current s]) (options:set-local! level 4))))
    (as-test-owner (lambda () (hooks:add! options:changed note)))
    (unload-owner! o)
    (check-equal? '((0 #t)) seen)
    (check-equal? 0 (parameterize ([scopes:current s]) (level)))
    (unload-owner! (as-test-owner current-owner))))

(test "settings and local values outlive a reload of options"
  (let ([s (scopes:make)] [o (make-owner '(reloaded))])
    (call-as-owner o
      (lambda ()
        (options:set! (margin) 8)
        (parameterize ([scopes:current s]) (options:set-local! (margin) 9))))
    (reload-modules! '((options)))
    (check-equal? 8 ((margin)))
    (check-equal? 9 (parameterize ([scopes:current s]) ((margin))))
    (check (parameterize ([scopes:current s]) (options:local? (margin))))
    (unload-owner! o)))

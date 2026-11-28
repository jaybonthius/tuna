(import (tuna) (test) (test-runner) (timers)
        (owners greet) (owners spell) (owners display) (owners theme)
        (rename (only (chezscheme) fork-thread) (fork-thread chez:fork-thread)))

(define (on-chez-thread thunk)
  (let ([result #f])
    (thread-join
      (chez:fork-thread
        (lambda ()
          (set! result (guard (c [(message-condition? c) (condition-message c)]) (thunk))))))
    result))

(define user (make-owner '(owners user)))

(test "current-owner names the module code runs for, and this-module the module the code is written in"
  (let ([spell (module-owner '(owners spell))])
    (check-equal? '(owners greet) (call-as-owner spell owners/greet:module-name))
    (check-equal? spell (call-as-owner spell current-owner))
    (check-raises violation? (eval '(this-module) (interaction-environment)))))

(test "loaded-modules lists the modules in the order they loaded, and one loaded again goes last"
  (let ([mine (lambda () (filter (lambda (name) (eq? (car name) 'owners)) (loaded-modules)))])
    (check-equal? '((owners greet) (owners spell) (owners display) (owners theme)) (mine))
    (unload-owner! (module-owner '(owners spell)))
    (load-module! '(owners spell))
    (check-equal? '((owners greet) (owners display) (owners theme) (owners spell)) (mine))))

(test "a changeable procedure is named by its exported name"
  (check-equal? "#<procedure owners/greet:text>" (format "~s" owners/greet:text)))

(test "override-remove! removes every module's override of a definition, as the current owner's change"
  (check-equal? "-- themed --" (owners/display:mode-line))
  (call-as-owner user (lambda () (override-set! owners/display:mode-line (lambda () "-- custom --"))))
  (check-equal? "-- custom --" (owners/display:mode-line))
  (call-as-owner user (lambda () (override-remove! owners/display:mode-line)))
  (check-equal? "-- plain --" (owners/display:mode-line))
  (check-equal? '(((owners user) removal) ((owners theme) override) ((owners display) define))
                (map (lambda (c) (list (owner-name (car c)) (cadr c))) (definition-changes owners/display:mode-line)))
  (check-equal? '(removal) (map car (owner-changes user)))
  (check-raises assertion-violation? (call-as-owner user (lambda () (override-remove! car)))))

(test "a module's removal goes when it unloads"
  (load-module! '(owners remover))
  (check-equal? '(owners remover) (owner-name (car (car (definition-changes owners/display:mode-line)))))
  (unload-owner! (module-owner '(owners remover)))
  (check-equal? '(owners user) (owner-name (car (car (definition-changes owners/display:mode-line))))))

(test "a thread Chez forked acts for no owner, so it neither changes nor spawns until it names one"
  (check-equal? "this code acts for no owner; name one with call-as-owner"
    (on-chez-thread (lambda () (override-remove! owners/display:mode-line))))
  (check-equal? #f (on-chez-thread current-owner))
  (check-equal? #f (call-as-owner (module-owner '(owners greet)) (lambda () (on-chez-thread current-owner))))
  (check-equal? "this thread acts for no owner; name one with call-as-owner"
    (on-chez-thread (lambda () (spawn-task (lambda (restore) (void))))))
  (let ([posted (on-chez-thread
                  (lambda ()
                    (call-as-owner (module-owner '(owners greet))
                      (lambda () (spawn-task (lambda (restore) (current-owner)))))))])
    (check-equal? (module-owner '(owners greet)) (test-runner:join posted))))

(test "batch-ended's advice runs as its owner, and a raise in it is reported and the loop goes on"
  (let ([owners '()] [reported '()] [raised? #f])
    (define (note-owner ended) (set! owners (cons (current-owner) owners)) (ended))
    (define (boom ended) (unless raised? (set! raised? #t) (car '())) (ended))
    (define (keep next c) (set! reported (cons c reported)))
    (call-as-owner user (lambda () (advice-add! batch-ended note-owner) (advice-add! report keep)))
    (test-runner:wait-until (lambda () (pair? owners)))
    (check (for-all (lambda (o) (eq? o user)) owners))
    (call-as-owner user (lambda () (advice-add! batch-ended boom)))
    (test-runner:wait-until (lambda () (pair? reported)))
    (call-as-owner user (lambda () (advice-remove! batch-ended boom) (advice-remove! batch-ended note-owner) (advice-remove! report keep)))
    (check (assertion-violation? (car reported)))
    (let ([t (spawn-task (lambda (restore) 'goes-on))])
      (check-equal? 'goes-on (test-runner:join t)))))

(test "a module's advice runs as the module, and what it starts goes when it unloads"
  (load-module! '(owners disp))
  (let ([redraws (eval 'owners/disp:redraws (environment '(owners disp)))])
    (test-runner:wait-until (lambda () (> (redraws) 0))))
  (check-equal? '(advice define define) (map car (owner-changes (module-owner '(owners disp)))))
  (check-equal? 1 (length (timers:live)))
  (unload-owner! (module-owner '(owners disp)))
  (check-equal? '() (timers:live)))

(test "what batch-ended's advice spawns runs in the next batch"
  (let ([order '()] [once? #f])
    (define (post-once ended)
      (unless once?
        (set! once? #t)
        (set! order (cons 'batch-ended order))
        (call-as-owner user (lambda () (spawn-task (lambda (restore) (set! order (cons 'posted order)))))))
      (ended))
    (call-as-owner user (lambda () (advice-add! batch-ended post-once)))
    (set! order (cons 'form order))
    (test-runner:wait-until (lambda () (= 3 (length order))))
    (call-as-owner user (lambda () (advice-remove! batch-ended post-once)))
    (check-equal? '(form batch-ended posted) (reverse order))))

(test "a definition evaluated again in its module's file keeps the exported name"
  (eval-in-module '(define (mode-line) "-- again --") '(owners display))
  (call-as-owner user (lambda () (override-remove! owners/display:mode-line)))
  (unload-owner! user)
  (unload-owner! (module-owner '(owners theme)))
  (check-equal? "-- again --" (owners/display:mode-line))
  (eval-in-module '(define mode-line (lambda () "-- once more --")) '(owners display))
  (check-equal? "-- once more --" (owners/display:mode-line)))

(test "made-owner finds the live owner make-owner made under a name, until its unload ends"
  (check-equal? #f (made-owner '(owners nobody)))
  (check-equal? #f (made-owner '(owners spell)))
  (let ([kept (make-owner '(owners kept))])
    (check-equal? kept (made-owner '(owners kept)))
    (unload-owner! kept)
    (check-equal? #f (made-owner '(owners kept))))
  (check-raises assertion-violation? (made-owner 'user)))

(test "a name is a module's or a made owner's, never both"
  (check-raises assertion-violation? (make-owner '(owners spell)))
  (let ([clash (make-owner '(owners clash))])
    (call-with-output-file (string-append (getenv "HOME") "/.config/tuna/lib/owners/clash.sls")
      (lambda (p) (put-string p "#!tuna\n(define (hello) 'module)\n")))
    (check-raises error? (load-module! '(owners clash)))
    (check-raises error? (eval '(import (owners clash)) (interaction-environment)))
    (check-equal? #f (module-file '(owners clash)))
    (check-equal? clash (made-owner '(owners clash)))))

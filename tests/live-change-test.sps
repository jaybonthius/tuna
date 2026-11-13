(import (chezscheme) (tuna-test) (chez-lang loader) (tuna core modules))

(define root
  (let ([dir (format "/tmp/tuna-live-change-test-~a" (get-process-id))])
    (mkdir dir)
    dir))

;; Chez judges an object stale by file times, which the file system keeps
;; to its clock tick.
(define (write-module! name text)
  (sleep (make-time 'time-duration 10000000 0))
  (call-with-output-file (string-append root "/lib/" name ".sls")
    (lambda (p) (put-string p text))
    'replace))

(define (racer-version k)
  (format "#!tuna
(define (f x) (+ x ~a))
(define (h x) x)
(define (assign-h! g) (set! h g))
" k))

(mkdir (string-append root "/lib"))
(write-module! "racer" (racer-version 1))

(compile-file-message #f)
(install-module-lookup! (library-directories) (string-append root "/lib") (string-append root "/library")
  (string-append root "/cache"))
(install-loader!)

(load-module! '(racer))

;; The lookup tells whether a library is loaded, and which modules a module
;; whose body failed imports, only from these raises, whose condition types
;; Chez does not document. This program imports the test harness only to
;; run it.
(test "Chez raises the condition types the module lookup relies on"
  (check-raises assertion-violation? (library-version '(tuna no-such-library)))
  (check-raises violation? (library-requirements '(tuna-test) (library-requirements-options import))))

;; Compiled once, against the first instance: a caller compiled earlier
;; must follow every later instance.
(define env (environment '(chezscheme) '(tuna) '(racer)))
(define (compiled form) (eval form env))
(define call-f (compiled '(lambda (x) (racer:f x))))
(define call-h (compiled '(lambda (x) (racer:h x))))
(define assign-h! (compiled 'racer:assign-h!))

(define (on-thread thunk)
  (let ([result #f])
    (thread-join (fork-thread (lambda () (set! result (thunk)))))
    result))

(define (raised-message thunk)
  (guard (c [#t (condition-message c)]) (thunk) #f))

(define unloaded-message "module (racer) is unloaded")

(test "loading, unloading and reloading on another thread raise and change nothing"
  (check-equal? "only the main thread makes changes"
    (on-thread (lambda () (raised-message (lambda () (unload-module! '(racer)))))))
  (check-equal? "only the main thread makes changes"
    (on-thread (lambda () (raised-message (lambda () (reload-module! '(racer)))))))
  (check-equal? "only the main thread makes changes"
    (on-thread (lambda () (raised-message (lambda () (on-unload void))))))
  (check-equal? 1 (call-f 0))
  (unload-module! '(racer))
  (check-equal? "only the main thread makes changes"
    (on-thread (lambda () (raised-message (lambda () (load-module! '(racer)))))))
  (check-equal? unloaded-message (raised-message (lambda () (call-f 0))))
  (load-module! '(racer))
  (check-equal? 1 (call-f 0)))

;; A caller on another thread sees a whole definition of some version, or
;; the module unloaded, never anything in between.
(test "calls on another thread during unloads, loads and reloads"
  (let* ([done #f]
         [bad '()]
         [calls 0]
         [caller (fork-thread
                   (lambda ()
                     (let loop ()
                       (unless done
                         (let ([v (guard (c [(and (violation? c) (message-condition? c))
                                             (condition-message c)])
                                    (call-f 0))])
                           (unless (or (memv v '(1 2 3)) (equal? v unloaded-message))
                             (set! bad (cons v bad))))
                         (set! calls (+ calls 1))
                         (loop)))))])
    (do ([i 0 (+ i 1)]) ((= i 30))
      (write-module! "racer" (racer-version (+ 1 (mod i 3))))
      (reload-module! '(racer))
      (unload-module! '(racer))
      (load-module! '(racer)))
    (set! done #t)
    (thread-join caller)
    (check-equal? '() bad)
    (check (> calls 0))
    (check-equal? 3 (call-f 0))))

;; The module's own assignment may run on any thread; one that finishes
;; after the unload must not bring the definition back.
(test "a module's own assignments on other threads while it unloads"
  (do ([trial 0 (+ trial 1)]) ((= trial 200))
    (let* ([stop #f]
           [threads
            (map (lambda (i)
                   (fork-thread
                     (lambda ()
                       (let loop ()
                         (guard (c [(violation? c) #f])
                           (assign-h! (lambda (x) i)))
                         (unless stop (loop))))))
                 '(1 2 3))])
      (unload-module! '(racer))
      (set! stop #t)
      (for-each thread-join threads)
      (check-equal? unloaded-message (raised-message (lambda () (call-h 0))))
      (load-module! '(racer))
      (check-equal? 0 (call-h 0)))))

(test "a reload that succeeds unloads a module whose raise its body caught"
  (write-module! "catcher" "#!tuna\n(define caught 'nothing)\n")
  (load-module! '(catcher))
  (write-module! "kaboom" "#!tuna\n(define (x) 1)\n(car '())\n")
  (write-module! "catcher" "#!tuna\n(define caught (guard (c [#t 'caught]) (invoke-library '(kaboom))))\n")
  (reload-module! '(catcher))
  (check-equal? 'caught (eval 'catcher:caught (environment '(catcher))))
  (check (member '(kaboom) (unloaded-modules))))

(system (format "rm -rf '~a'" root))
(test-exit)

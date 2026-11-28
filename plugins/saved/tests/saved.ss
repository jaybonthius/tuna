(import (tuna) (test) (test-runner) (saved) (plugins) (saved-test files)
        (rename (only (chezscheme) sleep) (sleep chez:sleep)))

(define (mine name) (saved-test/files:file "user" "test-file" "saved" "saved" (string-append name ".ss")))

(define (stored name) (saved-test/files:stored (mine name)))

;; The main thread is busy on purpose while a thread waits for it, so the
;; thread keeps the deadline: on a miss it cancels the busy task with the
;; reason missed, which its test then sees instead of hanging.
(define (on-thread-wait done? busy)
  (let ([deadline (add-duration (current-time 'time-monotonic) (make-time 'time-duration 0 30))])
    (let loop ()
      (cond
        [(done?) #t]
        [(time>? (current-time 'time-monotonic) deadline) (cancel-task busy 'missed) #f]
        [else (chez:sleep (make-time 'time-duration 1000000 0)) (loop)]))))

(define (set-and-wait! datum value name)
  (saved:set! datum value)
  (saved-test/files:wait-for-stored! (mine name) value))

;; Chez finds a module stale when its source is newer than its object, and
;; file times step with the kernel's clock tick, 1 to 10 ms, so a rewrite
;; in the tick of the last compile would look unchanged.
(define (write-module! name text)
  (suspend (lambda (resume) (fork-task (lambda (restore) (chez:sleep (make-time 'time-duration 10000000 0)) (resume void)))))
  (saved-test/files:write-text! (string-append (getenv "HOME") "/.config/tuna/lib/" name ".sls") text))

(define (again-file) (saved-test/files:file "user" "again" "kind.ss"))

(define (kind) ((eval 'again:kind (environment '(again)))))

(saved:define-saved answers '() list?)
(saved:define-saved flag #t boolean?)
(saved:define-saved each-0 0 fixnum?)
(saved:define-saved each-1 0 fixnum?)
(saved:define-saved each-2 0 fixnum?)
(saved:define-saved each-3 0 fixnum?)
(saved:define-saved shared '() list?)
(saved:define-saved big '() list?)
(saved:define-saved deep '() list?)
(saved:define-saved raced '() list?)
(saved:define-saved written 0 fixnum?)
(saved:define-saved counted 0 fixnum?)
(saved:define-saved |a/b%c| 0 fixnum?)
(saved:define-saved |..| 0 fixnum?)

(test "a datum starts as its initial value, and a reload of its module keeps its value"
  (check-equal? '() (answers))
  (saved:set! answers '("yes"))
  (check-equal? '("yes") (answers))
  (check (saved:saved? answers))
  (check (not (saved:saved? car)))
  (check (not (saved:saved? (lambda () '()))))
  (write-module! "again" "#!tuna\n(import (saved))\n(saved:define-saved kind '(1 2) list?)\n")
  (load-module! '(again))
  (saved:set! (eval 'again:kind (environment '(again))) '(1 2 3))
  (reload-modules! '((again)))
  (check-equal? '(1 2 3) (kind)))

(test "a reload whose check the value fails moves the value aside, with a warning"
  (saved-test/files:wait-for-stored! (again-file) '(1 2 3))
  (let ([reported (test-runner:reports-during
                    (lambda ()
                      (write-module! "again" "#!tuna\n(import (saved))\n(saved:define-saved kind 0 fixnum?)\n")
                      (reload-modules! '((again))))
                    1)])
    (check-equal? 1 (length reported))
    (check (warning? (car reported))))
  (check-equal? 0 (kind))
  (test-runner:wait-until (lambda () (not (file-exists? (again-file)))))
  (check-equal? '(1 2 3) (saved-test/files:stored (string-append (again-file) ".rejected")))
  (write-module! "again" "#!tuna\n(import (saved))\n(saved:define-saved kind \"none\" string?)\n")
  (reload-modules! '((again)))
  (check-equal? "none" (kind)))

(test "saved:set! checks the value and writes it as it was when set; only saved:set! sets it"
  (check-raises assertion-violation? (saved:set! answers 5))
  (check-raises assertion-violation? (saved:set! answers (list car)))
  (check-raises assertion-violation? (saved:set! car '()))
  (check-raises assertion-violation? (answers '("no")))
  (check-equal? '("yes") (answers))
  (let ([v (list (string-copy "before") (vector 1))])
    (saved:set! answers v)
    (string-set! (car v) 0 #\X)
    (vector-set! (cadr v) 0 2)
    (saved-test/files:wait-for-stored! (mine "answers") '("before" #(1)))))

(test "saved:remove! gives the initial value back and deletes the file"
  (set-and-wait! answers '("kept") "answers")
  (saved:remove! answers)
  (check-equal? '() (answers))
  (test-runner:wait-until (lambda () (not (file-exists? (mine "answers")))))
  (check-raises assertion-violation? (saved:remove! car)))

(test "the initial value must be plain data that passes the check"
  (for-each
    (lambda (name definition)
      (write-module! name (string-append "#!tuna\n(import (saved))\n" definition "\n"))
      (check-raises assertion-violation? (load-module! (list (string->symbol name)))))
    '("wrong-value" "not-plain" "no-check")
    '("(saved:define-saved wrong 'x list?)" "(saved:define-saved wrong (vector car) vector?)"
      "(saved:define-saved wrong '() 'list?)")))

(test "any thread sets and removes saved data, but only the main thread defines it"
  (join-task (fork-task (lambda (restore) (saved:set! answers '("from a thread")))))
  (check-equal? '("from a thread") (answers))
  (join-task (fork-task (lambda (restore) (saved:remove! answers))))
  (check-equal? '() (answers))
  (check-equal? "only the main thread makes changes"
    (let ([outcome #f])
      ;; A definition is a top-level form, so the thread evaluates one there.
      (join-task (fork-task (lambda (restore) (set! outcome (guard (c [#t (condition-message c)]) (eval '(saved:define-saved x 0 fixnum?) (interaction-environment)))))))
      outcome)))

(test "a module's stored value is read when it loads; one unreadable, not plain data or failing its check is moved aside with a warning"
  (let ([hist (lambda (name) (saved-test/files:file "tuna" "saved-test" "hist" name))])
    (for-each
      (lambda (name text) (saved-test/files:write-text! (hist (string-append name ".ss")) text))
      '("stored" "broken" "trailing" "empty" "boxed" "cyclic" "wrong")
      '("42" "(unclosed" "1 2" "" "#&1" "#0=(1 . #0#)" "\"text\""))
    (let ([reported (test-runner:reports-during (lambda () (load-module! '(saved-test hist))) 6)])
      (check-equal? 6 (length reported))
      (check (for-all warning? reported)))
    (let ([env (environment '(saved-test hist))])
      (check-equal? '(("first") 42 0 0 0 0 () 0)
        (map (lambda (name) ((eval (string->symbol (string-append "saved-test/hist:" name)) env)))
             '("entries" "stored" "broken" "trailing" "empty" "boxed" "cyclic" "wrong"))))
    (saved-test/files:wait-for-stored! (hist "entries.ss") '("first"))
    (check-equal? '("boxed.ss.rejected" "broken.ss.rejected" "cyclic.ss.rejected" "empty.ss.rejected" "entries.ss"
                    "stored.ss" "trailing.ss.rejected" "wrong.ss.rejected")
                  (sort string<? (directory-list (saved-test/files:file "tuna" "saved-test" "hist"))))))

(test "unloading a module leaves its saved data, and a procedure held from before is the same one"
  (let* ([env (environment '(saved-test hist))] [held (eval 'saved-test/hist:entries env)])
    (unload-owner! (module-owner '(saved-test hist)))
    (load-module! '(saved-test hist))
    (let ([entries (eval 'saved-test/hist:entries (environment '(saved-test hist)))])
      (check-equal? '("first" "first") (entries))
      (check (eq? held entries)))))

(test "a check that never returns can be ended, and the stored file stays"
  (let ([x (saved-test/files:file "tuna" "saved-test" "looping" "x.ss")])
    (saved-test/files:write-text! x "1")
    (let ([t (spawn-task (lambda (restore) (load-module! '(saved-test looping))))])
      (fork-task (lambda (restore) (when (on-thread-wait (lambda () (getprop 'saved-test 'checking #f)) t) (cancel-task t))))
      (let ([reported (test-runner:reports-during
                        (lambda () (check-equal? 'cancelled (call-with-values (lambda () (join-task t)) (lambda (how detail) how))))
                        0)])
        (check-equal? '() reported)))
    (check (file-exists? x))))

(test "a stored value is read with immutable strings and bytevectors, and #f is written as a value"
  (saved-test/files:write-text! (saved-test/files:file "tuna" "saved-test" "loaded" "loaded.ss") "(\"text\" #vu8(1 2) #(\"inner\"))")
  (load-module! '(saved-test loaded))
  (let ([v ((eval 'saved-test/loaded:loaded (environment '(saved-test loaded))))])
    (check-equal? '("text" #vu8(1 2) #("inner")) v)
    (check (immutable-string? (car v)))
    (check (immutable-bytevector? (cadr v)))
    (check (immutable-string? (vector-ref (caddr v) 0))))
  (saved:set! flag #f)
  (test-runner:wait-until (lambda () (file-exists? (mine "flag"))))
  (check-equal? #f (stored "flag")))

(test "sets from many threads leave each file holding its datum's last value"
  (let ([each (list each-0 each-1 each-2 each-3)])
    (for-each join-task
      (map (lambda (s i)
             (fork-task
               (lambda (restore)
                 (do ([n 0 (+ n 1)]) ((= n 300))
                   (saved:set! s n)
                   (saved:set! shared (list i n))))))
           each (iota 4)))
    (for-each (lambda (n) (saved-test/files:wait-for-stored! (mine (format "each-~a" n)) 299)) (iota 4))
    (saved-test/files:wait-for-stored! (mine "shared") (shared))
    (check-equal? 299 (cadr (shared)))))

(test "a reader never sees part of a file, and shared structure is written once and read back shared"
  (let ([reading #t] [partial 0] [reads 0])
    (let ([reader (fork-task
                    (lambda (restore)
                      (let loop ()
                        (when reading
                          (let ([v (stored "big")])
                            (when v
                              (set! reads (+ reads 1))
                              (unless (and (list? v) (= (length v) 5000) (for-all (lambda (s) (equal? s (car v))) v))
                                (set! partial (+ partial 1)))))
                          (loop)))))])
      (do ([n 0 (+ n 1)]) ((= n 40))
        (saved:set! big (make-list 5000 (format "version ~a" n)))
        (suspend (lambda (resume) (spawn-task (lambda (restore) (resume void))))))
      (saved-test/files:wait-for-stored! (mine "big") (big))
      (set! reading #f)
      (join-task reader)
      (check (> reads 0))
      (check-equal? 0 partial)))
  (saved:set! deep (let loop ([i 0] [x '()]) (if (= i 40) x (loop (+ i 1) (cons x x)))))
  (test-runner:wait-until (lambda () (stored "deep")))
  (let ([back (stored "deep")]) (check (eq? (car back) (cdr back)))))

(test "a removal racing with sets never leaves the removed value's file behind"
  (let ([mismatches 0])
    (do ([round 0 (+ round 1)]) ((= round 20))
      (for-each join-task
        (map (lambda (i)
               (fork-task
                 (lambda (restore)
                   (do ([n 0 (+ n 1)]) ((= n 200))
                     (if (= (random 3) 0) (saved:remove! raced) (saved:set! raced (list i n)))))))
             (iota 4)))
      (when (odd? round) (saved:remove! raced))
      (set-and-wait! written (+ (written) 1) "written")
      (unless (if (null? (raced)) (not (stored "raced")) (equal? (raced) (stored "raced")))
        (set! mismatches (+ mismatches 1))))
    (check-equal? 0 mismatches)))

(test "a datum set in batch-ended's advice makes no batch of its own"
  (let ()
    (define (batches-while-idle set?)
      (let ([batches 0])
        (define (counting ended)
          (set! batches (+ batches 1))
          (when set? (saved:set! counted batches))
          (ended))
        (advice-add! batch-ended counting)
        (suspend (lambda (resume) (fork-task (lambda (restore) (chez:sleep (make-time 'time-duration 50000000 0)) (resume void)))))
        (advice-remove! batch-ended counting)
        batches))
    (let* ([without (batches-while-idle #f)] [with (batches-while-idle #t)])
      (check-equal? without with)
      (saved-test/files:wait-for-stored! (mine "counted") with))))

(test "a datum's file is named by its plugin's source, its module and its name, each made safe as a file name"
  (load-module! '(saved-test util))
  (saved:set! |a/b%c| 1)
  (saved:set! |..| 1)
  (saved:set! (eval 'saved-test/util:hits (environment '(saved-test util))) 1)
  (for-each
    (lambda (path) (saved-test/files:wait-for-stored! (apply saved-test/files:file path) 1))
    '(("user" "test-file" "saved" "saved" "a%2Fb%25c.ss")
      ("user" "test-file" "saved" "saved" "%2E..ss")
      ("tuna" "saved-test" "util" "hits.ss"))))

(test "a plugin installed from a folder files its data by that folder, so a fork keeps its own"
  (let ([folder (lambda (name) (string-append (getenv "HOME") "/src/" name))])
    (for-each
      (lambda (name)
        (saved-test/files:write-text! (string-append (folder name) "/src/notes.sls")
          "#!tuna\n(import (saved))\n(saved:define-saved hits 0 fixnum?)\n"))
      '("notes" "notes-fork"))
    (plugins:install! `(use-plugin notes (local ,(folder "notes"))))
    (load-module! '(notes))
    (saved:set! (eval 'notes:hits (environment '(notes))) 3)
    (saved-test/files:wait-for-stored! (saved-test/files:file (saved-test/files:escaped (folder "notes")) "notes" "hits.ss") 3)
    (unload-owner! (module-owner '(notes)))
    (plugins:remove! 'notes)
    (plugins:install! `(use-plugin notes (local ,(folder "notes-fork"))))
    (load-module! '(notes))
    (check-equal? 0 ((eval 'notes:hits (environment '(notes)))))
    (check (file-exists? (saved-test/files:file (saved-test/files:escaped (folder "notes")) "notes" "hits.ss")))))


(test "a stored file that cannot be opened makes the load raise and stays; a deletion that fails is reported and the file stays"
  (let ([hits (saved-test/files:file "tuna" "saved-test" "locked" "hits.ss")])
    (saved-test/files:write-text! hits "1")
    (chmod hits #o000)
    (check-raises serious-condition? (load-module! '(saved-test locked)))
    (chmod hits #o644)
    (check (not (file-exists? (string-append hits ".rejected"))))
    (load-module! '(saved-test locked))
    (check-equal? 1 ((eval 'saved-test/locked:hits (environment '(saved-test locked)))))
    (chmod (path-parent hits) #o555)
    (let ([reported (test-runner:reports-during
                      (lambda () (saved:remove! (eval 'saved-test/locked:hits (environment '(saved-test locked)))))
                      1)])
      (chmod (path-parent hits) #o755)
      (check-equal? 1 (length reported))
      (check (i/o-error? (car reported))))
    (check-equal? 1 (saved-test/files:stored hits))))


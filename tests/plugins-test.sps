(import (chezscheme) (tuna-test) (chez-lang loader)
        (tuna core changes) (only (tuna core definitions) tick report advice-add! advice-remove!)
        (tuna core modules) (except (tuna core main-thread) exit)
        (tuna plugin-manager))

(define root
  (let ([dir (format "/tmp/tuna-plugins-test-~a" (get-process-id))])
    (mkdir dir)
    dir))

(define (path . parts) (apply string-append root (map (lambda (part) (string-append "/" part)) parts)))

(define (write-file! file text)
  (let loop ([dir (path-parent file)])
    (unless (file-directory? dir)
      (loop (path-parent dir))
      (mkdir dir)))
  (call-with-output-file file (lambda (p) (put-string p text)) 'replace))

;; A user's git settings, such as signing or address rewrites, would change
;; commits or addresses.
(putenv "HOME" root)
(putenv "GIT_CONFIG_NOSYSTEM" "1")

(define (make-remote! id)
  (let ([dir (path "remotes" (symbol->string id))])
    (write-file! (format "~a/~a.sls" dir id) (format "#!tuna\n(define (name) '~a)\n" id))
    (write-file! (format "~a/~a/match.sls" dir id)
      (format "(library (~a match) (export score) (import (chezscheme)) (define (score s) (string-length s)))\n" id))
    (unless (zero? (system (format "cd '~a' && git init -q -b main && git add -A && git -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false commit -qm one" dir)))
      (error 'make-remote! "git failed" id))
    (format "file://~a" dir)))

(define ids '(alpha beta gamma delta epsilon zeta))
(define addresses (map make-remote! (cons 'shared ids)))

(write-file! (path "config" "init.ss") "(import (tuna) (tuna plugins))\n")
(compile-file-message #f)
(start-plugins! (string-append (current-directory) "/build/bin/tuna") root (path "config" "init.ss") (path "config" "lib") (path "library") (path "plugins"))
(install-module-lookup! (library-directories) (path "config" "lib") (path "library") (path "cache")
  plugin-root install-missing-plugin! plugin-roots)
(install-loader!)

(define (line id) `(use-plugin ,id (git ,(format "file://~a" (path "remotes" (symbol->string id))))))

(define (configuration-lines)
  (call-with-input-file (path "config" "init.ss")
    (lambda (p)
      (let loop ()
        (let ([form (read p)])
          (cond
            [(eof-object? form) '()]
            [(and (pair? form) (eq? (car form) 'use-plugin)) (cons (cadr form) (loop))]
            [else (loop)]))))))

(define (sorted ids) (sort (lambda (a b) (string<? (symbol->string a) (symbol->string b))) ids))

(define (wait-until-called receive-done)
  (suspend (lambda (resume) (receive-done (lambda () (resume void))))))

(define (raised-message thunk)
  (guard (c [#t (if (message-condition? c) (condition-message c) c)]) (thunk) #f))

(define (tests)
  ;; Each round requests a quit at a later timer tick, so quits land all
  ;; over the reading.
  (test "a quit while the configuration's lines are read ends the reading rather than cutting the lines short"
    (write-file! (path "config" "init.ss")
      (call-with-string-output-port
        (lambda (p)
          (put-string p "(import (tuna) (tuna plugins))\n")
          (do ([i 0 (+ i 1)]) ((= i 2000))
            (fprintf p "(set-option! fill:column ~a)\n" i)))))
    (let* ([ticks 0] [quit-at #f]
           [counter (lambda (tick)
                      (tick)
                      (set! ticks (+ ticks 1))
                      (when (eqv? ticks quit-at) (request-quit!)))])
      (advice-add! tick counter)
      (read-configuration-lines!)
      (let ([total ticks])
        (check (> total 20))
        (check-equal? '()
          (filter
            (lambda (n)
              (set! ticks 0)
              (set! quit-at n)
              (not (eq? 'quit (guard (c [(quit-condition? c) 'quit]) (read-configuration-lines!) 'read))))
            (map add1 (iota (quotient total 2))))))
      (advice-remove! tick counter))
    (write-file! (path "config" "init.ss") "(import (tuna) (tuna plugins))\n")
    (read-configuration-lines!))

  (test "installs of different plugins run at once, while the main thread goes on"
    (let* ([finished-meanwhile #f]
           [tasks (map (lambda (id) (spawn-task (lambda () (install-plugin! (line id))))) ids)])
      (post! (lambda () (set! finished-meanwhile (length (filter task-done? tasks)))))
      (for-each join-task tasks)
      (check-equal? 0 finished-meanwhile)
      ;; Lines are written in the order the installs finish.
      (check-equal? (sorted ids) (sorted (configuration-lines)))
      (check-equal? (configuration-lines) (installed-plugins))
      (check (for-all plugin-commit ids))))

  (test "a second install of a plugin while git runs for it raises, and the first completes"
    (let* ([first (spawn-task (lambda () (install-plugin! (line 'shared))))]
           [second (spawn-task (lambda () (raised-message (lambda () (install-plugin! (line 'shared))))))])
      (check-equal? "git is running for the plugin" (join-task second))
      (join-task first)
      (check (memq 'shared (configuration-lines)))
      (check (plugin-commit 'shared))))

  (test "other threads find a plugin's plain library while the main thread changes plugins"
    (let ([missed 0] [stop? #f] [m (make-mutex)])
      (let ([finders
             (map (lambda (i)
                    (fork-thread
                      (lambda ()
                        (let loop ()
                          (unless stop?
                            (let-values ([(source object found?)
                                          ((library-search-handler) 'import '(shared match)
                                           (library-directories) (library-extensions))])
                              (unless source (with-mutex m (set! missed (+ missed 1)))))
                            (loop))))))
                  (iota 4))])
        (do ([round 0 (+ round 1)]) ((= round 5))
          (for-each remove-plugin! ids)
          (for-each join-task
            (map (lambda (id) (spawn-task (lambda () (install-plugin! (line id))))) ids)))
        (set! stop? #t)
        (for-each thread-join finders))
      (check-equal? 0 missed)
      (check-equal? (sorted (cons 'shared ids)) (sorted (configuration-lines)))))

  (test "the commands make changes, so only the main thread runs them"
    (let ([outcome #f])
      (thread-join
        (fork-thread
          (lambda ()
            (set! outcome
              (list (raised-message (lambda () (install-plugin! (line 'alpha))))
                    (raised-message (lambda () (update-plugin! 'alpha)))
                    (raised-message (lambda () (remove-plugin! 'alpha)))
                    (raised-message remove-unused-plugins!))))))
      (check-equal? (make-list 4 "only the main thread makes changes") outcome)))

  (test "git has no terminal, so ssh cannot wait for an answer on it"
    (let ([report (path "ssh-report")] [script (path "ssh")])
      (write-file! script
        (string-append
          "#!/bin/sh\n"
          "{ awk '{print $6}' /proc/$$/stat\n"
          "  if (exec 3</dev/tty) 2>/dev/null; then echo tty; else echo none; fi; } > '" report "'\n"
          "exit 1\n"))
      (chmod script #o755)
      (putenv "GIT_SSH_COMMAND" script)
      (check (raised-message
               (lambda () (install-plugin! '(use-plugin sessioned (git "ssh://example.invalid/sessioned"))))))
      (let ([lines (call-with-input-file report (lambda (p) (list (get-line p) (get-line p))))]
            [session (call-with-input-file (format "/proc/~a/stat" (get-process-id))
                       (lambda (p)
                         (let skip () (unless (char=? (read-char p) #\)) (skip)))
                         (let* ([state (read p)] [parent (read p)] [group (read p)] [session (read p)])
                           (number->string session))))])
        (check (not (equal? session (car lines))))
        (check-equal? "none" (cadr lines)))))

  (test "a quit install keeps the plugin taken until its git ends"
    (let ([script (path "slow-ssh")] [line '(use-plugin slow (git "ssh://example.invalid/slow"))])
      (define (yield) (suspend (lambda (resume) (post! (lambda () (resume void))))))
      (write-file! script "#!/bin/sh\nsleep 0.5\nexit 1\n")
      (chmod script #o755)
      (putenv "GIT_SSH_COMMAND" script)
      (let ([first (spawn-task (lambda () (install-plugin! line)))] [reported '()])
        (define (keep original c) (set! reported (cons c reported)))
        (yield)
        (advice-add! report keep)
        (signal-task first (make-quit-condition))
        (check (quit-condition? (guard (c [#t c]) (join-task first))))
        (advice-remove! report keep)
        (check (and (= (length reported) 1) (quit-condition? (car reported))))
        (check-equal? "git is running for the plugin" (raised-message (lambda () (install-plugin! line))))
        (suspend
          (lambda (resume)
            (fork-thread (lambda () (sleep (make-time 'time-duration 0 3)) (resume void)))))
        (check (not (equal? "git is running for the plugin"
                            (raised-message (lambda () (install-plugin! line))))))))))

(post! (lambda ()
         (tests)
         (system (format "rm -rf '~a'" root))
         (test-exit)))
(run-main-loop)

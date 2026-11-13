(import (chezscheme) (tuna-test) (chez-lang loader)
        (tuna core changes) (only (tuna core definitions) tick report advice-add! advice-remove!)
        (tuna core modules) (except (tuna core main-thread) exit)
        (tuna plugin-manager) (only (tuna files) string-prefix?))

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
    (unless (zero? (system (format "cd '~a' && git init -q -b main && git add -A && git -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false commit -qm one" dir)))
      (error 'make-remote! "git failed" id))
    (format "file://~a" dir)))

(define (commit-remote! dir)
  (unless (zero? (system (format "cd '~a' && { [ -d .git ] || git init -q -b main; } && git add -A && git -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false commit -qm one" dir)))
    (error 'commit-remote! "git failed" dir))
  (call-with-input-file (format "~a/.git/refs/heads/main" dir) get-line))

(define (library-line id url commit)
  `(library ,id (git ,url) (commit ,commit) (library-directories ("src" . "obj")) (build)))

(define (make-library-user! id line)
  (let ([dir (path "remotes" (symbol->string id))])
    (write-file! (format "~a/~a.sls" dir id) (format "#!tuna\n(define (name) '~a)\n" id))
    (write-file! (format "~a/tuna.deps" dir) (format "~s\n" line))
    (commit-remote! dir)
    `(use-plugin ,id (git ,(format "file://~a" dir)))))

(define (slow-library id name)
  (let ([dir (path "remotes" (symbol->string id))])
    (write-file! (format "~a/src/~a.sls" dir name)
      (format "(library (~a) (export ~a) (import (chezscheme)) (define (~a) '~a))\n" name name name name))
    `(library ,id (git ,(format "file://~a" dir)) (commit ,(commit-remote! dir))
       (library-directories ("src" . "obj")) (build "sleep" "1"))))

(define shared-library
  (let ([dir (path "remotes" "chez-shared")])
    (write-file! (format "~a/src/shared-library.sls" dir)
      "(library (shared-library) (export shared) (import (chezscheme)) (define (shared) 'shared))\n")
    (library-line 'chez-shared (format "file://~a" dir) (commit-remote! dir))))

(define ids '(alpha beta gamma delta epsilon zeta))
(define addresses (map make-remote! (cons 'shared ids)))

(write-file! (path "config" "init.ss") "(import (tuna) (tuna plugins))\n")
(compile-file-message #f)
(start-plugins! (string-append (current-directory) "/build/bin/tuna") root (path "config" "init.ss") (path "config" "lib") (path "library") (path "plugins")
  (path "own-libraries") (path "libraries"))
(install-module-lookup! (library-directories) (path "config" "lib") (path "library") (path "cache"))
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

(define (delete-configuration-line! id)
  (let ([lines (call-with-input-file (path "config" "init.ss")
                 (lambda (p) (let loop () (let ([text (get-line p)]) (if (eof-object? text) '() (cons text (loop)))))))])
    (write-file! (path "config" "init.ss")
      (apply string-append
        (map (lambda (text) (string-append text "\n"))
             (remp (lambda (text) (string-prefix? (format "(use-plugin ~a " id) text)) lines))))))

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

  (test "installs of plugins that name one library install it once, and its root once"
    (let ([tasks (map (lambda (id) (spawn-task (lambda () (install-plugin! (make-library-user! id shared-library)))))
                      '(user-1 user-2 user-3))])
      (for-each join-task tasks)
      (check (for-all (lambda (id) (memq id (configuration-lines))) '(user-1 user-2 user-3)))
      (check-equal? (cadr (assq 'commit (cddr shared-library)))
        (call-with-input-file (path "libraries" "chez-shared" ".git" "HEAD") get-line))
      (check-equal? 1 (length (filter (lambda (root) (equal? (car root) (path "libraries" "chez-shared" "src")))
                                      (library-directories))))))

  (test "a second install of a plugin while git runs for it raises, and the first completes"
    (let* ([first (spawn-task (lambda () (install-plugin! (line 'shared))))]
           [second (spawn-task (lambda () (raised-message (lambda () (install-plugin! (line 'shared))))))])
      (check-equal? "git is running for the plugin" (join-task second))
      (join-task first)
      (check (memq 'shared (configuration-lines)))
      (check (plugin-commit 'shared))))

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
                            (raised-message (lambda () (install-plugin! line)))))))))

  (test "a quit install keeps its library taken until its git ends, and later installs wait for none"
    (let* ([library '(library chez-slow (git "ssh://example.invalid/slow") (commit "0000000") (build))]
           [first-line (make-library-user! 'slow-1 library)]
           [second-line (make-library-user! 'slow-2 library)])
      (define (yield) (suspend (lambda (resume) (post! (lambda () (resume void))))))
      (define running "plugin slow-2 needs library chez-slow: git is running for the library with irritant chez-slow")
      (let ([first (spawn-task (lambda () (install-plugin! first-line)))] [reported '()])
        (define (keep original c) (set! reported (cons c reported)))
        (let wait () (unless (file-exists? (path "plugins" "slow-1.installed")) (yield) (wait)))
        (yield)
        (advice-add! report keep)
        (signal-task first (make-quit-condition))
        (check (quit-condition? (guard (c [#t c]) (join-task first))))
        (advice-remove! report keep)
        (check (and (= (length reported) 1) (quit-condition? (car reported))))
        (check-equal? running (raised-message (lambda () (install-plugin! second-line))))
        (suspend
          (lambda (resume)
            (fork-thread (lambda () (sleep (make-time 'time-duration 0 3)) (resume void)))))
        (check (not (equal? running (raised-message (lambda () (install-plugin! second-line)))))))))

  (test "a quit install whose library is building leaves no plugin and no line, and the install can run again"
    (let ([line (make-library-user! 'quitter (slow-library 'chez-quitted 'quitted))])
      (define (yield) (suspend (lambda (resume) (post! (lambda () (resume void))))))
      (let ([task (spawn-task (lambda () (install-plugin! line)))] [reported '()])
        (define (keep original c) (set! reported (cons c reported)))
        (let wait () (unless (file-exists? (path "libraries" "chez-quitted")) (yield) (wait)))
        (advice-add! report keep)
        (signal-task task (make-quit-condition))
        (check (quit-condition? (guard (c [#t c]) (join-task task))))
        (advice-remove! report keep)
        (check (not (memq 'quitter (installed-plugins))))
        (check (not (memq 'quitter (configuration-lines))))
        (suspend
          (lambda (resume)
            (fork-thread (lambda () (sleep (make-time 'time-duration 0 2)) (resume void)))))
        (install-plugin! line)
        (check (memq 'quitter (configuration-lines))))))

  (test "remove-unused-plugins! waits for an install whose library is building"
    (let ([line (make-library-user! 'patient (slow-library 'chez-patient 'patient-library))])
      (define (yield) (suspend (lambda (resume) (post! (lambda () (resume void))))))
      (let ([task (spawn-task (lambda () (install-plugin! line)))])
        (let wait () (unless (file-exists? (path "libraries" "chez-patient")) (yield) (wait)))
        (remove-unused-plugins!)
        (join-task task)
        (check (memq 'patient (configuration-lines)))
        (check (file-exists? (path "libraries" "chez-patient.installed"))))))

  (test "an update installs the libraries its new commit names, whether or not the plugin has a line"
    (for-each
      (lambda (id lined?)
        (let* ([dir (path "remotes" (symbol->string id))]
               [library-id (string->symbol (format "chez-~a" id))]
               [library (let ([library-dir (path "remotes" (symbol->string library-id))])
                          (write-file! (format "~a/src/~a.sls" library-dir library-id)
                            (format "(library (~a) (export library-answer) (import (chezscheme)) (define (library-answer) 42))\n" library-id))
                          (library-line library-id (format "file://~a" library-dir) (commit-remote! library-dir)))])
          (write-file! (format "~a/~a.sls" dir id) "#!tuna\n(define (answer) 0)\n")
          (commit-remote! dir)
          (install-plugin! `(use-plugin ,id (git ,(format "file://~a" dir))))
          (load-module! (list id))
          (unless lined?
            (delete-configuration-line! id)
            (read-configuration-lines!)
            (check (not (memq id (configuration-lines)))))
          (write-file! (format "~a/~a.sls" dir id) (format "#!tuna\n(import (~a))\n(define (answer) (library-answer))\n" library-id))
          (write-file! (format "~a/tuna.deps" dir) (format "~s\n" library))
          (let ([commit (commit-remote! dir)])
            (update-plugin! id)
            (check-equal? commit (plugin-commit id))
            (check (memq id (configuration-lines)))
            (check (file-exists? (path "libraries" (format "~a.installed" library-id)))))))
      '(updated-with-line updated-without-line)
      '(#t #f))))

(post! (lambda ()
         (tests)
         (system (format "rm -rf '~a'" root))
         (test-exit)))
(run-main-loop)

(import (tuna) (test) (test-runner) (plugins))

(define (path . parts) (apply string-append (getenv "HOME") (map (lambda (part) (string-append "/" part)) parts)))

(define (read-configuration-lines!) ((eval-in-module 'read-configuration-lines! '(plugins))))

(define (write-file! file text)
  (let loop ([dir (path-parent file)])
    (unless (file-directory? dir)
      (loop (path-parent dir))
      (mkdir dir)))
  (call-with-output-file file (lambda (p) (put-string p text)) 'replace))

(define (make-remote! id)
  (let ([dir (path "remotes" (symbol->string id))])
    (write-file! (format "~a/src/~a.sls" dir id) (format "#!tuna\n(define (name) '~a)\n" id))
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
    (write-file! (format "~a/src/~a.sls" dir id) (format "#!tuna\n(define (name) '~a)\n" id))
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

(define (line id) `(use-plugin ,id (git ,(format "file://~a" (path "remotes" (symbol->string id))))))

(define (configuration-lines)
  (call-with-input-file (path ".config" "tuna" "init.ss")
    (lambda (p)
      (let loop ()
        (let ([form (read p)])
          (cond
            [(eof-object? form) '()]
            [(and (pair? form) (eq? (car form) 'use-plugin)) (cons (cadr form) (loop))]
            [else (loop)]))))))

(define (string-prefix? prefix s)
  (and (<= (string-length prefix) (string-length s)) (string=? prefix (substring s 0 (string-length prefix)))))

(define (delete-configuration-line! id)
  (let ([lines (call-with-input-file (path ".config" "tuna" "init.ss")
                 (lambda (p) (let loop () (let ([text (get-line p)]) (if (eof-object? text) '() (cons text (loop)))))))])
    (write-file! (path ".config" "tuna" "init.ss")
      (apply string-append
        (map (lambda (text) (string-append text "\n"))
             (remp (lambda (text) (string-prefix? (format "(use-plugin ~a " id) text)) lines))))))

(define (sorted ids) (sort (lambda (a b) (string<? (symbol->string a) (symbol->string b))) ids))

(define (raised-message thunk)
  (guard (c [#t (if (message-condition? c) (condition-message c) c)]) (thunk) #f))

(define (raised-text thunk)
  (guard (c [#t (call-with-string-output-port (lambda (p) (display-condition c p)))]) (thunk) #f))

(define (yield) (suspend (lambda (resume) (spawn-task (lambda (restore) (resume void))))))

(define (ended t) (call-with-values (lambda () (join-task t)) list))

(write-file! (path ".config" "tuna" "init.ss") "(import (tuna))\n")
(plugins:load-configuration!)

;; Each round cancels at a later timer tick, so cancels land all over the
;; reading.
(test "a cancel while the configuration's lines are read ends the reading rather than cutting the lines short"
  (write-file! (path ".config" "tuna" "init.ss")
    (call-with-string-output-port
      (lambda (p)
        (put-string p "(import (tuna))\n")
        (do ([i 0 (+ i 1)]) ((= i 2000))
          (fprintf p "(options:set! fill:column ~a)\n" i)))))
  (let* ([ticks 0] [cancel-at #f]
         [counter (lambda (tick)
                    (tick)
                    (set! ticks (+ ticks 1))
                    (when (eqv? ticks cancel-at) (cancel-task (current-task) 'tick)))]
         [quiet (lambda (report c) (unless (cancelled? c) (report c)))])
    (advice-add! tick counter)
    (advice-add! report quiet)
    (read-configuration-lines!)
    (let ([total ticks])
      (check (> total 20))
      (check-equal? '()
        (filter
          (lambda (n)
            (set! ticks 0)
            (set! cancel-at n)
            (not (eq? 'cancelled (car (ended (spawn-task (lambda (restore) (read-configuration-lines!))))))))
          (map add1 (iota (quotient total 2))))))
    (advice-remove! tick counter)
    (advice-remove! report quiet))
  (write-file! (path ".config" "tuna" "init.ss") "(import (tuna))\n")
  (read-configuration-lines!))

(test "installs of different plugins run at once, while the main thread goes on"
  (let* ([finished-meanwhile #f]
         [tasks (map (lambda (id) (spawn-task (lambda (restore) (plugins:install! (line id))))) ids)])
    (spawn-task (lambda (restore) (set! finished-meanwhile (length (filter (lambda (t) (eq? (task-state t) 'done)) tasks)))))
    (for-each join-task tasks)
    (check-equal? 0 finished-meanwhile)
    ;; Lines are written in the order the installs finish.
    (check-equal? (sorted ids) (sorted (configuration-lines)))
    (check-equal? (configuration-lines) (plugins:installed))
    (check (for-all plugins:commit ids))))

(test "installs of plugins that name one library install it once, and its root once"
  (let ([tasks (map (lambda (id) (spawn-task (lambda (restore) (plugins:install! (make-library-user! id shared-library)))))
                    '(user-1 user-2 user-3))])
    (for-each join-task tasks)
    (check (for-all (lambda (id) (memq id (configuration-lines))) '(user-1 user-2 user-3)))
    (check-equal? (cadr (assq 'commit (cddr shared-library)))
      (call-with-input-file (path ".local" "share" "tuna" "libraries" "chez-shared" ".git" "HEAD") get-line))
    (check-equal? 1 (length (filter (lambda (root) (equal? (car root) (path ".local" "share" "tuna" "libraries" "chez-shared" "src")))
                                    (library-directories))))))

(test "a second install of a plugin while git runs for it raises, and the first completes"
  (let* ([first (spawn-task (lambda (restore) (plugins:install! (line 'shared))))]
         [second (spawn-task (lambda (restore) (raised-message (lambda () (plugins:install! (line 'shared))))))])
    (check-equal? '(returned ("git is running for the plugin")) (ended second))
    (join-task first)
    (check (memq 'shared (configuration-lines)))
    (check (plugins:commit 'shared))))

(test "the commands make changes, so only the main thread runs them"
  (let ([outcome #f])
    (join-task
      (fork-task
        (lambda (restore)
          (set! outcome
            (list (raised-message (lambda () (plugins:install! (line 'alpha))))
                  (raised-message (lambda () (plugins:update! 'alpha)))
                  (raised-message (lambda () (plugins:remove! 'alpha)))
                  (raised-message plugins:remove-unused!))))))
    (check-equal? (make-list 4 "only the main thread installs and removes plugins") outcome)))

(test "git has no terminal, so ssh cannot wait for an answer on it"
  (let ([report-file (path "ssh-report")] [script (path "ssh")])
    (write-file! script
      (string-append
        "#!/bin/sh\n"
        "{ awk '{print $6}' /proc/$$/stat\n"
        "  if (exec 3</dev/tty) 2>/dev/null; then echo tty; else echo none; fi; } > '" report-file "'\n"
        "exit 1\n"))
    (chmod script #o755)
    (putenv "GIT_SSH_COMMAND" script)
    (check (raised-message
             (lambda () (plugins:install! '(use-plugin sessioned (git "ssh://example.invalid/sessioned"))))))
    (let ([lines (call-with-input-file report-file (lambda (p) (list (get-line p) (get-line p))))]
          [session (call-with-input-file (format "/proc/~a/stat" (get-process-id))
                     (lambda (p)
                       (let skip () (unless (char=? (read-char p) #\)) (skip)))
                       (let* ([state (read p)] [parent (read p)] [group (read p)] [session (read p)])
                         (number->string session))))])
      (check (not (equal? session (car lines))))
      (check-equal? "none" (cadr lines)))))

(test "a cancelled install keeps the plugin taken until its git ends"
  (let ([script (path "slow-ssh")] [slow-line '(use-plugin slow (git "ssh://example.invalid/slow"))] [reported '()])
    (define (keep original c) (set! reported (cons c reported)))
    (write-file! script "#!/bin/sh\nsleep 0.5\nexit 1\n")
    (chmod script #o755)
    (putenv "GIT_SSH_COMMAND" script)
    (let ([first (spawn-task (lambda (restore) (plugins:install! slow-line)))])
      (yield)
      (advice-add! report keep)
      (cancel-task first)
      (check-equal? 'cancelled (car (ended first)))
      (advice-remove! report keep)
      (check (and (= (length reported) 1) (cancelled? (car reported))))
      (check-equal? "git is running for the plugin" (raised-message (lambda () (plugins:install! slow-line))))
      (test-runner:wait-until
        (lambda () (not (equal? "git is running for the plugin" (raised-message (lambda () (plugins:install! slow-line))))))))))

(test "a cancelled install keeps its library taken until its git ends, and later installs wait for none"
  (let* ([library '(library chez-slow (git "ssh://example.invalid/slow") (commit "0000000") (build))]
         [first-line (make-library-user! 'slow-1 library)]
         [second-line (make-library-user! 'slow-2 library)]
         [running "plugin slow-2 needs library chez-slow: git is running for the library with irritant chez-slow"]
         [reported '()])
    (define (keep original c) (set! reported (cons c reported)))
    (let ([first (spawn-task (lambda (restore) (plugins:install! first-line)))])
      (test-runner:wait-until (lambda () (file-exists? (path ".local" "share" "tuna" "plugins" "slow-1.installed"))))
      (yield)
      (advice-add! report keep)
      (cancel-task first)
      (check-equal? 'cancelled (car (ended first)))
      (advice-remove! report keep)
      (check (and (= (length reported) 1) (cancelled? (car reported))))
      (check-equal? running (raised-message (lambda () (plugins:install! second-line))))
      (test-runner:wait-until
        (lambda () (not (equal? running (raised-message (lambda () (plugins:install! second-line))))))))))

(test "a cancelled install whose library is building leaves no plugin and no line, and the install can run again"
  (let ([quitter-line (make-library-user! 'quitter (slow-library 'chez-quitted 'quitted))]
        [quiet (lambda (report c) (unless (cancelled? c) (report c)))])
    (let ([task (spawn-task (lambda (restore) (plugins:install! quitter-line)))])
      (test-runner:wait-until (lambda () (file-exists? (path ".local" "share" "tuna" "libraries" "chez-quitted"))))
      (advice-add! report quiet)
      (cancel-task task)
      (check-equal? 'cancelled (car (ended task)))
      (advice-remove! report quiet)
      (check (not (memq 'quitter (plugins:installed))))
      (check (not (memq 'quitter (configuration-lines))))
      (test-runner:wait-until (lambda () (not (raised-message (lambda () (plugins:install! quitter-line))))))
      (check (memq 'quitter (configuration-lines))))))

(test "remove-unused-plugins! waits for an install whose library is building"
  (let ([patient-line (make-library-user! 'patient (slow-library 'chez-patient 'patient-library))])
    (let ([task (spawn-task (lambda (restore) (plugins:install! patient-line)))])
      (test-runner:wait-until (lambda () (file-exists? (path ".local" "share" "tuna" "libraries" "chez-patient"))))
      (plugins:remove-unused!)
      (join-task task)
      (check (memq 'patient (configuration-lines)))
      (check (file-exists? (path ".local" "share" "tuna" "libraries" "chez-patient.installed"))))))

(test "an update installs the libraries its new commit names, whether or not the plugin has a line"
  (for-each
    (lambda (id lined?)
      (let* ([dir (path "remotes" (symbol->string id))]
             [library-id (string->symbol (format "chez-~a" id))]
             [library (let ([library-dir (path "remotes" (symbol->string library-id))])
                        (write-file! (format "~a/src/~a.sls" library-dir library-id)
                          (format "(library (~a) (export library-answer) (import (chezscheme)) (define (library-answer) 42))\n" library-id))
                        (library-line library-id (format "file://~a" library-dir) (commit-remote! library-dir)))])
        (write-file! (format "~a/src/~a.sls" dir id) "#!tuna\n(define (answer) 0)\n")
        (commit-remote! dir)
        (plugins:install! `(use-plugin ,id (git ,(format "file://~a" dir))))
        (load-module! (list id))
        (unless lined?
          (delete-configuration-line! id)
          (read-configuration-lines!)
          (check (not (memq id (configuration-lines)))))
        (write-file! (format "~a/src/~a.sls" dir id) (format "#!tuna\n(import (~a))\n(define (answer) (library-answer))\n" library-id))
        (write-file! (format "~a/tuna.deps" dir) (format "~s\n" library))
        (let ([new-commit (commit-remote! dir)])
          (plugins:update! id)
          (check-equal? new-commit (plugins:commit id))
          (check (memq id (configuration-lines)))
          (check (file-exists? (path ".local" "share" "tuna" "libraries" (format "~a.installed" library-id)))))))
    '(updated-with-line updated-without-line)
    '(#t #f)))

(test "start and plugins load before any line, so a line for either raises, as does a plugin that holds their libraries"
  (for-each
    (lambda (id)
      (let ([refused (format "~a loads before any line is read, so only tuna --start=FOLDER replaces it" id)])
        (check-equal? (format "Exception in install-plugin!: ~a" refused)
          (raised-text (lambda () (plugins:install! `(use-plugin ,id (git ,(make-remote! id)))))))
        (check-equal? (format "Exception in use-plugin: ~a" refused)
          (raised-text
            (lambda ()
              (call-as-owner (plugins:repl-owner)
                (lambda () (plugins:eval-form `(use-plugin ,id (local ,(path "remotes" (symbol->string id))))))))))))
    '(start plugins))
  (check (not (exists (lambda (id) (memq id (configuration-lines))) '(start plugins))))
  (let ([dir (path "remotes" "holder")])
    (write-file! (format "~a/src/holder.sls" dir) "#!tuna\n(define (name) 'holder)\n")
    (write-file! (format "~a/src/plugins/extra.sls" dir) "#!tuna\n(define (name) 'extra)\n")
    (commit-remote! dir)
    (check (string-prefix? "Exception in install-plugin!: plugin holder holds the library (plugins extra), a name Tuna keeps for itself"
             (raised-text (lambda () (plugins:install! `(use-plugin holder (git ,(format "file://~a" dir))))))))))

;; The configuration's unload action pauses, so the cancel lands while
;; the operation waits in that unload, after asking for it.
(test "a reload cancelled while it waits for the configuration's unload still has the configuration read again"
  (write-file! (path ".config" "tuna" "lib" "imported.sls") "#!tuna\n(define (name) 'imported)\n")
  (write-file! (path ".config" "tuna" "init.ss") "(import (tuna) (imported))\n")
  (plugins:load-configuration!)
  (let ([release #f] [before (plugins:configuration-owner)])
    (call-as-owner before
      (lambda () (on-unload (lambda () (suspend (lambda (resume) (set! release resume)))))))
    (let ([t (spawn-task (lambda (restore) (reload-modules! '((imported)))))]
          [quiet (lambda (report c) (unless (cancelled? c) (report c)))])
      (test-runner:wait-until (lambda () release))
      (advice-add! report quiet)
      (cancel-task t)
      (yield)
      (release void)
      (check-equal? 'cancelled (car (ended t)))
      (advice-remove! report quiet)
      (test-runner:wait-until (lambda () (not (eq? before (plugins:configuration-owner)))))
      (check (not (owner-live? before)))
      (check (not (eq? before (plugins:configuration-owner))))
      (check (owner-live? (plugins:configuration-owner))))))
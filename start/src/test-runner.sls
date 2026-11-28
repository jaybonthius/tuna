#!tuna
(import (plugins) (plugins files) (plugins installs) (plugins process))

(define %parallel 4)
(define %limit-seconds 120)

(define (run-paths paths)
  (unless (and (list? paths) (for-all string? paths))
    (assertion-violation 'test-runner:run-paths "not a list of strings" paths))
  (let ([found (map (lambda (path) (cons path (%path-files (%from-running path)))) paths)])
    (for-each
      (lambda (entry) (unless (cdr entry) (printf "FAIL ~a: not a test file or a folder\n" (car entry))))
      found)
    (let ([queue (apply append (map (lambda (entry) (or (cdr entry) '())) found))]
          [root (format "~a/tuna-test-~a" (%temporary-folder) (get-process-id))]
          [count 0]
          [passed? (for-all (lambda (entry) (and (cdr entry) #t)) found)])
      (delete-tree root)
      (for-each join
        (map (lambda (i)
               (spawn-task
                 (lambda (restore)
                   (let loop ()
                     (unless (null? queue)
                       (let ([file (car queue)])
                         (set! queue (cdr queue))
                         (set! count (+ count 1))
                         (unless (%run-and-tell file (format "~a/~a" root count))
                           (set! passed? #f))
                         (loop)))))))
             (iota %parallel)))
      (delete-tree root)
      passed?)))

;; Files in folders under tests/ are run only by the tests that launch
;; them, so a path names a test file only when it sits directly in tests/.
(define (%path-files path)
  (cond
    [(file-regular? path) (and (%runnable? path) (list path))]
    [(not (file-directory? path)) #f]
    [(string=? (path-last (normal-path path)) "tests") (%test-files path)]
    [(file-directory? (string-append path "/tests")) (%test-files (string-append path "/tests"))]
    [else '()]))

(define (%runnable? path)
  (and (string=? (path-extension path) "ss")
       (string=? (path-last (path-parent (normal-path path))) "tests")))

(define (%test-files folder)
  (map (lambda (name) (string-append folder "/" name))
       (sort string<?
             (filter (lambda (name)
                       (let ([path (string-append folder "/" name)])
                         (and (file-regular? path) (%runnable? path))))
                     (directory-list folder)))))

(define (%run-and-tell file home)
  (let ([start (current-time 'time-monotonic)])
    (let-values ([(status errors output) (%launch (normal-path file) home)])
      (let ([took (time-difference (current-time 'time-monotonic) start)])
        (if (and (eqv? status 0) (string=? errors ""))
            (printf "ok ~a ~,1f s\n" file (+ (time-second took) (/ (time-nanosecond took) 1e9)))
            (printf "FAIL ~a: ~a\n~a~a"
              file
              (cond
                [(eq? status 'timed-out) (format "did not end within ~a s" %limit-seconds)]
                [(eqv? status 0) "wrote to standard error"]
                [else (format "exited with status ~a" status)])
              (%labelled "standard error" errors)
              (%labelled "standard output" output)))
        (flush-output-port (current-output-port))
        (and (eqv? status 0) (string=? errors ""))))))

(define (%labelled label text)
  (if (string=? text "")
      ""
      (format "--- ~a\n~a~a" label text (if (%string-suffix? "\n" text) "" "\n"))))

(define (%string-suffix? suffix s)
  (let ([n (string-length suffix)] [m (string-length s)])
    (and (fx<= n m) (string=? suffix (substring s (fx- m n) m)))))

(define (run-file file home)
  (unless (string? file) (assertion-violation 'test-runner:run-file "not a string" file))
  (unless (string? home) (assertion-violation 'test-runner:run-file "not a string" home))
  (let ([file (normal-path (%from-running file))])
    (%check-test-file 'test-runner:run-file file)
    (let-values ([(status errors output) (%launch file (normal-path home))])
      (values status errors))))

;; A test file, or a file a test launches, is a .ss file in a tests folder,
;; whose parent names the file's owner.
(define (%check-test-file who file)
  (unless (file-regular? file) (assertion-violation who "no such file" file))
  (unless (and (string=? (path-extension file) "ss") (%tests-folder file))
    (assertion-violation who "not a .ss file in a tests folder" file)))

;; A test names the files it runs relative to its own folder, since its
;; working folder is its home.
(define (%from-running path)
  (let ([running (getprop 'test-runner 'file #f)])
    (if (or (path-absolute? path) (not running))
        path
        (string-append (path-parent running) "/" path))))

(define (%temporary-folder)
  (let ([folder (getenv "TMPDIR")])
    (if (and folder (> (string-length folder) 0)) folder "/tmp")))

(define (%tests-folder file)
  (let loop ([folder (path-parent file)])
    (cond
      [(member folder '("" "/")) #f]
      [(string=? (path-last folder) "tests") folder]
      [else (loop (path-parent folder))])))

(define (%bin) (path-parent (normal-path (car (command-line)))))

;; The child finds an own plugin's test modules where it finds the plugin,
;; in the install. start's and the kernel's are not installed, and their
;; tests use them as the user's lib/ modules, so those are copied there.
(define (%lib-to-copy file)
  (let ([tests (%tests-folder file)])
    (and (not (file-directory? (format "~a/plugins/~a/src" (%bin) (path-last (path-parent tests)))))
         (string-append tests "/lib"))))

;; Nothing of the user's that would change what a test does reaches the
;; program: no configuration, no saved data, no git settings, and Tuna's
;; own plugins from the install.
(define (home-environment home)
  (unless (string? home) (assertion-violation 'test-runner:home-environment "not a string" home))
  `(("HOME" . ,home) ("TMPDIR" . ,(string-append home "/tmp")) ("GIT_CONFIG_NOSYSTEM" . "1")
    ("XDG_CONFIG_HOME" . #f) ("XDG_DATA_HOME" . #f) ("XDG_CACHE_HOME" . #f)))

(define make-home!
  (case-lambda
    [(home) (make-home! home #f)]
    [(home configuration)
     (unless (string? home) (assertion-violation 'test-runner:make-home! "not a string" home))
     (unless (or (not configuration) (string? configuration))
       (assertion-violation 'test-runner:make-home! "not a string" configuration))
     (let ([running (getprop 'test-runner 'file #f)] [home (normal-path home)])
       (unless running (assertion-violation 'test-runner:make-home! "no test file is running"))
       (let ([init (and configuration (normal-path (%from-running configuration)))])
         (when (and init (not (file-regular? init)))
           (assertion-violation 'test-runner:make-home! "no such file" init))
         (%run-script
           (string-append
             (%home-script home (%lib-to-copy running))
             (if init
                 (format "cp ~a ~a\n" (shell-quote init) (shell-quote (string-append home "/.config/tuna/init.ss")))
                 "")))
         (void)))]))

;; The install's compiled plugins are copied in, as a home's compiled
;; folder is its Tuna's own, so the Tuna under test compiles none of them.
(define (%home-script home lib)
  (let* ([bin (%bin)]
         [cache (string-append home "/.cache/tuna")]
         [q shell-quote])
    (string-append
      "set -e\n"
      (format "mkdir -p ~a ~a\n" (q (string-append home "/tmp")) (q (string-append home "/.config/tuna/lib")))
      (format "if [ ! -d ~a ]; then mkdir -p ~a; cp -R ~a ~a; cp -R ~a ~a; fi\n"
        (q (string-append cache "/library"))
        (q (string-append cache "/start" bin))
        (q (string-append bin "/plugins-cache")) (q (string-append cache "/library"))
        (q (string-append bin "/start-cache")) (q (string-append cache "/start" bin "/start")))
      (if (and lib (file-directory? lib))
          (format "cp -R ~a ~a\n" (q (string-append lib "/.")) (q (string-append home "/.config/tuna/lib/")))
          ""))))

(define (%run-script script) (join (fork-task (lambda (restore) (system script)))))

(define (%launch file home)
  (let* ([program (normal-path (car (command-line)))]
         [scratch (string-append (%temporary-folder) "/tuna-test-" (gensym->unique-string (gensym)))]
         [output (string-append scratch ".out")]
         [errors (string-append scratch ".err")]
         [q shell-quote]
         [status
          (%run-script
            (string-append
              (format "exec </dev/null >~a 2>~a\n" (q output) (q errors))
              (%home-script home (%lib-to-copy file))
              (format "cd ~a\n" (q home))
              (format "env~{ -u ~a~}~{ ~a~} timeout -k 10 ~a ~a ~a\n"
                (map car (filter (lambda (entry) (not (cdr entry))) (home-environment home)))
                (map (lambda (entry) (q (format "~a=~a" (car entry) (cdr entry))))
                     (filter cdr (home-environment home)))
                %limit-seconds (q program) (q (string-append "--test-file=" file)))))])
    (let ([read-and-delete (lambda (path)
                             (let ([text (if (file-exists? path) (read-text-file path) "")])
                               (delete-file path #f)
                               text))])
      (let* ([errors (read-and-delete errors)] [output (read-and-delete output)])
        ;; timeout exits 124 when its TERM ended the child, 137 when it had
        ;; to send KILL; the shell waits for it, so the status is timeout's.
        (values (if (memv status '(124 137)) 'timed-out status) errors output)))))

;; start's body runs again when the plugin manager is reloaded, and the
;; file must run once per process; the property list is the process's.
(define (evaluate-file file)
  (unless (string? file) (assertion-violation 'test-runner:evaluate-file "not a string" file))
  (unless (getprop 'test-runner 'file #f)
    (let ([file (normal-path file)])
      (%check-test-file 'test-runner:evaluate-file file)
      (putprop 'test-runner 'file file)
      (call-as-owner (make-owner (%owner-name file))
        (lambda () (spawn-task (lambda (restore) (%evaluate-forms file))))))))

;; Owners are named after the file, since tests make owners of their own
;; and making an owner whose name is live raises.
(define (%owner-name file)
  (let* ([tests (%tests-folder file)]
         [folder (path-parent tests)]
         [name (path-last folder)]
         [plugin (if (file-regular? (format "~a/src/~a.sls" folder name)) (string->symbol name) 'tuna)])
    (let loop ([path (path-root file)] [parts '()])
      (if (string=? path tests)
          `(test-file ,plugin ,@parts)
          (loop (path-parent path) (cons (string->symbol (path-last path)) parts))))))

;; exit unwinds every task, and runs the after-thunks of paused ones, so a
;; file that exits before its last form, itself or through a key it
;; presses, is caught here; a task's winders also run at each pause. A
;; cancel that reaches the top of a form ends the file as a raise does.
(define (%evaluate-forms file)
  (let ([finished? #f] [at 0])
    (define (fail) (set! finished? #t) (exit 1))
    (dynamic-wind
      void
      (lambda ()
        (guard (c [#t (report c) (fail)])
          (for-each
            (lambda (form)
              (set! at (+ at 1))
              (plugins:call-reporting form (lambda () (plugins:eval-form form)) fail))
            (plugins:call-reporting #f (lambda () (plugins:file-forms file)) fail)))
        (set! finished? #t))
      (lambda ()
        (unless (or finished? (memq (task-state (current-task)) '(paused woken)))
          (report (condition (make-error)
                    (make-message-condition (format "~a ended by exit at form ~a" file at)))))))
    (exit 0)))

(define (join task)
  (unless (task? task) (assertion-violation 'test-runner:join "not a task" task))
  (let-values ([(how detail) (join-task task)])
    (case how
      [(returned) (apply values detail)]
      [(raised) (raise detail)]
      [(cancelled) (raise (make-cancelled detail))]
      [else (raise (make-cancelled how))])))

(define (wait-until done?)
  (unless (procedure? done?) (assertion-violation 'test-runner:wait-until "not a procedure" done?))
  (let ([deadline (add-duration (current-time 'time-monotonic) (make-time 'time-duration 0 30))])
    (let loop ()
      (unless (done?)
        (when (time>? (current-time 'time-monotonic) deadline)
          (errorf 'test-runner:wait-until "~s did not hold within 30 s" done?))
        (suspend
          (lambda (resume)
            (fork-task
              (lambda (restore)
                (sleep (make-time 'time-duration 10000000 0))
                (resume void)))))
        (loop)))))

;; The advice is its caller's, a test file or a test module the file
;; calls, which loads after every plugin, so it sits outside every
;; plugin's advice on report: a plugin's advice never sees a report caught
;; here. Threads report too, so the list is kept under a mutex. Not a
;; dynamic-wind, whose after-thunk would run at each pause of the test's
;; task. A warning is not caught, so the code that raised it goes on.
(define reports-during
  (case-lambda
    [(thunk) (reports-during thunk 0)]
    [(thunk count)
     (unless (procedure? thunk) (assertion-violation 'test-runner:reports-during "not a procedure" thunk))
     (unless (and (fixnum? count) (fx>= count 0)) (assertion-violation 'test-runner:reports-during "not a count" count))
     (let* ([mutex (make-mutex)] [reported '()]
            [keep (lambda (next c) (with-mutex mutex (set! reported (cons c reported))))]
            [caught (lambda () (with-mutex mutex (reverse reported)))])
       (advice-add! report keep)
       (guard (c [(not (warning? c)) (advice-remove! report keep) (raise c)])
         (thunk)
         (wait-until (lambda () (>= (length (caught)) count))))
       (advice-remove! report keep)
       (caught))]))

(define (raised-with who message)
  (unless (symbol? who) (assertion-violation 'test-runner:raised-with "not a symbol" who))
  (unless (string? message) (assertion-violation 'test-runner:raised-with "not a string" message))
  (lambda (c)
    (and (who-condition? c) (eq? who (condition-who c))
         (message-condition? c) (string=? message (condition-message c)))))

;; The echo area shows a report's message, then its irritants, so a
;; refusal the user is told in a sentence has none.
(define (shown-reports-during thunk)
  (map (lambda (c)
         (cons* (and (who-condition? c) (condition-who c)) (if (message-condition? c) (condition-message c) c)
                (if (irritants-condition? c) (condition-irritants c) '())))
       (reports-during thunk)))

;; A task spawned now runs after the tasks queued before it, and the
;; resume it queues while the caller is paused runs only once their batch
;; has ended.
(define (wait-for-batch)
  (suspend (lambda (resume) (spawn-task (lambda (restore) (resume void))))))

(define %main-thread (get-thread-id))
(define %self (current-owner))
(define %running (box #f))

(define (%note-running next)
  (set-box! %running (current-task))
  (next))

;; Only tick, which runs in the task the main thread is running, can name
;; that task to another thread. tick is advised only for files that ask,
;; since the advice runs at every tick.
(define (running-task-canceller)
  (unless (eqv? (get-thread-id) %main-thread)
    (assertion-violation 'test-runner:running-task-canceller "not on the main thread"))
  (call-as-owner %self (lambda () (advice-add! tick %note-running)))
  (rec cancel!
    (case-lambda
      [() (cancel! #f)]
      [(spared)
       (unless (or (not spared) (task? spared))
         (assertion-violation 'test-runner:running-task-canceller "not a task" spared))
       (let ([t (if (eqv? (get-thread-id) %main-thread) (current-task) (unbox %running))])
         (and t (not (eq? t spared)) (eq? (task-state t) 'running)
              (begin (cancel-task t) t)))])))

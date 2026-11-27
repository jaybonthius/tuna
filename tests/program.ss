(import (tuna) (test) (test-runner) (program) (processes) (tuna version))

(define (home name)
  (let ([folder (string-append (getenv "HOME") "/" name)])
    (test-runner:make-home! folder)
    folder))

(define (write-file! path text)
  (call-with-output-file path (lambda (p) (put-string p text)) 'replace))

(define (read-datum path) (and (file-exists? path) (call-with-input-file path read)))

(define (pause-seconds seconds)
  (suspend
    (lambda (resume)
      (fork-task (lambda (restore) (sleep (make-time 'time-duration (exact (round (* (mod seconds 1) 1e9))) (exact (floor seconds)))) (resume void))))))

(define (seconds-now)
  (let ([t (current-time 'time-monotonic)]) (+ (time-second t) (/ (time-nanosecond t) 1e9))))

(test "--version prints the version and exits"
  (let-values ([(status output errors) (program:run (home "version") '("--version"))])
    (check-equal? 0 status)
    (check-equal? (format "tuna ~a\n" tuna-version) output)))

(test "without HOME, tuna says so and exits with status 1"
  (let-values ([(status output errors) (program:run (home "no-home") '() '(("HOME" . #f)))])
    (check-equal? 1 status)
    (check-equal? "tuna: HOME is not set\n" errors)))

(test "Tuna's own options are read only at the start of the command line; the rest reach the configuration"
  (let ([folder (home "arguments")])
    (write-file! (string-append folder "/.config/tuna/init.ss")
      "(call-with-output-file (string-append (getenv \"HOME\") \"/seen\")\n  (lambda (p) (write (list (command-line-arguments) (cdr (command-line)) (string? (car (command-line)))) p))\n  'replace)\n(exit)\n")
    (for-each
      (lambda (arguments)
        (let-values ([(status output errors) (program:run folder arguments)])
          (check-equal? 0 status)
          (check-equal? "" errors)
          (check-equal? (list arguments arguments #t) (read-datum (string-append folder "/seen")))))
      '(("notes.org" "+12") ("--version" "x") ("--script") ("x" "--script" "y")))))

(test "--script runs a Chez script as scheme --script does, reading no configuration, and exits with its status"
  (let ([folder (home "script")])
    (write-file! (string-append folder "/.config/tuna/init.ss") "(exit 9)\n")
    (write-file! (string-append folder "/script.ss")
      (string-append
        "(call-with-output-file \"seen\" (lambda (p) (write (list (command-line) (command-line-arguments)) p)) 'replace)\n"
        "(when (equal? (command-line-arguments) '(\"exit\")) (exit 3))\n"
        "(when (equal? (command-line-arguments) '(\"raise\")) (car '()))\n"))
    (let-values ([(status output errors) (program:run folder '("--script" "script.ss" "a" "b c"))])
      (check-equal? 0 status)
      (check-equal? '(("script.ss" "a" "b c") ("a" "b c")) (read-datum (string-append folder "/seen"))))
    (let-values ([(status output errors) (program:run folder '("--script" "script.ss" "exit"))])
      (check-equal? 3 status))
    (let-values ([(status output errors) (program:run folder '("--script" "script.ss" "raise"))])
      (check-equal? 255 status))))

(test "Tuna's own plugins are those beside the program, however it is started"
  (let* ([folder (home "copied")] [bin (string-append folder "/bin")] [installed (path-parent (program:tuna))])
    (define (shell program . arguments)
      (let-values ([(status output errors) (processes:run program arguments)])
        (check-equal? 0 status)))
    (shell "mkdir" "-p" bin)
    (shell "cp" (program:tuna) (string-append bin "/tuna"))
    (shell "cp" "-R" (string-append installed "/plugins") (string-append installed "/start") bin)
    (shell "ln" "-s" (string-append installed "/libraries") (string-append bin "/libraries"))
    (shell "mkdir" "-p" (string-append bin "/plugins/own/src"))
    (write-file! (string-append bin "/plugins/own/src/own.sls") "#!tuna\n(define (where) \"beside the program\")\n")
    (shell "ln" "-s" (string-append bin "/tuna") (string-append folder "/linked-tuna"))
    (write-file! (string-append folder "/.config/tuna/init.ss")
      "(import (own))\n(call-with-output-file (string-append (getenv \"HOME\") \"/seen\") (lambda (p) (write (own:where) p)) 'replace)\n(exit)\n")
    (for-each
      (lambda (program)
        (let-values ([(status output errors) (program:run program folder '() '())])
          (check-equal? 0 status)
          (check-equal? "" errors)
          (check-equal? "beside the program" (read-datum (string-append folder "/seen")))))
      (list (string-append bin "/tuna") (string-append folder "/linked-tuna")))))

(test "Tuna's own names are never looked for in the working folder"
  (let ([folder (home "working")])
    (mkdir (string-append folder "/tuna"))
    (write-file! (string-append folder "/tuna/extra.sls")
      "(library (tuna extra) (export where) (import (chezscheme)) (define where \"work\"))\n")
    (write-file! (string-append folder "/.config/tuna/init.ss")
      (string-append
        "(call-with-output-file (string-append (getenv \"HOME\") \"/seen\")\n"
        "  (lambda (p) (write (guard (c [#t 'refused]) (eval '(import (tuna extra)) (interaction-environment)) 'found) p))\n"
        "  'replace)\n(exit)\n"))
    (let-values ([(status output errors) (program:run folder '())])
      (check-equal? 0 status)
      (check-equal? 'refused (read-datum (string-append folder "/seen")))
      (check (not (file-exists? (string-append folder "/tuna/extra.so")))))))

(test "exit's status is the process's, whichever thread calls it, even when input ends while modules unload"
  (let ([folder (home "slow")])
    (write-file! (string-append folder "/.config/tuna/init.ss")
      (string-append
        "(import (tuna))\n(import (rename (only (chezscheme) sleep) (sleep chez:sleep)))\n"
        "(on-unload (lambda () (chez:sleep (make-time 'time-duration 100000000 0))))\n(import (console))\n"))
    (for-each
      (lambda (form)
        (let ([r (program:start (program:tuna) folder '() '())])
          (program:send! r form)
          (program:close-input! r)
          (let-values ([(status output errors) (program:wait r)])
            (check-equal? 4 status))))
      '("(exit 4)\n" "(join-task (fork-task (lambda (restore) (exit 4))))\n"))))

(test "the main thread writes and exits while the console waits for input"
  (let ([folder (home "waiting")])
    (write-file! (string-append folder "/.config/tuna/init.ss")
      (string-append
        "(import (tuna))\n(import (rename (only (chezscheme) sleep) (sleep chez:sleep)))\n"
        "(fork-task (lambda (restore) (chez:sleep (make-time 'time-duration 200000000 0))\n"
        "  (spawn-task (lambda (restore) (call-with-output-file (string-append (getenv \"HOME\") \"/posted\") (lambda (p) (write 'posted p)))))\n"
        "  (chez:sleep (make-time 'time-duration 300000000 0))\n  (exit 5)))\n(import (console))\n"))
    (let* ([started (seconds-now)] [r (program:start (program:tuna) folder '() '())])
      (let-values ([(status output errors) (program:wait r)])
        (check-equal? 5 status)
        (check-equal? 'posted (read-datum (string-append folder "/posted")))
        (check (< (- (seconds-now) started) 3))))))

(test "Tuna reads no standard input: with no configuration it runs until a signal ends it"
  (let* ([folder (home "empty")] [r (program:start (program:tuna) folder '() '())])
    (program:send! r "(exit 6)\n")
    (pause-seconds 0.5)
    (check (not (program:ended? r)))
    (program:signal! r (processes:signal term))
    (let-values ([(status output errors) (program:wait r)])
      (check-equal? -15 status)
      (check-equal? "" output)
      (check-equal? "" errors))))

(test "Tuna reads no standard input: a configuration without the console ends with its own exit"
  (let ([folder (home "batch")])
    (write-file! (string-append folder "/.config/tuna/init.ss") "(exit 7)\n")
    (let ([r (program:start (program:tuna) folder '() '())])
      (program:send! r "(exit 6)\n")
      (program:close-input! r)
      (let-values ([(status output errors) (program:wait r)])
        (check-equal? 7 status)))))

#!tuna
(import (plugins) (plugins files) (test-runner))

;; The flags start owns are read from (command-line), which it leaves as it
;; is, so a body run again after a reload finds them too; the plugins see
;; the rest in (command-line-arguments).
(define (%flag-value prefix arguments)
  (let ([found (find (lambda (a) (string-prefix? prefix a)) arguments)])
    (and found (substring found (string-length prefix) (string-length found)))))

(define (%folder variable fallback)
  (let ([value (getenv variable)])
    (if (and value (> (string-length value) 0)) (normal-path value) fallback)))

;; The paths after --test are the runner's, not files for a plugin to open.
(define (%before-test arguments)
  (cond
    [(null? arguments) '()]
    [(string=? (car arguments) "--test") '()]
    [else (cons (car arguments) (%before-test (cdr arguments)))]))

;; A test run that raises has nothing left to do, and nothing else would
;; end the process.
(define (%spawn-exiting thunk)
  (spawn-task (lambda (restore) (guard (c [#t (report c) (exit 1)]) (thunk)))))

;; Installs pause for git and builds, and a module's body cannot pause, so
;; the configuration is read in a task of its own.
(let* ([program (normal-path (car (command-line)))]
       [arguments (cdr (command-line))]
       [home (normal-path (or (getenv "HOME") (errorf 'start "HOME is not set")))]
       [config (%folder "XDG_CONFIG_HOME" (string-append home "/.config"))]
       [data (%folder "XDG_DATA_HOME" (string-append home "/.local/share"))]
       [cache (%folder "XDG_CACHE_HOME" (string-append home "/.cache"))]
       [init (let ([given (%flag-value "--config=" arguments)])
               (if given (normal-path given) (string-append config "/tuna/init.ss")))])
  (command-line-arguments
    (remp (lambda (a) (or (string-prefix? "--config=" a) (string-prefix? "--test-file=" a) (string=? a "--install")))
          (%before-test arguments)))
  (if (member "--install" arguments)
      (plugins:start-install! program home init (string-append data "/tuna") (string-append cache "/tuna"))
      (plugins:start! program home init (string-append data "/tuna") (string-append cache "/tuna")))
  (cond
    [(member "--install" arguments) (spawn-task (lambda (restore) (exit (if (plugins:install-all!) 0 1))))]
    [(member "--test" arguments)
     => (lambda (tail) (%spawn-exiting (lambda () (exit (if (test-runner:run-paths (cdr tail)) 0 1)))))]
    [(%flag-value "--test-file=" arguments)
     => (lambda (file)
          (%spawn-exiting
            (lambda ()
              (plugins:load-configuration!)
              (test-runner:evaluate-file file))))]
    [else (spawn-task (lambda (restore) (plugins:load-configuration!)))]))

#!tuna
(import (plugins) (plugins files))

;; The flags start owns are read from (command-line), which it leaves as it
;; is, so a body run again after a reload finds them too; the plugins see
;; the rest in (command-line-arguments).
(define (%flag-value prefix arguments)
  (let ([found (find (lambda (a) (string-prefix? prefix a)) arguments)])
    (and found (substring found (string-length prefix) (string-length found)))))

(define (%folder variable fallback)
  (let ([value (getenv variable)])
    (if (and value (> (string-length value) 0)) (normal-path value) fallback)))

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
  (command-line-arguments (remp (lambda (a) (string-prefix? "--config=" a)) arguments))
  (plugins:start! program home init (string-append data "/tuna") (string-append cache "/tuna"))
  (spawn-task (lambda (restore) (plugins:load-configuration!))))

(import (tuna) (test) (test-runner) (caught-reports) (plugins) (eval) (eval-test))

(test "eval-file evaluates a file that is no module form by form as the REPL's owner, and eval-text does so with text and no path, giving the last form's values"
  (eval-test:write-file! "scratch.ss" "(define scratch-owner (current-owner))\n(define scratch-value 1)\n")
  (eval:eval-file "~/scratch.ss")
  (check-equal? (list (plugins:repl-owner) 1) (list (eval:eval-text "scratch-owner") (eval:eval-text "scratch-value")))
  (check-equal? 3 (eval:eval-text "(define text-owner (current-owner)) (+ 1 2)"))
  (check-equal? (plugins:repl-owner) (eval:eval-text "text-owner"))
  (check-equal? (void) (eval:eval-text "")))

(test "text with the path of a file that is no module evaluates the same way, giving the last form's values"
  (check-equal? (list 2 (plugins:repl-owner))
    (call-with-values (lambda () (eval:eval-text "1 (values 2 (current-owner))" "~/notes.ss")) list)))

(test "eval-file of a missing file raises, and both check their arguments"
  (check-raises i/o-file-does-not-exist-error? (eval:eval-file "~/nothere.ss"))
  (check-raises assertion-violation? (eval:eval-file 'scratch))
  (check-raises assertion-violation? (eval:eval-text 'scratch))
  (check-raises assertion-violation? (eval:eval-text "1" 'scratch)))

(define fresh-path ".config/tuna/lib/fresh.sls")

(test "a module's file that no import has loaded loads it, and text with its path evaluates in its scope"
  (eval-test:write-file! fresh-path "#!tuna\n(define (x) 'fresh)\n")
  (eval:eval-file (string-append "~/" fresh-path))
  (check-equal? 'fresh (eval:eval-text "(fresh:x)"))
  (eval:eval-text "(define (x) 'assigned)" (string-append "~/" fresh-path))
  (check-equal? 'assigned (eval:eval-text "(fresh:x)")))

(define loads '())

(define (note-load load instance) (set! loads (cons (owner-name instance) loads)) (load instance))

(test "a loaded module's file reloads it, by any path to it"
  (let ([home-name (path-last (getenv "HOME"))])
    (advice-add! module-loaded note-load)
    (eval:eval-file "~/.config/tuna/lib//fresh.sls")
    (eval:eval-file "~/.config/tuna/../tuna/lib/./fresh.sls")
    (eval:eval-file (string-append "../" home-name "/.config/tuna/lib/fresh.sls"))
    (advice-remove! module-loaded note-load)
    (check-equal? '(((fresh) (fresh) (fresh)) fresh) (list loads (eval:eval-text "(fresh:x)")))))

(define (make-folders! path)
  (unless (file-exists? path)
    (make-folders! (path-parent path))
    (mkdir path)))

(test "a #!tuna file that its name's lookup does not find is not a module"
  (let ([home (eval-test:home-path "shadowed")])
    (test-runner:make-home! home)
    (make-folders! (string-append home "/.local/share/tuna/plugins/shadow/src"))
    (call-with-output-file (string-append home "/.local/share/tuna/plugins/shadow/src/shadow.sls")
      (lambda (p) (put-string p "#!tuna\n(define (x) 'installed)\n")))
    (let-values ([(status errors) (test-runner:run-file "file/shadowed.ss" home)])
      (check-equal? 0 status)
      (check-equal? "" errors))))

(test "a module whose name has two parts reloads like any other"
  (mkdir (eval-test:home-path ".config/tuna/lib/slice"))
  (eval-test:write-file! ".config/tuna/lib/slice/highlight.sls" "#!tuna\n(define (color) 'red)\n")
  (check-equal? 'red (eval:eval-text "(import (slice highlight)) (slice/highlight:color)"))
  (eval-test:write-file! ".config/tuna/lib/slice/highlight.sls" "#!tuna\n(define (color) 'blue)\n")
  (eval:eval-file "~/.config/tuna/lib/slice/highlight.sls")
  (check-equal? 'blue (eval:eval-text "(slice/highlight:color)")))

(import (tuna) (test) (test-runner) (plugins) (fixtures) (remotes))

(define loaded-calls 0)
(define (count-loaded next) (set! loaded-calls (+ loaded-calls 1)) (next))

(fixtures:write-lib-module! '(greet) '((define (text name) (string-append "Hello, " name "!"))))
(advice-add! plugins:configuration-loaded count-loaded)
(fixtures:load-configuration! '((import (tuna) (greet)) (define configured 'yes)))

(test "configuration-loaded is called once the configuration has been evaluated, and configuration-file names it"
  (check-equal? 1 loaded-calls)
  (check-equal? (fixtures:configuration-path) (plugins:configuration-file)))

(test "the REPL's owner is made again after it unloads"
  (let ([repl (plugins:repl-owner)])
    (check-equal? repl (plugins:repl-owner))
    (unload-owner! repl)
    (check (not (eq? repl (plugins:repl-owner))))
    (check-equal? '(repl) (owner-name (plugins:repl-owner)))))

(test "call-reporting reports a raise with the form's position and returns after-report's value, and reports a warning and goes on"
  (let ([form (car (plugins:file-forms (fixtures:configuration-path)))])
    (let* ([value #f]
           [reports (test-runner:reports-during
                      (lambda () (set! value (plugins:call-reporting form (lambda () (car '())) (lambda () 'after)))))])
      (check-equal? 'after value)
      (check-equal? '(1) (map fixtures:reported-line reports)))
    (let* ([value #f]
           [reports (test-runner:reports-during
                      (lambda () (set! value (plugins:call-reporting form (lambda () (warning 'here "careful") 'went-on) (lambda () 'after)))))])
      (check-equal? 'went-on value)
      (check-equal? '("careful") (map fixtures:message reports)))))

(test "module-source names a module's plugin by its git address or local folder, user for lib/, and tuna for Tuna's own"
  (fixtures:at-repl `(use-plugin vertico (git ,(remotes:url "vertico"))))
  (check-equal? (remotes:url "vertico") (plugins:module-source '(vertico)))
  (check-equal? 'user (plugins:module-source '(greet)))
  (check-equal? 'tuna (plugins:module-source '(kill-ring))))

(test "install! refuses a line with no source, and update! a local plugin"
  (check-equal? "no source for the plugin" (fixtures:raised-message (lambda () (plugins:install! '(use-plugin nowhere)))))
  (fixtures:write-file! (fixtures:home-path "src" "notes" "src" "notes.sls") (fixtures:module-text '((define (where) "notes"))))
  (plugins:install! '(use-plugin notes (local "~/src/notes")))
  (check-equal? "a local plugin is not fetched" (fixtures:raised-message (lambda () (plugins:update! 'notes))))
  (check-equal? #f (plugins:commit 'notes)))

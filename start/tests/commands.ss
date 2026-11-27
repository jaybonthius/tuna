(import (tuna) (test) (test-runner) (plugins) (options) (fixtures) (remotes))

(define spell-commits (remotes:commits "spell"))
(define plugins-folder (fixtures:home-path ".local" "share" "tuna" "plugins"))

(define (line-of id)
  (call-with-input-file (fixtures:configuration-path)
    (lambda (p)
      (let loop ()
        (let ([form (read p)])
          (cond
            [(eof-object? form) #f]
            [(and (pair? form) (eq? (car form) 'use-plugin) (eq? (cadr form) id)) form]
            [else (loop)]))))))

(define (lines)
  (call-with-input-file (fixtures:configuration-path)
    (lambda (p)
      (let loop ()
        (let ([form (read p)])
          (cond
            [(eof-object? form) '()]
            [(and (pair? form) (eq? (car form) 'use-plugin)) (cons form (loop))]
            [else (loop)]))))))

(fixtures:write-file! (string-append plugins-folder "/greet/src/greet.sls") (fixtures:module-text '((define (text) "hello"))))

(define head
  (format "(import (tuna) (options))\n(use-plugin spell (git ~s) (commit ~s))\n(options:set! spell:language \"en-GB\")\n(define spell:dictionary-path (lambda () \"/home/groucho/words\"))\n(use-plugin sources (git ~s))\n(use-plugin compat)\n(use-plugin consult)\n(use-plugin embark)\n(use-plugin embark-consult)"
    (remotes:url "spell") (fixtures:short (car spell-commits)) (remotes:url "sources")))
(define tail "\n(define after-lines #t)\n")

(fixtures:write-file! (fixtures:configuration-path) (string-append head tail))
(define first-reports (test-runner:reports-during plugins:load-configuration!))


(test "at start the line installs its plugin at the line's commit, and the configuration sets and overrides its definitions, with no report"
  (check-equal? '() first-reports)
  (check-equal? (car spell-commits) (plugins:commit 'spell))
  (check-equal? '("/home/groucho/words" "en-GB") (fixtures:at-repl '(list (spell:dictionary-path) (spell:language))))
  (check-equal? '(((init) override) ((spell) define)) (fixtures:changes-of spell:dictionary-path))
  (check-equal? '(((init) "en-GB")) (fixtures:at-repl '(options:settings spell:language))))

(test "a plugin may be a folder of another plugin's repository, installed at the newest commit"
  (check-equal? '("newest" #t) (fixtures:at-repl '(list (embark-consult:version) (embark:integrated))))
  (check-equal? '(spell sources compat consult embark embark-consult greet) (plugins:installed)))

(define vertico-line `(use-plugin vertico (git ,(remotes:url "vertico"))))

(test "install! writes its line after the last line with the full commit, keeps the rest of the file, and loads nothing"
  (plugins:install! vertico-line)
  (check-equal? (format "~a\n~s~a" head (append vertico-line (list (list 'commit (car (remotes:commits "vertico"))))) tail)
    (fixtures:read-file (fixtures:configuration-path)))
  (check (memq 'vertico (plugins:installed)))
  (check-equal? #f (module-owner '(vertico))))

(test "install! refuses a plugin the configuration has a line for"
  (check-equal? "the configuration has a line for the plugin" (fixtures:raised-message (lambda () (plugins:install! vertico-line)))))

(test "a line typed at the REPL loads its plugin"
  (fixtures:at-repl '(use-plugin vertico))
  (check-equal? 10 (fixtures:at-repl '(vertico:count))))

(test "update! checks out the newest commit, writes it into the line, and reloads the plugin's modules, keeping the configuration's override"
  (let ([loads '()])
    (define (note-load next name) (set! loads (cons (owner-name name) loads)) (next name))
    (advice-add! module-loaded note-load)
    (plugins:update! 'spell)
    (advice-remove! module-loaded note-load)
    (check-equal? '((spell)) loads))
  (check-equal? (cadr spell-commits) (plugins:commit 'spell))
  (check-equal? `(use-plugin spell (git ,(remotes:url "spell")) (commit ,(cadr spell-commits))) (line-of 'spell))
  (check-equal? "/home/groucho/words" (fixtures:at-repl '(spell:dictionary-path)))
  (plugins:update! 'spell (fixtures:short (car spell-commits)))
  (check-equal? (car spell-commits) (plugins:commit 'spell)))

(test "a line with no source gets only its commit, and still takes its source from the index"
  (plugins:update! 'compat (fixtures:short (car (remotes:commits "compat"))))
  (check-equal? `(use-plugin compat (commit ,(car (remotes:commits "compat")))) (line-of 'compat))
  (check-equal? "compat buffer" (fixtures:at-repl '(consult:buffer))))

(define flaky-commits (remotes:commits "flaky"))
(define flaky-line `(use-plugin flaky (git ,(remotes:url "flaky")) (commit ,(car flaky-commits))))

(test "when a module fails to load, the update is reported and the plugin goes back to its commit, its line unchanged"
  (plugins:install! `(use-plugin flaky (git ,(remotes:url "flaky")) (commit ,(fixtures:short (car flaky-commits)))))
  (fixtures:at-repl '(use-plugin flaky))
  (check-equal? '(flaky) (map condition-who (test-runner:reports-during (lambda () (plugins:update! 'flaky)))))
  (check-equal? 1 (fixtures:at-repl '(flaky:version)))
  (check-equal? (car flaky-commits) (plugins:commit 'flaky))
  (check-equal? flaky-line (line-of 'flaky))
  (check-equal? (format "commit nope not found in ~a" (remotes:url "flaky"))
    (fixtures:raised-message (lambda () (plugins:update! 'flaky "nope")))))

(test "going back puts back only the plugin's own line, so a line another task wrote meanwhile stays"
  (fixtures:write-file! (fixtures:home-path "src" "notes" "src" "notes.sls") (fixtures:module-text '((define (where) "notes"))))
  (let* ([before (lines)]
         [installing (spawn-task (lambda (restore) (plugins:install! '(use-plugin notes (local "~/src/notes")))))])
    (check-equal? '(flaky) (map condition-who (test-runner:reports-during (lambda () (plugins:update! 'flaky)))))
    (join-task installing)
    (check-equal? (append before '((use-plugin notes (local "~/src/notes")))) (lines))))

(test "a line typed at the REPL has none in the configuration to put back, so going back takes out the line update! wrote"
  (plugins:remove! 'flaky)
  (fixtures:at-repl `(use-plugin flaky (git ,(remotes:url "flaky")) (commit ,(fixtures:short (car flaky-commits)))))
  (let ([before (fixtures:read-file (fixtures:configuration-path))])
    (check-equal? '(flaky) (map condition-who (test-runner:reports-during (lambda () (plugins:update! 'flaky)))))
    (check-equal? before (fixtures:read-file (fixtures:configuration-path))))
  (check-equal? 1 (fixtures:at-repl '(flaky:version)))
  (check-equal? (car flaky-commits) (plugins:commit 'flaky)))

(test "remove! unloads the plugin's modules, comments out its line and deletes its folder"
  (plugins:remove! 'vertico)
  (check (not (memq 'vertico (plugins:installed))))
  (check (not (file-exists? (string-append plugins-folder "/vertico"))))
  (check-equal? #f (line-of 'vertico))
  (check-equal? "module (vertico) is unloaded" (fixtures:raised-message (lambda () (fixtures:at-repl '(vertico:count))))))

(test "a line with a branch installs the branch's newest commit"
  (plugins:install! `(use-plugin vertico (git ,(remotes:url "vertico")) (branch "dev")))
  (fixtures:at-repl '(use-plugin vertico))
  (check-equal? 20 (fixtures:at-repl '(vertico:count))))

(test "remove-unused! deletes only the plugins with no line none of whose modules a lookup has found"
  (plugins:remove-unused!)
  (check-equal? '(spell sources compat consult embark embark-consult notes vertico flaky) (plugins:installed))
  (check-equal? '("compat" "compat.installed" "consult" "consult.installed" "embark" "embark-consult" "embark-consult.installed"
                  "embark.installed" "flaky" "flaky.installed" "notes.installed" "sources" "sources.installed" "spell"
                  "spell.installed" "vertico" "vertico.installed")
    (sort string<? (directory-list plugins-folder))))

(test "an import never installs: one no root answers raises"
  (check-equal? "library ~s not found"
    (guard (c [(message-condition? c) (condition-message c)]) (fixtures:at-repl '(import (nowhere))))))

(test "the commands check their arguments"
  (check-equal? "not installed" (fixtures:raised-message (lambda () (plugins:update! 'kill-ring))))
  (check-equal? "not installed" (fixtures:raised-message (lambda () (plugins:remove! 'nothing))))
  (check-equal? "not a use-plugin line" (fixtures:raised-message (lambda () (plugins:install! 'vertico)))))

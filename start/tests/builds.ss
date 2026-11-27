(import (tuna) (test) (test-runner) (plugins) (fixtures))

(define plugins-folder (fixtures:home-path ".local" "share" "tuna" "plugins"))
(define (build-log id) (fixtures:read-file (fixtures:home-path ".cache" "tuna" "builds" (format "~a.log" id))))
(define (log-entry commit status output) (format "build of ~a, status ~a\n~a" commit status output))
(define (failure who id status output)
  (list who (format "the build of ~a failed with status ~a: ~a (output in ~a)"
              id status output (fixtures:home-path ".cache" "tuna" "builds" (format "~a.log" id)))))
(define (raised thunk) (guard (c [(message-condition? c) (list (condition-who c) (fixtures:message c))]) (thunk) #f))

;; Git refuses submodules from local paths unless the user allows them.
(fixtures:write-file! (fixtures:home-path ".gitconfig") "[protocol \"file\"]\n\tallow = always\n")

(define cadd-commits
  (fixtures:commits! "cadd"
    (map (lambda (body) (list (cons "add.c" (format "int cadd(int a, int b) { return ~a; }\n" body))))
         '("a + b" "a + b + 100"))))

(define wrap-build
  (fixtures:forms-text
    '((define (run command)
        (unless (zero? (system command))
          (errorf 'build "~a failed" command)))
      (unless (file-directory? "build") (mkdir "build"))
      (unless (file-directory? "src/build") (mkdir "src/build"))
      (run "cc -O2 -shared -fPIC -o build/libwrap.so vendor/cadd/add.c")
      (with-output-to-file "src/build/paths.ss"
        (lambda () (write `(define shared-object ,(string-append (current-directory) "/build/libwrap.so"))))
        'replace)
      (with-output-to-file "build/facts.ss"
        (lambda ()
          (write (list (scheme-version) (command-line-arguments) (getenv "GIT_TERMINAL_PROMPT")
                       (eof-object? (read-char)) (current-directory))))
        'replace)
      (display "built\n"))))

(define wrap-module
  '((include "build/paths.ss")
    (define add (begin (load-shared-object shared-object) (foreign-procedure "cadd" (int int) int)))
    (define (build-facts) (call-with-input-file (string-append (path-parent shared-object) "/facts.ss") read))))

(define (wrap-commit! files cadd)
  (let ([folder (fixtures:remote-folder "wrap")])
    (unless (file-directory? (string-append folder "/vendor/cadd"))
      (fixtures:commit! "wrap" '())
      (fixtures:git! folder "submodule" "add" "-q" (fixtures:remote-url "cadd") "vendor/cadd"))
    (fixtures:git! (string-append folder "/vendor/cadd") "checkout" "-q" cadd)
    (fixtures:commit! "wrap" files)))

(define wrap-commits
  (let* ([built (wrap-commit! `(("build.ss" . ,wrap-build) ("src/wrap.sls" . ,(fixtures:module-text wrap-module))) (car cadd-commits))]
         [unbuilt (wrap-commit! '(("build.ss" . "(display \"starting\\n\")\n(errorf 'build \"cc is missing\")\n")) (car cadd-commits))]
         [moved (wrap-commit! `(("build.ss" . ,wrap-build)) (cadr cadd-commits))]
         [raising (wrap-commit! `(("src/wrap.sls" . ,(fixtures:module-text (append wrap-module '((car '())))))) (car cadd-commits))])
    (list built unbuilt moved raising)))

(fixtures:write-file! (fixtures:home-path "src" "loc" "build.ss") "(with-output-to-file \"built\" (lambda () (display \"yes\")))\n")
(fixtures:write-file! (fixtures:home-path "src" "loc" "src" "loc.sls") (fixtures:module-text '((define (where) "local"))))

(define configuration-text
  (format "(import (tuna))\n(use-plugin wrap (git ~s) (commit ~s))\n(use-plugin loc (local \"~~/src/loc\"))\n"
    (fixtures:remote-url "wrap") (fixtures:short (car wrap-commits))))

(fixtures:write-file! (fixtures:configuration-path) configuration-text)
(plugins:load-configuration!)

(test "after a checkout Tuna fetches the submodules and runs build.ss with tuna --script in the plugin's folder, with no arguments, empty input and git's prompt off"
  (check-equal? 5 (fixtures:at-repl '(wrap:add 2 3)))
  (check-equal? (list "Chez Scheme Version 10.4.1" '() "0" #t (string-append plugins-folder "/wrap"))
    (fixtures:at-repl '(wrap:build-facts)))
  (check-equal? (log-entry (car wrap-commits) 0 "built\n") (build-log 'wrap)))

(test "a failed build fails the update, which goes back to the previous commit and builds it again, and leaves the configuration as it was"
  (check-equal? (failure 'update-plugin! 'wrap 255 "Exception in build: cc is missing")
    (raised (lambda () (plugins:update! 'wrap (fixtures:short (cadr wrap-commits))))))
  (check-equal? (car wrap-commits) (plugins:commit 'wrap))
  (check-equal? 5 (fixtures:at-repl '(wrap:add 2 3)))
  (check-equal? (string-append (log-entry (cadr wrap-commits) 255 "starting\nException in build: cc is missing\n")
                               (log-entry (car wrap-commits) 0 "built\n"))
    (build-log 'wrap))
  (check-equal? configuration-text (fixtures:read-file (fixtures:configuration-path))))

(test "an update to the same commit builds again, and an update moves the submodules with the plugin"
  (plugins:update! 'wrap (fixtures:short (car wrap-commits)))
  (check-equal? (log-entry (car wrap-commits) 0 "built\n") (build-log 'wrap))
  (plugins:update! 'wrap (fixtures:short (caddr wrap-commits)))
  (check-equal? "int cadd(int a, int b) { return a + b + 100; }\n"
    (fixtures:read-file (string-append plugins-folder "/wrap/vendor/cadd/add.c"))))

(test "an update whose module fails to load is reported and goes back to the previous commit, building it again"
  (check-equal? '(car) (map condition-who (test-runner:reports-during (lambda () (plugins:update! 'wrap (fixtures:short (cadddr wrap-commits)))))))
  (check-equal? (caddr wrap-commits) (plugins:commit 'wrap))
  (check-equal? (string-append (log-entry (cadddr wrap-commits) 0 "built\n") (log-entry (caddr wrap-commits) 0 "built\n"))
    (build-log 'wrap)))

(define broken-commit (fixtures:commit! "broken" `(("build.ss" . "(display \"no compiler\\n\")\n(exit 3)\n")
                                                   ("src/broken.sls" . ,(fixtures:module-text '((define (x) 1)))))))
(define broken-line `(use-plugin broken (git ,(fixtures:remote-url "broken"))))

(test "a failed build fails the install and leaves the plugin as it was, with the build's output in its log"
  (check-equal? (failure 'use-plugin 'broken 3 "no compiler") (raised (lambda () (fixtures:at-repl broken-line))))
  (check (not (file-exists? (string-append plugins-folder "/broken"))))
  (check-equal? (failure 'install-plugin! 'broken 3 "no compiler") (raised (lambda () (plugins:install! broken-line))))
  (check (not (file-exists? (string-append plugins-folder "/broken"))))
  (check-equal? '(wrap loc) (plugins:installed))
  (check-equal? (log-entry broken-commit 3 "no compiler\n") (build-log 'broken)))

(test "install! builds what it installs"
  (plugins:remove! 'wrap)
  (plugins:install! `(use-plugin wrap (git ,(fixtures:remote-url "wrap")) (commit ,(fixtures:short (car wrap-commits)))))
  (check (file-exists? (string-append plugins-folder "/wrap/build/libwrap.so")))
  (check-equal? (car wrap-commits) (plugins:commit 'wrap)))

(test "a local plugin is its author's, so Tuna does not build it"
  (check-equal? "local" (fixtures:at-repl '(loc:where)))
  (check (not (file-exists? (fixtures:home-path "src" "loc" "built")))))

(define gen-commits
  (fixtures:commits! "gen"
    (list
      `(("src/gen.sls" . ,(fixtures:module-text '((define (version) 1)))))
      '(("src/gen.sls" . #f)
        ("build.ss" . "(unless (file-directory? \"src\") (mkdir \"src\"))\n(with-output-to-file \"src/gen.sls\" (lambda () (display \"#!tuna\\n(define (version) 2)\\n\")) 'replace)\n(display \"wrote src/gen.sls\\n\")\n"))
      '(("build.ss" . "(when (file-exists? \"src/gen.sls\") (delete-file \"src/gen.sls\"))\n(unless (file-directory? \"out\") (mkdir \"out\"))\n(with-output-to-file \"out/gen.sls\" (lambda () (display \"#!tuna\\n(define (version) 3)\\n\")) 'replace)\n(display \"wrote out/gen.sls\\n\")\n"))
      '(("build.ss" . "(display \"no compiler\\n\")\n(exit 3)\n")))))

(test "a build may write the plugin's main module, so Tuna looks for it after the build"
  (fixtures:load-configuration! `((import (tuna)) (use-plugin gen (git ,(fixtures:remote-url "gen")) (commit ,(fixtures:short (car gen-commits))))))
  (check-equal? 1 (fixtures:at-repl '(gen:version)))
  (plugins:update! 'gen (fixtures:short (cadr gen-commits)))
  (check-equal? 2 (fixtures:at-repl '(gen:version)))
  (check-equal? (log-entry (cadr gen-commits) 0 "wrote src/gen.sls\n") (build-log 'gen)))

(test "a build that leaves no main module fails the update, which goes back to the previous commit and builds it again"
  (check-equal? '(update-plugin! "plugin gen holds no module (gen)")
    (raised (lambda () (plugins:update! 'gen (fixtures:short (caddr gen-commits))))))
  (check-equal? (cadr gen-commits) (plugins:commit 'gen))
  (check-equal? 2 (fixtures:at-repl '(gen:version)))
  (check-equal? (string-append (log-entry (caddr gen-commits) 0 "wrote out/gen.sls\n") (log-entry (cadr gen-commits) 0 "wrote src/gen.sls\n"))
    (build-log 'gen)))

(test "a failed build fails the update before any module is looked for"
  (check-equal? (failure 'update-plugin! 'gen 3 "no compiler")
    (raised (lambda () (plugins:update! 'gen (fixtures:short (cadddr gen-commits))))))
  (check-equal? (cadr gen-commits) (plugins:commit 'gen))
  (check-equal? 2 (fixtures:at-repl '(gen:version)))
  (check-equal? `((import (tuna)) (use-plugin gen (git ,(fixtures:remote-url "gen")) (commit ,(cadr gen-commits))))
    (call-with-input-file (fixtures:configuration-path) (lambda (p) (let loop () (let ([f (read p)]) (if (eof-object? f) '() (cons f (loop)))))))))

(define made-commit
  (fixtures:commit! "made"
    '(("build.ss" . "(unless (file-directory? \"src\") (mkdir \"src\"))\n(with-output-to-file \"src/made.sls\" (lambda () (display \"#!tuna\\n(define (where) \\\"built\\\")\\n\")) 'replace)\n(display \"wrote src/made.sls\\n\")\n"))))
(define made-line `(use-plugin made (git ,(fixtures:remote-url "made"))))

(test "an install, by a line or by install!, runs the build before it looks for the main module"
  (fixtures:at-repl made-line)
  (check-equal? "built" (fixtures:at-repl '(made:where)))
  (check-equal? (log-entry made-commit 0 "wrote src/made.sls\n") (build-log 'made))
  (plugins:remove! 'made)
  (plugins:install! made-line)
  (check (file-exists? (string-append plugins-folder "/made/src/made.sls")))
  (check-equal? made-commit (plugins:commit 'made)))

(define hollow-commit (fixtures:commit! "hollow" '(("build.ss" . "(display \"nothing to build\\n\")\n"))))
(define hollow-line `(use-plugin hollow (git ,(fixtures:remote-url "hollow"))))

(test "an install whose build leaves no main module leaves the plugin as it was, with the build's output in its log"
  (check-equal? '(install-plugin! "plugin hollow holds no module (hollow)") (raised (lambda () (plugins:install! hollow-line))))
  (check-equal? '(use-plugin "plugin hollow holds no module (hollow)") (raised (lambda () (fixtures:at-repl hollow-line))))
  (check (not (file-exists? (string-append plugins-folder "/hollow"))))
  (check-equal? '(gen made loc wrap) (plugins:installed))
  (check-equal? (log-entry hollow-commit 0 "nothing to build\n") (build-log 'hollow)))

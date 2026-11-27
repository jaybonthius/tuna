(import (tuna) (test) (test-runner) (plugins) (processes) (fixtures))

;; An install of its own, holding only these plugins, so the test fetches
;; nothing from the network and compiles little.
(define installed-bin (path-parent (car (command-line))))
(define bin (fixtures:home-path "install"))
(define tuna (string-append bin "/tuna"))

(define (run! program . arguments)
  (let-values ([(status output errors) (processes:run program arguments)])
    (unless (zero? status) (errorf 'run! "~a ~s failed: ~a" program arguments (utf8->string output)))))

(define (plugin! id forms . files)
  (fixtures:write-module! (format "~a/plugins/~a/src" bin id) (list id) forms)
  (for-each (lambda (file) (fixtures:write-file! (format "~a/plugins/~a/~a" bin id (car file)) (cdr file))) files))

(define (library-line id commit build)
  (fixtures:forms-text
    `((library ,id (git ,(fixtures:remote-url (symbol->string id))) (commit ,commit)
        (library-directories ("src" . "build/obj/src")) (build ,@build)))))

(define (chez-library! id name forms)
  (fixtures:commit! (symbol->string id)
    (list (cons (format "src/~a.sls" name) (fixtures:forms-text (list `(library (,name) ,@forms)))))))

(define (string-contains? s part)
  (let ([n (string-length part)])
    (let loop ([i 0])
      (and (<= (+ i n) (string-length s))
           (or (string=? part (substring s i (+ i n))) (loop (+ i 1)))))))

;; What a configuration saw is written to its home as data, since its
;; checks and reports would reach only the child's standard error.
(define (run-tuna home arguments)
  (let ([home (fixtures:home-path home)])
    (unless (file-directory? home) (mkdir home))
    (let-values ([(status output errors)
                  (processes:run "timeout" (cons* "60" tuna arguments) #f
                    (processes:options [directory home] [environment (test-runner:home-environment home)]
                                       [separate-stderr #t]))])
      (values status (utf8->string output) (utf8->string errors)))))

(define (run-configuration home forms)
  (fixtures:write-file! (fixtures:home-path home ".config" "tuna" "init.ss")
    (fixtures:forms-text
      (append forms '((call-with-output-file (string-append (getenv "HOME") "/seen") (lambda (p) (write seen p)) 'replace) (exit)))))
  (let-values ([(status output errors) (run-tuna home '())])
    (list status errors (call-with-input-file (fixtures:home-path home "seen") read))))

(run! "mkdir" "-p" (string-append bin "/plugins"))
(run! "cp" (car (command-line)) tuna)
(run! "cp" "-R" (string-append installed-bin "/start") (string-append bin "/start"))
(delete-file (string-append bin "/start/tuna.deps"))

(plugin! 'fine '((define (where) "fine")))
(plugin! 'lone '((import (broken)) (define (where) "lone"))
  (cons "tuna.deps" (library-line 'chez-broken (chez-library! 'chez-broken 'broken '((export) (import (chezscheme)))) '("false"))))
(plugin! 'lone-user '((import (lone))))
(plugin! 'unbuilt '((define (where) "unbuilt")) '("build.ss" . "(errorf 'build \"no compiler\")\n"))
(plugin! 'unbuilt-user '((import (unbuilt))))

(define twice-commits
  (fixtures:commits! "chez-twice"
    (map (lambda (n) (list (cons "src/twice.sls" (fixtures:forms-text `((library (twice) (export version) (import (chezscheme)) (define (version) ,n)))))))
         '(1 2))))
(plugin! 'early '((import (prefix (twice) twice:)) (define (version) (twice:version)))
  (cons "tuna.deps" (library-line 'chez-twice (car twice-commits) '())))
(plugin! 'late '((import (prefix (twice) twice:)) (define (version) (twice:version)))
  (cons "tuna.deps" (library-line 'chez-twice (cadr twice-commits) '())))

(define base-commit
  (chez-library! 'chez-base 'base '((export base-name) (import (chezscheme)) (define (base-name) "base"))))
(define counter-commits
  (let* ([first (chez-library! 'chez-counter 'counter '((export counter-version) (import (chezscheme)) (define (counter-version) "1")))]
         [second (fixtures:commit! "chez-counter"
          (list (cons "src/counter.sls"
                      (fixtures:forms-text
                        '((library (counter) (export counter-version) (import (chezscheme) (base))
                            (define (counter-version) (string-append "2 with " (base-name)))))))
                (cons "tuna.deps" (library-line 'chez-base (fixtures:short base-commit) '()))))])
    (list first second)))
(plugin! 'counted '((import (counter)) (define (version) (counter-version)))
  (cons "tuna.deps" (library-line 'chez-counter (fixtures:short (car counter-commits)) '())))

(define-values (install-status install-output install-errors) (run-tuna "installer" '("--install")))
(define (install-libraries) (sort string<? (directory-list (string-append bin "/libraries"))))
(define installed-libraries (install-libraries))

(test "an install with a library and a build that fail prints each failure and the plugins they leave out, loads the rest, and succeeds"
  (check-equal? 0 install-status)
  (check-equal? "" install-errors)
  (for-each
    (lambda (line) (check-equal? line (and (string-contains? install-output line) line)))
    '("library chez-broken could not be installed: the build of library chez-broken failed with status 1"
      "plugin lone is left out: it needs library chez-broken"
      "plugin lone-user is left out: it needs library chez-broken"
      "plugin unbuilt is left out: the build of plugin unbuilt failed with status 255: Exception in build: no compiler"
      "plugin unbuilt-user is left out: the build of plugin unbuilt failed with status 255"))
  (check (not (string-contains? install-output "plugin fine"))))

(test "a failed build is kept beside its plugin's folder, and a failed library leaves nothing in the install"
  (check (file-exists? (string-append bin "/plugins/unbuilt.failed")))
  (check (not (member "chez-broken" installed-libraries))))

(test "at an ordinary start a form reaching a left-out plugin raises plugins:&left-out, naming the plugin and why, and the rest load"
  (check-equal? '(0 "" ("fine" (lone-user lone chez-broken) (unbuilt-user unbuilt #f) (lone lone chez-broken)))
    (run-configuration "user"
      '((import (tuna) (plugins) (fine))
        (define (try name)
          (guard (c [(plugins:left-out? c) (list (car name) (plugins:left-out-plugin c) (plugins:left-out-library c))])
            (plugins:eval-form `(import ,name))))
        (define seen (list (fine:where) (try '(lone-user)) (try '(unbuilt-user)) (try '(lone))))))))

(test "a module of a left-out plugin's name that the lookup finds elsewhere, such as lib/, loads"
  (fixtures:write-module! (fixtures:home-path "stand-in" ".config" "tuna" "lib") '(lone) '((define (where) "the stand-in")))
  (check-equal? '(0 "" "the stand-in") (run-configuration "stand-in" '((import (tuna) (lone)) (define seen (lone:where))))))

(test "own plugins asking for a library at two commits on one line of history get the later, compared in the install's clone with no fetch"
  (check-equal? '(0 "" 2) (run-configuration "later" '((import (tuna) (early)) (define seen (early:version)))))
  (check (not (file-exists? (fixtures:home-path "later" ".local" "share" "tuna" "libraries")))))

(test "an own plugin and an installed one asking for a library at commits on one line of history get the later, installed for the user with what it names"
  (fixtures:commit! "newer" (list (cons "src/newer.sls" (fixtures:module-text '((define (name) "newer"))))
                                  (cons "tuna.deps" (library-line 'chez-counter (fixtures:short (cadr counter-commits)) '()))))
  (check-equal? '(0 "" "2 with base")
    (run-configuration "requests" `((import (tuna)) (use-plugin newer (git ,(fixtures:remote-url "newer"))) (import (counted)) (define seen (counted:version)))))
  (check-equal? '("chez-base" "chez-base.installed" "chez-counter" "chez-counter.installed")
    (sort string<? (directory-list (fixtures:home-path "requests" ".local" "share" "tuna" "libraries"))))
  (check-equal? (cadr counter-commits) (fixtures:git! (fixtures:home-path "requests" ".local" "share" "tuna" "libraries" "chez-counter") "rev-parse" "HEAD")))

(test "a plugin's line for a library that agrees with an own plugin's is served by the install's copy"
  (fixtures:write-file! (fixtures:home-path "src" "agree" "src" "agree.sls") (fixtures:module-text '((import (counter)) (define (version) (counter-version)))))
  (fixtures:write-file! (fixtures:home-path "src" "agree" "tuna.deps") (library-line 'chez-counter (fixtures:short (car counter-commits)) '()))
  (check-equal? '(0 "" "1")
    (run-configuration "agree" `((import (tuna)) (use-plugin agree (local ,(fixtures:home-path "src" "agree"))) (define seen (agree:version)))))
  (check (not (file-exists? (fixtures:home-path "agree" ".local" "share" "tuna" "libraries")))))

(test "only tuna --install installs the install's libraries, and only a Tuna started to install installs"
  (check-equal? '(0 "" refused)
    (run-configuration "refuser" '((import (tuna) (plugins)) (define seen (guard (c [(assertion-violation? c) 'refused]) (plugins:install-all!))))))
  (check-equal? installed-libraries (install-libraries))
  (for-each
    (lambda (home) (check (not (file-exists? (fixtures:home-path home ".local" "share" "tuna" "libraries")))))
    '("user" "stand-in" "later" "refuser")))

(test "own plugins that disagree on a library are reported, failing the install, and leave no plugin out silently"
  (plugin! 'rival '((import (broken)))
    (cons "tuna.deps" (library-line 'chez-broken (fixtures:git! (fixtures:remote-folder "chez-broken") "rev-parse" "HEAD") '("true"))))
  (let-values ([(status output errors) (run-tuna "second" '("--install"))])
    (check (string-contains? errors "ask for chez-broken with different build clauses")))
  (run! "rm" "-rf" (string-append bin "/plugins/rival")))

(test "an install in which a plugin that is not left out fails to load exits with status 1"
  (plugin! 'failing '((car '())))
  (let-values ([(status output errors) (run-tuna "third" '("--install"))])
    (check-equal? 1 status)
    (check (string-contains? errors "car")))
  (run! "rm" "-rf" (string-append bin "/plugins/failing")))

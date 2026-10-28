;;; Starting from init.ss (tuna/boot.ss, tuna/config.ss): finding the
;;; file, loading it without effect, turning plugins on with per-plugin and
;;; per-block isolation, time limits, the start-up report and its log,
;;; tuna check, tuna init, and the command line. Every test writes its init.ss to its own temporary directory
;;; and runs in a fresh kernel.
(import :std/misc/ports
        :std/source
        :std/test
        :tuna/kernel
        :tuna/lib/configuration
        :tuna/boot
        "../support/kernel"
        "../support/string-input"
        "../../../tests/support/config")
(export boot-test)

(def tuna-directory (path-expand (this-source-directory)))
(def repository-directory
  (path-expand "../../../" tuna-directory))
(def test-plugins-module (path-expand "../../../tests/support/config" tuna-directory))

(def (call-with-temporary-directory proc)
  (let (directory (path-expand (string-append "tuna-boot-test-"
                                              (number->string (random-integer 1000000000)))
                               (getenv "TMPDIR" "/tmp")))
    (create-directory* directory)
    (try
     (proc directory)
     (finally
      (delete-file-or-directory directory #t)))))

;; Write an init.ss in DIRECTORY whose body is LINES after the language
;; line and an import of the test plugins; return its path.
(def (write-init (directory : :string) . lines) => :string
  (let (path (path-expand "init.ss" directory))
    (write-file-string
     path
     (string-join (append ["#lang :tuna/config"
                           (string-append "(import \"" test-plugins-module "\")")]
                          lines)
                  "\n"))
    path))

;; Set the environment variables in BINDINGS ((name . value-or-#f) ...)
;; around THUNK.
(def (call-with-environment (bindings : :list) (thunk : :procedure))
  (let (saved (map (lambda ((b : :pair)) (cons (car b) (getenv (car b) #f))) bindings))
    (def (apply-bindings! bs)
      (for-each (lambda ((b : :pair))
                  (if (cdr b) (setenv (car b) (cdr b)) (setenv (car b))))
                bs))
    (try
     (apply-bindings! bindings)
     (thunk)
     (finally (apply-bindings! saved)))))

(def (start (path : :string)) => startup-report
  (start-from-configuration (make-config-choice path "--config")))

;; The report's entries as (what status), and the detail of one.
(def (statuses (report : startup-report)) => :list
  (map (lambda ((e : report-entry)) [(report-entry-what e) (report-entry-status e)])
       (startup-report-entries report)))

(def (detail (report : startup-report) (what : :string)) => :string
  (report-entry-detail
   (find (lambda ((e : report-entry)) (equal? (report-entry-what e) what))
         (startup-report-entries report))))

(def (contains? (text : :string) (part : :string)) => :boolean
  (and (string-contains text part) #t))

;; The live threads named tuna-activation-stop: helpers that sent an
;; activation a stop and still wait for it.
(def (waiting-stoppers)
  (let root ((g (thread-thread-group (current-thread))))
    (let (parent (thread-group-parent g))
      (if parent
        (root parent)
        (let walk ((g g))
          (append (filter (lambda (t)
                            (and (eq? (thread-name t) 'tuna-activation-stop)
                                 (not (thread-state-normally-terminated? (thread-state t)))
                                 (not (thread-state-abnormally-terminated? (thread-state t)))))
                          (thread-group->thread-list g))
                  (apply append (map walk (thread-group->thread-group-list g)))))))))

(def boot-test
  (test-suite "start-up from init.ss"
    (test-case "a user's config block may use undeclared services but turns off with its target"
      (call-with-temporary-directory
        (lambda (directory)
          (let (path (write-init directory
                       "(import :tuna/kernel)"
                       "(use-plugin provider)"
                       "(use-plugin good config: (unless (service-provider probe-service) (error \"Missing probe\")) (probe-on! 'unlisted-config))"))
            (call-with-fresh-kernel []
              (lambda ()
                (let (report (start path))
                  (check (statuses report)
                         => '(("config-blocks" on) ("provider" on) ("good" on)
                              ("config: block of good" on) ("your own code (plugin init)" on)))
                  (check (probe-on? 'unlisted-config) => #t)
                  (activate-plugin! test-input)
                  (start-editor-loop!)
                  (call-on-editor-loop (lambda () (deactivate-plugin! good)))
                  (check (call-on-editor-loop (lambda () (probe-on? 'unlisted-config))) => #f)
                  (check (plugin-active? provider) => #t))))))))

    (test-case "program flags are parsed; plugin arguments wait for the configuration"
      (check (parse-command-line []) => '(run #f ()))
      (check (parse-command-line ["--port" "8001"]) => '(run #f ("--port" "8001")))
      (check (parse-command-line ["--config" "a.ss" "--port" "8001"])
             => '(run "a.ss" ("--port" "8001")))
      (check (parse-command-line ["--greeting" "hi" "--config" "a.ss" "--times" "2"])
             => '(run "a.ss" ("--greeting" "hi" "--times" "2")))
      (check (parse-command-line ["--config"]) => #f)
      (check (parse-command-line ["--config" "--help"]) => #f)
      (check (parse-command-line ["--bogus"]) => '(run #f ("--bogus")))
      (check (parse-command-line ["check"]) => '(check #f ()))
      (check (parse-command-line ["check" "--config" "a.ss" "--port" "8001"])
             => '(check "a.ss" ("--port" "8001")))
      (check (parse-command-line ["--help" "--config" "a.ss"]) => '(help "a.ss" ()))
      (check (parse-command-line ["check" "--help"]) => '(help #f ()))
      (check (parse-command-line ["init"]) => '(init))
      (check (parse-command-line ["init" "--config" "a.ss"]) => #f)
      (check (parse-command-line ["reload"]) => '(reload))
      (check (parse-command-line ["reload" "--greeting" "hi"]) => #f))

    (test-case "discovery: --config, then TUNA_CONFIG, then XDG_CONFIG_HOME, then HOME"
      (call-with-environment
       '(("TUNA_CONFIG" . "/env/init.ss") ("XDG_CONFIG_HOME" . "/xdg") ("HOME" . "/home/u"))
       (lambda ()
         (check (config-choice-path (find-configuration "/flag/init.ss")) => "/flag/init.ss")
         (check (config-choice-origin (find-configuration "/flag/init.ss")) => "--config")
         (check (config-choice-path (find-configuration #f)) => "/env/init.ss")
         (call-with-environment '(("TUNA_CONFIG" . #f))
           (lambda ()
             (check (config-choice-path (find-configuration #f)) => "/xdg/tuna/init.ss")
             (call-with-environment '(("XDG_CONFIG_HOME" . "relative"))
               (lambda ()
                 (check (config-choice-path (find-configuration #f))
                        => "/home/u/.config/tuna/init.ss")))))))
      (check (config-choice-path (find-configuration "relative/init.ss"))
             => (path-expand "relative/init.ss")))

    (test-case "no configuration: nothing turned on; the report says how to get one"
      (call-with-fresh-kernel []
        (lambda ()
          (let (report (start "/nonexistent/tuna/init.ss"))
            (check (startup-report-entries report) => [])
            (check (contains? (startup-report-problem report) "tuna init") ? values)
            (check (contains? (startup-report-text report) "/nonexistent/tuna/init.ss") ? values)
            ;; Only the start-up code's own configuration service.
            (check (map service-info-provider (describe-services)) => '(session-owner))))))

    (test-case "loading has no effect; activation applies plugins, blocks, and code"
      (call-with-temporary-directory
       (lambda (directory)
         (let (path (write-init directory
                                "(use-plugin good config: (probe-on! 'good-block))"
                                "(probe-on! 'user)"))
           (call-with-fresh-kernel []
             (lambda ()
               (let (loaded (load-configuration path))
                 (check (configuration? loaded) ? values)
                 (check (map (lambda ((d : declaration)) (plugin-name (declaration-target d)))
                             (configuration-declarations loaded))
                        => '(good))
                 (check (probe-on? 'good) => #f)
                 (check (probe-on? 'good-block) => #f)
                 (check (probe-on? 'user) => #f)
                 (check (plugin-active? good) => #f)
                 (check (statuses (let (choice (make-config-choice path "--config"))
                                    (make-startup-report choice #f (activate-configuration! choice loaded))))
                        => '(("config-blocks" on) ("good" on)
                             ("config: block of good" on)
                             ("your own code (plugin init)" on)))
                 (check (probe-on? 'good) => #t)
                 (check (probe-on? 'good-block) => #t)
                 (check (probe-on? 'user) => #t))))
           (check (probe-on? 'good) => #f)
           (check (probe-on? 'user) => #f)))))

    (test-case "a failing plugin is rolled back, others come up, dependents are skipped"
      (call-with-temporary-directory
       (lambda (directory)
         (let (path (write-init directory
                                "(use-plugin dependent)"
                                "(use-plugin failing-provider)"
                                "(use-plugin good)"))
           (call-with-fresh-kernel []
             (lambda ()
               (let (report (start path))
                 (check (statuses report)
                        => '(("failing-provider" failed) ("good" on)
                             ("dependent" skipped) ("your own code (plugin init)" on)))
                 (check (contains? (detail report "failing-provider") "fails on purpose") ? values)
                 (check (detail report "dependent") => "needs probe, which no plugin provides")
                 (check (probe-on? 'failing-provider) => #f)
                 (check (service-provider probe-service) => #f)
                 (check (plugin-active? dependent) => #f)
                 (check (probe-on? 'good) => #t)
                 (check (contains? (startup-report-text report) "init.ss:3") ? values)
                 (check (contains? (startup-report-text report) "1 skipped") ? values))))))))

    (test-case "a plugin is turned on once a later one provides what it needs"
      (call-with-temporary-directory
       (lambda (directory)
         (let (path (write-init directory
                                "(use-plugin dependent)"
                                "(use-plugin provider)"))
           (call-with-fresh-kernel []
             (lambda ()
               (check (statuses (start path))
                      => '(("provider" on) ("dependent" on)
                           ("your own code (plugin init)" on)))))))))

    (test-case "a failing config: block is undone alone and follows its plugin"
      (call-with-temporary-directory
       (lambda (directory)
         (let (path (write-init directory
                                "(use-plugin good config: (probe-on! 'bad-block) (error \"block fails\"))"
                                "(use-plugin provider config: (probe-on! 'provider-block))"))
           (call-with-fresh-kernel []
             (lambda ()
               (let (report (start path))
                 (check (assoc "config: block of good" (statuses report))
                        => '("config: block of good" failed))
                 (check (detail report "config: block of good") => "block fails")
                 (check (probe-on? 'bad-block) => #f)
                 (check (probe-on? 'good) => #t)
                 (check (probe-on? 'provider-block) => #t)
                 ;; While the loop runs, the block goes and comes with its plugin.
                 (activate-plugin! test-input)
                 (start-editor-loop!)
                 (call-on-editor-loop (lambda () (deactivate-plugin! provider)))
                 (check (wait-until (lambda () (not (probe-on? 'provider-block)))) ? values)
                 (call-on-editor-loop (lambda () (activate-plugin! provider)))
                 (check (wait-until (lambda () (probe-on? 'provider-block))) ? values))))))))

    (test-case "an error in the user's own code undoes only that code"
      (call-with-temporary-directory
       (lambda (directory)
         (let (path (write-init directory
                                "(use-plugin good)"
                                "(probe-on! 'user)"
                                "(error \"user code fails\")"))
           (call-with-fresh-kernel []
             (lambda ()
               (let (report (start path))
                 (check (statuses report)
                        => '(("good" on) ("your own code (plugin init)" failed)))
                 (check (detail report "your own code (plugin init)") => "user code fails")
                 (check (probe-on? 'user) => #f)
                 (check (probe-on? 'good) => #t))))))))

    (test-case "a syntax error turns nothing on and reports the line"
      (call-with-temporary-directory
       (lambda (directory)
         (let (path (write-init directory
                                "(use-plugin good)"
                                "(probe-on! 'user"))
           (call-with-fresh-kernel []
             (lambda ()
               (let (report (start path))
                 (check (startup-report-entries report) => [])
                 (check (contains? (startup-report-problem report)
                                   (string-append path ":4:1: Incomplete form"))
                        ? values)
                 (check (contains? (startup-report-problem report) "Nothing was turned on") ? values)
                 (check (plugin-active? good) => #f))))))))

    (test-case "unknown names and bad declarations fail the load"
      (call-with-temporary-directory
       (lambda (directory)
         (call-with-fresh-kernel []
           (lambda ()
             (let (problem (load-configuration (write-init directory "(use-plugin no-such-plugin)")))
               (check (contains? problem "Reference to unbound identifier") ? values)
               (check (contains? problem "init.ss:3:13: Reference to unbound identifier: no-such-plugin")
                      ? values))
             (check (contains? (load-configuration (write-init directory "(use-plugin 42)"))
                               "Bad syntax")
                    ? values)
             (check (contains? (load-configuration (write-init directory "(use-plugin car)"))
                               "use-plugin needs a plugin")
                    ? values)
             (check (contains? (load-configuration (write-init directory
                                                               "(use-plugin good)"
                                                               "(use-plugin good)"))
                               "already declared at")
                    ? values)
             (check (contains? (load-configuration (write-init directory "(use-plugin plugin-named-init)"))
                               "reserved")
                    ? values)
             ;; Not at the top level, use-plugin is the user's own code,
             ;; where it fails when that code runs.
             (let (report (start (write-init directory "(when #t (use-plugin good))")))
               (check (contains? (detail report "your own code (plugin init)") "only at the top level")
                      ? values)
               (check (plugin-active? good) => #f)))))))

    (test-case "a load that loops is stopped and reported"
      (call-with-temporary-directory
       (lambda (directory)
         (let (path (write-init directory
                                "(defrules spin () ((_) (spin)))"
                                "(spin)"))
           (call-with-fresh-kernel []
             (lambda ()
               (parameterize ((load-time-limit 0.5))
                 (let (report (start path))
                   (check (startup-report-entries report) => [])
                   (check (contains? (startup-report-problem report) "did not finish within") ? values)))
               ;; The file is reloaded, not left stuck: fixed, it loads.
               (write-init directory "(use-plugin good)")
               (check (statuses (start path))
                      => '(("good" on) ("your own code (plugin init)" on)))))))))

    (test-case "an activation that hangs is stopped and rolled back; the rest come up"
      (call-with-temporary-directory
       (lambda (directory)
         (let (path (write-init directory
                                "(use-plugin hanging)"
                                "(use-plugin good)"))
           (call-with-fresh-kernel []
             (lambda ()
               (parameterize ((activation-time-limit 0.5))
                 (let (report (start path))
                   (check (statuses report)
                          => '(("hanging" failed) ("good" on)
                               ("your own code (plugin init)" on)))
                   (check (detail report "hanging")
                          => "did not finish turning on within 0.5 s and was stopped")
                   (check (probe-on? 'hanging) => #f)
                   (check (plugin-active? hanging) => #f)))))))))

    (test-case "an activation that ignores being stopped is waited for, never killed"
      (call-with-temporary-directory
       (lambda (directory)
         (let ((path (write-init directory
                                 "(use-plugin stubborn-provider)"
                                 "(use-plugin dependent)"
                                 "(use-plugin good)"))
               (errors (open-output-string)))
           (call-with-fresh-kernel []
             (lambda ()
               (let (report (parameterize ((activation-time-limit 0.2)
                                           (stop-grace 0.2)
                                           (current-error-port errors))
                              (start path)))
                 (check (contains? (get-output-string errors)
                                   "stubborn-provider did not stop when asked after 0.2 s; start-up is waiting for it")
                        ? values)
                 (check (statuses report)
                        => '(("stubborn-provider" failed) ("good" on)
                             ("dependent" skipped) ("your own code (plugin init)" on)))
                 (check (detail report "stubborn-provider") => "stubborn-provider gave up")
                 ;; The stop it swallowed left no thread waiting on this one,
                 ;; which would lend this thread its priority for good.
                 (check (waiting-stoppers) => [])
                 ;; Rolled back: no provider is left without its plugin.
                 (check (probe-on? 'stubborn) => #f)
                 (check (service-provider probe-service) => #f)
                 (check (map (lambda ((info : service-info))
                               [(service-info-name info) (service-info-provider info)
                                (service-info-dependents info)])
                             (describe-services))
                        => '((configuration session-owner ()) (probe #f ()))))))
           ;; Deactivating everything left nothing behind.
           (check (probe-on? 'good) => #f)
           (check (probe-on? 'stubborn) => #f)))))

    (test-case "configuration rejects two declared providers before activation"
      (call-with-temporary-directory
        (lambda (directory)
          (let* ((path (write-init directory "(use-plugin provider)" "(use-plugin better-provider)"))
                 (problem (check-configuration (make-config-choice path "--config"))))
            (check (contains? problem "service probe is provided by both provider and better-provider") => #t)))))

    (test-case "load-time code is limited to imports and declarations"
      (call-with-temporary-directory
       (lambda (directory)
         (call-with-fresh-kernel []
           (lambda ()
             ;; use-plugin takes only a name.
             (check (string? (load-configuration
                              (write-init directory "(import :tuna/kernel)"
                                          "(use-plugin (begin (activate-plugin! good) good))")))
                    ? values)
             (check (plugin-active? good) => #f)
             ;; A leading requires: is the user's code, run only at activation.
             (check (configuration? (load-configuration
                                     (write-init directory "(import :tuna/kernel)"
                                                 "requires: (begin (activate-plugin! good) [])")))
                    ? values)
             (check (plugin-active? good) => #f)
             ;; In a config: block a keyword is an option written too late
             ;; (configuration stage 3): a syntax error, and nothing runs.
             (check (contains? (load-configuration
                                (write-init directory "(import :tuna/kernel)"
                                            "(use-plugin provider config: requires: (begin (activate-plugin! good) []))"))
                               "use-plugin options go before config:")
                    ? values)
             (check (plugin-active? good) => #f)
             ;; A file in another language is not run at all.
             (for-each
              (lambda ((first-line : :string))
                (let (path (path-expand "init.ss" directory))
                  (write-file-string
                   path
                   (string-append first-line
                                  "(import :tuna/kernel \"" test-plugins-module "\")\n"
                                  "(activate-plugin! good)\n"))
                  (check (contains? (load-configuration path)
                                    ":1: the first line must be `#lang :tuna/config`")
                         ? values)
                  (check (plugin-active? good) => #f)))
              ["" "#lang :tuna/prelude\n" "#lang :tuna/configuration\n"]))))))

    (test-case "tuna check loads and validates without turning anything on"
      (call-with-temporary-directory
       (lambda (directory)
         (call-with-fresh-kernel []
           (lambda ()
             (check (contains? (check-configuration (make-config-choice "/nonexistent/init.ss" "TUNA_CONFIG"))
                               "No configuration at /nonexistent/init.ss (TUNA_CONFIG)")
                    ? values)
             (let (path (write-init directory "(use-plugin good" ))
               (check (contains? (check-configuration (make-config-choice path "--config"))
                                 "Incomplete form")
                      ? values))
             (let (path (write-init directory "(use-plugin good)" "(probe-on! 'user)"))
               (check (check-configuration (make-config-choice path "--config")) => #f))
             (check (plugin-active? good) => #f)
             (check (describe-services) => []))))))

    (test-case "the start-up log is replaced on every start"
      (call-with-temporary-directory
       (lambda (directory)
         (let (log (path-expand "state/tuna/startup.log" directory))
           (write-startup-report! "first start\nwith two lines\n" log)
           (write-startup-report! "second start\n" log)
           (check (read-file-string log) => "second start\n")
           (call-with-environment [(cons "XDG_STATE_HOME" (path-expand "state" directory))]
             (lambda () (check (startup-log-path) => log)))))))

    (test-case "the starter declares today's plugins, in order"
      (call-with-fresh-kernel []
        (lambda ()
          (let (loaded (load-configuration (path-expand "starter/init.ss" repository-directory)))
            (check (map (lambda ((d : declaration)) (plugin-name (declaration-target d)))
                        (configuration-declarations loaded))
                   => '(stylesheets commands keys web-transport settings session
                        rope-text-store buffers autosave terminals program-status notifications layout
                        view-commands scrolling html-renderer buttons markdown editing
                        minibuffer completion completion-list files
                        echo-area help
                        configuration))
            (check (declaration-options (car (configuration-declarations loaded)))
                   => '((variant . stellar-default)))
            (check (declaration-options (list-ref (configuration-declarations loaded) 3))
                   => '((port . 0) (hosts)))
            (check (describe-services) => [])))))

    (test-case "tuna init copies the starter once and never overwrites"
      (call-with-temporary-directory
       (lambda (directory)
         (call-with-environment [(cons "XDG_CONFIG_HOME" directory)]
           (lambda ()
             (let (path (path-expand "tuna/init.ss" directory))
               (check (init-configuration!) => (cons #t (string-append "Wrote Tuna's starter configuration to " path ".")))
               (check (read-file-string path)
                      => (read-file-string (path-expand "starter/init.ss" repository-directory)))
               (write-file-string path "mine")
               (check (car (init-configuration!)) => #f)
               (check (read-file-string path) => "mine")))))))))

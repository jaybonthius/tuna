;;; Plugin options in init.ss (tuna/lib/plugin-options.ss) and the
;;; configuration service with its report (tuna/configuration.ss):
;;; options are checked at load with every problem and its line, a load
;;; with a bad option changes nothing, options reach the plugin, and a
;;; changed option replaces the plugin with the running version as the
;;; fallback. Every test writes its files to its own temporary directory
;;; and runs in a fresh kernel.
(import :tuna/plugins/commands/contract
        :std/io
        :std/misc/ports
        :std/net/address
        :std/source
        :std/test
        :tuna/kernel
        :tuna/boot
        :tuna/lib/plugin-options
        :std/interface
        (except-in :tuna/configuration activate-plugin!)
        :tuna/plugins/keys/contract
        :tuna/plugins/commands/plugin
        :tuna/plugins/keys/plugin
        :tuna/plugins/web/plugin
        :tuna/plugins/reload-config/plugin
        "../../tuna/tests/support/kernel"
        (only-in "../../tuna/tests/support/string-input" test-input test-messages current-message)
        "../support/config")
(export options-test)

(def test-plugins-module
  (path-expand "../support/config" (path-expand (this-source-directory))))

(def (call-with-temporary-directory proc)
  (let (directory (path-expand (string-append "tuna-options-test-"
                                              (number->string (random-integer 1000000000)))
                               (getenv "TMPDIR" "/tmp")))
    (create-directory* directory)
    (try
     (proc directory)
     (finally
      (delete-file-or-directory directory #t)))))

;; Write DIRECTORY/init.ss: the language line (line 1), an import of the
;; test plugins (line 2), then LINES from line 3 on.
(def (write-init (directory : :string) . lines) => :string
  (let (path (path-expand "init.ss" directory))
    (write-file-string
     path
     (string-join (append ["#lang :tuna/config"
                           (string-append "(import \"" test-plugins-module "\")")]
                          lines)
                  "\n"))
    path))

(def (start (path : :string)) => startup-report
  (start-from-configuration (make-config-choice path "--config")))

(def (changes (report : reload-report)) => :list
  (map (lambda ((e : report-entry)) [(report-entry-what e) (report-entry-status e)])
       (reload-report-entries report)))

(def (contains? (text : :string) (part : :string)) => :boolean
  (and (string-contains text part) #t))

;; A second, small Configuration provider: reload returns a fixed text
;; and counts calls; the last report is whatever reload returned.
(defclass configuration-stub ((reloads : :fixnum) (last : :t)) final: #t)

(implement Configuration configuration-stub
  (activate! (lambda (self target order) (error "This configuration double does not activate plugins")))
  (set-restart-wrapper! (lambda (self ctx wrapper) (void)))
  (restart (lambda (self owners apply rollback)
             (with-catch (lambda (e) (rollback) (raise e)) apply)))
  (reload! (lambda (self)
             (set! self.reloads (fx1+ self.reloads))
             (set! self.last (string-append "stub reload " (number->string self.reloads) "\n"))
             self.last))
  (last-report (lambda (self) self.last))
  (evaluate (lambda (self form) (error "This configuration double does not evaluate code")))
  (swap! (lambda (self old new) (restart-plugin! old new))))

(def the-stub (configuration-stub reloads: 0 last: #f))

(defplugin (stub-configuration ctx)
  "Provides the configuration service with a stub."
  provides: [configuration-service]
  (context-provide! ctx configuration-service (Configuration the-stub)))

(def (run-command (name : :symbol)) => :void
  ((command-procedure (: (command-ref name) command))))

;; A loopback port nothing listens on now.
(def (free-port) => :fixnum
  (using (socket (tcp-listen (string->address "inet4:127.0.0.1:0")) : ServerSocket)
    (let (address (socket.address))
      (socket.close)
      (:- (InetAddress-port address) :fixnum))))

(def options-test
  (test-suite "plugin options and the configuration report"
    (test-case "declared flags parse through option types and override before activation"
      (call-with-temporary-directory
       (lambda (directory)
         (try
          (call-with-fresh-kernel []
            (lambda ()
              (let* ((path (write-init directory "(use-plugin optioned greeting: \"init\" times: 2)"))
                     (choice (make-config-choice path "--config")))
                ;; check validates but installs no overrides or plugins.
                (check (check-configuration choice ["--greeting" "checked" "--fail" "#t"]) => #f)
                (check (plugin-option-override optioned 'greeting) => #f)
                (check (plugin-active? optioned) => #f)
                (check (startup-report-problem
                        (start-from-configuration choice
                          ["--greeting" "first" "--times" "3" "--fail" "#f" "--greeting" "forced"]))
                       => #f)
                (check (last-greeting) => "forced")
                (check (plugin-option optioned 'times) => 3)
                (check (plugin-option optioned 'fail) => #f)
                (check (plugin-option-override optioned 'times) => "--times")
                (let (spec (make-option-spec 'mode 'normal "A mode." symbol-type "--mode"))
                  (check (parse-option-flag-value optioned spec "normal") => 'normal)))))
          (finally
           (for-each (cut remove-plugin-option-override! optioned <>) '(greeting times fail)))))))

    (test-case "unknown flags, missing values and bad values change nothing"
      (call-with-temporary-directory
       (lambda (directory)
         (call-with-fresh-kernel []
           (lambda ()
             (let* ((path (write-init directory "(use-plugin optioned)"))
                    (choice (make-config-choice path "--config"))
                    (cases '((("--bogus") . "Unknown flag: --bogus")
                            (("--times") . "Flag --times needs a value")
                            (("--times" "--greeting" "hi") . "Flag --times needs a value")
                            (("--times" "11") . "--times: optioned option times must be a whole number from 1 to 10")
                            (("--times" "x") . "--times: optioned option times must be a whole number from 1 to 10")
                            (("--fail" "false") . "--fail: optioned option fail must be #t or #f")
                            (("--greeting" "partial" "--bogus") . "Unknown flag: --bogus"))))
               (for-each
                (lambda (c)
                  (check (check-configuration choice (car c)) => (cdr c))
                  (check (with-catch exception-summary
                           (lambda () (start-from-configuration choice (car c)) "did not fail"))
                         => (cdr c))
                  (check (plugin-active? optioned) => #f)
                  (check (plugin-active? session-owner) => #f)
                  (check (plugin-option-override optioned 'greeting) => #f))
                cases)))))))

    (test-case "two configured plugins cannot claim the same flag, even without arguments"
      (call-with-temporary-directory
       (lambda (directory)
         (call-with-fresh-kernel []
           (lambda ()
             (let* ((path (write-init directory "(use-plugin optioned)"
                                     "(use-plugin optioned-dependent)"))
                    (choice (make-config-choice path "--config"))
                    (problem "Flag --greeting is claimed by both optioned and optioned-dependent"))
               (check (check-configuration choice) => problem)
               (check (with-catch exception-summary (lambda () (start-from-configuration choice))) => problem)
               (check (contains? (command-line-help choice) problem) => #t)
               (check (plugin-active? optioned) => #f)
               (check (plugin-active? session-owner) => #f)))))))

    (test-case "help lists only configured flags with their option docs, without activation"
      (call-with-temporary-directory
       (lambda (directory)
         (call-with-fresh-kernel []
           (lambda ()
             (let* ((path (write-init directory "(use-plugin optioned)"))
                    (choice (make-config-choice path "--config"))
                    (before (activation-count 'optioned))
                    (help (command-line-help choice)))
               (check (contains? help "--config PATH") => #t)
               (check (contains? help "--greeting VALUE  What to say. (optioned)") => #t)
               (check (contains? help "--times VALUE  How often to say it. (optioned)") => #t)
               (check (contains? help "--fail VALUE  Fail on activation. (optioned)") => #t)
               (check (contains? help "--port") => #f)
               (check (activation-count 'optioned) => before)
               (check (plugin-active? session-owner) => #f)
               (write-init directory "(use-plugin good)")
               (check (contains? (command-line-help choice) "  (none)") => #t)
               (write-file-string path "#lang :tuna/config\n(")
               (check (contains? (command-line-help choice) "Plugin flags unavailable:") => #t)
               (delete-file path)
               (let (help (command-line-help choice))
                 (check (contains? help "--help") => #t)
                 (check (contains? help "Plugin flags unavailable: No configuration at") => #t)
                 (check (contains? help "--greeting") => #f))))))))

    (test-case "every option problem is reported with its line, and the load changes nothing"
      (call-with-temporary-directory
       (lambda (directory)
         (call-with-fresh-kernel []
           (lambda ()
             (let ((path (write-init directory "(use-plugin optioned greeting: \"hi\")"))
                   (before (activation-count 'optioned)))
               (start path)
               (check (last-greeting) => "hi")
               (write-init directory
                           "(use-plugin optioned greeting: hi times: 11"
                           "  greting: \"x\" times: 2)"
                           "(use-plugin good colour: \"red\")")
               (let* ((expected ["init.ss line 3: optioned option greeting must be a string"
                                 "init.ss line 3: optioned option times must be a whole number from 1 to 10"
                                 "init.ss line 4: optioned has no option greting; its options are greeting, times, fail"
                                 "init.ss line 4: optioned option times is given twice"
                                 "init.ss line 5: good has no option colour; it takes no options"])
                      (checked (check-configuration (make-config-choice path "--config")))
                      (report (reload-configuration!)))
                 (for-each (lambda (line)
                             (check (contains? checked line) ? values)
                             (check (contains? (reload-report-text report) line) ? values))
                           expected)
                 (check (contains? (reload-report-text report) "Nothing was changed.") ? values)
                 (check (contains? (reload-report-text report) "*** ERROR") => #f)
                 (check (changes report) => [])
                 (check (fx- (activation-count 'optioned) before) => 1)
                 (check (last-greeting) => "hi")
                 (check (probe-on? 'good) => #f)
                 (check (probe-on? 'optioned) => #t))))))))

    (test-case "options are data: quoted values and defaults"
      (call-with-temporary-directory
       (lambda (directory)
         (call-with-fresh-kernel []
           (lambda ()
             (let (path (write-init directory "(use-plugin optioned times: 3)"))
               (check (check-configuration (make-config-choice path "--config")) => #f)
               (start path)
               (check (plugin-option optioned 'times) => 3)
               (check (last-greeting) => "hello")
               (write-init directory "(use-plugin optioned greeting: 'hi)")
               (check (contains? (check-configuration (make-config-choice path "--config"))
                                 "init.ss line 3: optioned option greeting must be a string")
                      ? values)))))))

    (test-case "a changed option replaces the plugin; a failing new value keeps the running one"
      (call-with-temporary-directory
       (lambda (directory)
         (call-with-fresh-kernel []
           (lambda ()
             (let ((path (write-init directory "(use-plugin optioned greeting: \"hi\")"))
                   (before (activation-count 'optioned)))
               (start path)
               (write-init directory "(use-plugin optioned greeting: \"there\")")
               (let (report (reload-configuration!))
                 (check (changes report) => [["optioned" 'replaced]])
                 (check (last-greeting) => "there"))
               (write-init directory "(use-plugin optioned greeting: \"x\" fail: #t)")
               (let (report (reload-configuration!))
                 (check (changes report) => [["optioned" 'failed]])
                 (check (contains? (reload-report-text report) "the running version is back on") ? values)
                 (check (last-greeting) => "there")
                 (check (plugin-option optioned 'fail) => #f)
                 (check (probe-on? 'optioned) => #t))
               (write-init directory "(use-plugin optioned greeting: \"there\")")
               (check (changes (reload-configuration!)) => [])
               (write-init directory "(use-plugin optioned)")
               (check (changes (reload-configuration!)) => [["optioned" 'replaced]])
               (check (last-greeting) => "hello")
               ;; Start, replace, the failing value, the running one back, defaults.
               (check (fx- (activation-count 'optioned) before) => 5)))))))

    (test-case "the web transport's port option, and --port overrides it"
      (let ((option-port (free-port))
            (flag-port (free-port)))
        (try
         (set-plugin-options! web-transport [(cons 'port option-port)])
         (call-with-fresh-kernel [web-transport]
           (lambda ()
             (check (contains? (web-transport-url)
                               (string-append "127.0.0.1:" (number->string option-port) "/"))
                    ? values)))
         (override-plugin-option! web-transport 'port flag-port "--port")
         (call-with-fresh-kernel [web-transport]
           (lambda ()
             (check (contains? (web-transport-url)
                               (string-append "127.0.0.1:" (number->string flag-port) "/"))
                    ? values)))
         (finally
          (remove-plugin-option-override! web-transport 'port)
          (set-plugin-options! web-transport [])))))

    (test-case "an overridden option: noted at start-up; changing it touches nothing"
      (call-with-temporary-directory
       (lambda (directory)
         (try
          (call-with-fresh-kernel []
            (lambda ()
              (let* ((path (write-init directory "(use-plugin optioned greeting: \"a\")"))
                     (report (start-from-configuration (make-config-choice path "--config")
                                                       ["--greeting" "forced"]))
                     (before (activation-count 'optioned)))
                (check (last-greeting) => "forced")
                (check (contains? (startup-report-text report)
                                  "optioned (init.ss:3): option greeting is overridden by --greeting")
                       ? values)
                (write-init directory "(use-plugin optioned greeting: \"b\")")
                (let (report (reload-configuration!))
                  (check (changes report) => [["optioned" 'deferred]])
                  (check (contains? (reload-report-text report)
                                    "option greeting is overridden by --greeting, so the change takes effect only when Tuna starts without the override")
                         ? values))
                (check (activation-count 'optioned) => before)
                ;; A restart caused by another option still reads the override.
                (write-init directory "(use-plugin optioned greeting: \"c\" times: 2)")
                (check (changes (reload-configuration!)) => [["optioned" 'replaced]])
                (check (last-greeting) => "forced")
                (check (plugin-option-override optioned 'greeting) => "--greeting"))))
          (finally
           (remove-plugin-option-override! optioned 'greeting))))))

    (test-case "command-line overrides survive a source plugin being read again"
      (call-with-temporary-directory
       (lambda (directory)
         (let ((helper (path-expand "flag-owner.ss" directory))
               (old #f))
           (def (write-helper (greeting : :string)) => :void
             (write-file-string helper
               (string-append
                "(import :tuna/kernel :tuna/lib/plugin-options)\n(export flag-owner)\n"
                "(defplugin flag-owner \"Takes a greeting.\")\n"
                "(defplugin-options flag-owner (greeting \"" greeting
                "\" \"What to say.\" string-type flag: \"--greeting\"))\n")))
           (try
            (call-with-fresh-kernel []
              (lambda ()
                (write-helper "hello")
                (let* ((path (write-init directory "(import \"./flag-owner\")" "(use-plugin flag-owner)"))
                       (choice (make-config-choice path "--config"))
                       (report (start-from-configuration choice ["--greeting" "forced"])))
                  (set! old (report-entry-subject
                             (find (lambda ((e : report-entry))
                                     (eq? (plugin-name (report-entry-subject e)) 'flag-owner))
                                   (startup-report-entries report))))
                  (write-helper "new default")
                  (let* ((report (reload-configuration!))
                         (entry (find (lambda ((e : report-entry))
                                        (eq? (plugin-name (report-entry-subject e)) 'flag-owner))
                                      (reload-report-entries report)))
                         (new (report-entry-subject entry)))
                    (check (report-entry-status entry) => 'replaced)
                    (check (eq? old new) => #f)
                    (check (plugin-option new 'greeting) => "forced")
                    (check (plugin-option-override new 'greeting) => "--greeting")))))
            (finally
             (when old (remove-plugin-option-override! old 'greeting))))))))

    (test-case "the configuration service: the last report, the summary, and reload"
      (call-with-temporary-directory
       (lambda (directory)
         (call-with-fresh-kernel []
           (lambda ()
             (let* ((path (write-init directory
                                      "(use-plugin good)"
                                      "(use-plugin failing-provider)"
                                      "(use-plugin dependent)"))
                    (report (start path)))
               (check (last-configuration-report) => (startup-report-text report))
               (for-each activate-plugin! [commands keys test-messages reload-config])
               (run-hook configuration-report-ready-hook
                         (make-configuration-report (startup-report-text report) #f
                           (map (lambda ((e : report-entry)) [(report-entry-status e) (report-entry-what e)])
                                (startup-report-entries report)) "/s/startup.log"))
               (check (current-message)
                      => "Tuna start-up: failed: failing-provider; skipped: dependent. The report is in /s/startup.log; show-config-report shows it.")
               (write-init directory "(use-plugin good)")
               (let (text (reload-configuration-report))
                 (check (contains? text "Tuna reload report") ? values)
                 (check (last-configuration-report) => text)))))
         (call-with-fresh-kernel []
           (lambda ()
             (start (write-init directory "(use-plugin good)"))
             (for-each activate-plugin! [commands keys test-messages reload-config])
             (run-hook configuration-report-ready-hook
                       (make-configuration-report "No problems" #f '((on "good")) "/s/startup.log"))
             (check (current-message) => "")
             ;; A reload that finds no file is the last report too.
             (delete-file (path-expand "init.ss" directory))
             (let (report (reload-configuration!))
               (check (contains? (reload-report-problem report) "No configuration at") ? values)
               (check (last-configuration-report) => (reload-report-text report))))))))

    (test-case "reload-config and show-config-report go through the contract"
      (call-with-fresh-kernel [commands keys test-messages stub-configuration reload-config]
        (lambda ()
          (run-command 'show-config-report)
          (check (current-message) => "There is no configuration report yet.")
          (run-command 'reload-config)
          (check (current-message) => "stub reload 1")
          (run-command 'show-config-report)
          (check (current-message) => "stub reload 1")
          (check (configuration-stub-reloads the-stub) => 1))))

    (test-case "reordered options and a written-out default touch nothing"
      (call-with-temporary-directory
       (lambda (directory)
         (call-with-fresh-kernel []
           (lambda ()
             (let ((path (write-init directory "(use-plugin optioned greeting: \"a\" times: 2)"))
                   (before (activation-count 'optioned)))
               (start path)
               (write-init directory "(use-plugin optioned times: 2 greeting: \"a\")")
               (check (changes (reload-configuration!)) => [])
               (write-init directory "(use-plugin optioned times: 2 greeting: \"a\" fail: #f)")
               (check (changes (reload-configuration!)) => [])
               (check (fx- (activation-count 'optioned) before) => 1)))))))

    (test-case "an option change restarts an unchanged config: block with its plugin"
      (call-with-temporary-directory
       (lambda (directory)
         (call-with-fresh-kernel []
           (lambda ()
             (let (path (write-init directory "(use-plugin optioned greeting: \"a\" config: (note-activation! 'optioned-block))"))
               (start path)
               (write-init directory "(use-plugin optioned greeting: \"b\" config: (note-activation! 'optioned-block))")
               (let ((before (activation-count 'optioned-block))
                     (report (reload-configuration!)))
                 (check (changes report)
                        => [["optioned" 'replaced] ["config: block of optioned" 'restarted]])
                 (check (fx- (activation-count 'optioned-block) before) => 1))))))))

    (test-case "a changed user module with a failing option falls back to the running version"
      (call-with-temporary-directory
       (lambda (directory)
         (def (write-mine version)
           (write-file-string
            (path-expand "mine.ss" directory)
            (string-append "(import :tuna/kernel :tuna/lib/plugin-options \"" test-plugins-module "\")\n"
                           "(export mine)\n"
                           "(defplugin mine \"" version "\" optional: [probe-service fixed-service] (when (plugin-option mine 'bad) (error \"told to fail\")) (probe-on! 'mine))\n"
                           "(defplugin-options mine (bad #f \"Fail.\" boolean-type))\n")))
         (def (write-init-mine line)
           (write-file-string
            (path-expand "init.ss" directory)
            (string-append "#lang :tuna/config\n(import :tuna/plugins/commands/contract :tuna/plugins/keys/contract :tuna/plugins/settings/contract)\n(import \"" test-plugins-module "\" \"mine\")\n" line)))
         (write-mine "v1")
         (write-init-mine "(use-plugin mine)")
         (call-with-fresh-kernel []
           (lambda ()
             (start (path-expand "init.ss" directory))
             (check (probe-on? 'mine) => #t)
             (write-mine "v2")
             (write-init-mine "(use-plugin mine bad: #t)")
             (let (report (reload-configuration!))
               ;; The user's code is replaced too, since a user module was read again.
               (check (changes report)
                      => [["mine" 'failed] ["your own code (plugin init)" 'replaced]])
               (check (contains? (reload-report-text report) "the running version is back on") ? values))
             (check (probe-on? 'mine) => #t))))))

    (test-case "declaration problems are collected with option problems, without a banner"
      (call-with-temporary-directory
       (lambda (directory)
         (let* ((path (write-init directory
                                  "(use-plugin optioned greeting: 1)"
                                  "(use-plugin good)"
                                  "(use-plugin good)"
                                  "(use-plugin car)"
                                  "(use-plugin plugin-named-session-owner)"))
                (text (check-configuration (make-config-choice path "--config"))))
           (for-each (lambda (line) (check (contains? text line) ? values))
                     ["init.ss line 3: optioned option greeting must be a string"
                      "init.ss line 5: plugin good is already declared at init.ss line 4"
                      "init.ss line 6: use-plugin needs a plugin, not"
                      "init.ss line 7: the plugin name session-owner is reserved"])
           (check (contains? text "*** ERROR") => #f)))))

    (test-case "an option after config: is a syntax error"
      (call-with-temporary-directory
       (lambda (directory)
         (let (text (check-configuration
                     (make-config-choice
                      (write-init directory "(use-plugin optioned config: (note-activation! 'x) times: 3)")
                      "--config")))
           (check (contains? text "use-plugin options go before config:") ? values)))))

    (test-case "a kernel restart reads the same options"
      (call-with-temporary-directory
       (lambda (directory)
         (call-with-fresh-kernel []
           (lambda ()
             (start (write-init directory
                                "(use-plugin provider)"
                                "(use-plugin optioned-dependent greeting: \"kept\")"))
             (let (before (activation-count 'optioned-dependent))
               (restart-plugin! provider better-provider)
               (check (fx- (activation-count 'optioned-dependent) before) => 1)
               (check (dependent-greeting) => "kept")))))))

    (test-case "an option change of a startup-tier provider waits for the next start"
      (call-with-temporary-directory
       (lambda (directory)
         (call-with-fresh-kernel []
           (lambda ()
             (start (write-init directory "(use-plugin fixed-optioned n: 1)"))
             (activate-plugin! test-input)
             (start-editor-loop!)
             (write-init directory "(use-plugin fixed-optioned n: 2)")
             (let (report (call-on-editor-loop reload-configuration!))
               (check (changes report) => [["fixed-optioned" 'deferred]])
               (check (contains? (reload-report-text report) "so the new options take effect at next start")
                      ? values))
             (check (fixed-n) => 1)
             (check (plugin-option fixed-optioned 'n) => 1))))))

    (test-case "defplugin-options checks defaults; plugin-option needs a declared name"
      (let ()
        (defplugin lone "Declares options.")
        (check-exception (defplugin-options lone (x "text" "A flag." boolean-type)) true)
        (check (plugin-option-specs lone) => [])
        (check-exception (plugin-option good 'colour) true)))))

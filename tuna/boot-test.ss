;;; Starting from init.ss (tuna/boot.ss, tuna/config.ss): finding the
;;; file, loading it without effect, turning plugins on with per-plugin and
;;; per-block isolation, time limits, the start-up report and its log, and
;;; tuna init. Every test writes its init.ss to its own temporary directory
;;; and runs in a fresh kernel.
(import :std/misc/ports
        :std/source
        :std/test
        :tuna/kernel
        :tuna/lib/configuration
        :tuna/boot
        "test-support/kernel"
        "test-support/string-input"
        "test-support/config")
(export boot-test)

(def tuna-directory (path-expand (this-source-directory)))
(def repository-directory
  (path-directory (path-strip-trailing-directory-separator tuna-directory)))
(def test-plugins-module (path-expand "test-support/config" tuna-directory))

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

(def boot-test
  (test-suite "start-up from init.ss"
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
            (check (describe-services) => [])))))

    (test-case "loading has no effect; activation applies plugins, blocks, and code"
      (call-with-temporary-directory
       (lambda (directory)
         (let (path (write-init directory
                                "(use-plugin good-plugin config: (probe-on! 'good-block))"
                                "(probe-on! 'user)"))
           (call-with-fresh-kernel []
             (lambda ()
               (let (loaded (load-configuration path))
                 (check (configuration? loaded) ? values)
                 (check (map (lambda ((d : declaration)) (plugin-name (declaration-target d)))
                             (configuration-declarations loaded))
                        => '(good-plugin))
                 (check (probe-on? 'good) => #f)
                 (check (probe-on? 'good-block) => #f)
                 (check (probe-on? 'user) => #f)
                 (check (plugin-active? good-plugin) => #f)
                 (check (statuses (make-startup-report (make-config-choice path "--config") #f
                                                       (activate-configuration! loaded)))
                        => '(("config-blocks" on) ("good-plugin" on)
                             ("config: block of good-plugin" on)
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
                                "(use-plugin dependent-plugin)"
                                "(use-plugin failing-provider-plugin)"
                                "(use-plugin good-plugin)"))
           (call-with-fresh-kernel []
             (lambda ()
               (let (report (start path))
                 (check (statuses report)
                        => '(("failing-provider-plugin" failed) ("good-plugin" on)
                             ("dependent-plugin" skipped) ("your own code (plugin init)" on)))
                 (check (contains? (detail report "failing-provider-plugin") "fails on purpose") ? values)
                 (check (detail report "dependent-plugin") => "needs probe, which no plugin provides")
                 (check (probe-on? 'failing-provider) => #f)
                 (check (service-provider probe-service) => #f)
                 (check (plugin-active? dependent-plugin) => #f)
                 (check (probe-on? 'good) => #t)
                 (check (contains? (startup-report-text report) "init.ss:3") ? values)
                 (check (contains? (startup-report-text report) "1 skipped") ? values))))))))

    (test-case "a plugin is turned on once a later one provides what it needs"
      (call-with-temporary-directory
       (lambda (directory)
         (let (path (write-init directory
                                "(use-plugin dependent-plugin)"
                                "(use-plugin provider-plugin)"))
           (call-with-fresh-kernel []
             (lambda ()
               (check (statuses (start path))
                      => '(("provider-plugin" on) ("dependent-plugin" on)
                           ("your own code (plugin init)" on)))))))))

    (test-case "a failing config: block is undone alone and follows its plugin"
      (call-with-temporary-directory
       (lambda (directory)
         (let (path (write-init directory
                                "(use-plugin good-plugin config: (probe-on! 'bad-block) (error \"block fails\"))"
                                "(use-plugin provider-plugin config: (probe-on! 'provider-block))"))
           (call-with-fresh-kernel []
             (lambda ()
               (let (report (start path))
                 (check (assoc "config: block of good-plugin" (statuses report))
                        => '("config: block of good-plugin" failed))
                 (check (detail report "config: block of good-plugin") => "block fails")
                 (check (probe-on? 'bad-block) => #f)
                 (check (probe-on? 'good) => #t)
                 (check (probe-on? 'provider-block) => #t)
                 ;; While the loop runs, the block goes and comes with its plugin.
                 (activate-plugin! test-input-plugin)
                 (start-editor-loop!)
                 (call-on-editor-loop (lambda () (deactivate-plugin! provider-plugin)))
                 (check (wait-until (lambda () (not (probe-on? 'provider-block)))) ? values)
                 (call-on-editor-loop (lambda () (activate-plugin! provider-plugin)))
                 (check (wait-until (lambda () (probe-on? 'provider-block))) ? values))))))))

    (test-case "an error in the user's own code undoes only that code"
      (call-with-temporary-directory
       (lambda (directory)
         (let (path (write-init directory
                                "(use-plugin good-plugin)"
                                "(probe-on! 'user)"
                                "(error \"user code fails\")"))
           (call-with-fresh-kernel []
             (lambda ()
               (let (report (start path))
                 (check (statuses report)
                        => '(("good-plugin" on) ("your own code (plugin init)" failed)))
                 (check (detail report "your own code (plugin init)") => "user code fails")
                 (check (probe-on? 'user) => #f)
                 (check (probe-on? 'good) => #t))))))))

    (test-case "a syntax error turns nothing on and reports the line"
      (call-with-temporary-directory
       (lambda (directory)
         (let (path (write-init directory
                                "(use-plugin good-plugin)"
                                "(probe-on! 'user"))
           (call-with-fresh-kernel []
             (lambda ()
               (let (report (start path))
                 (check (startup-report-entries report) => [])
                 (check (contains? (startup-report-problem report)
                                   (string-append path ":4:1: Incomplete form"))
                        ? values)
                 (check (contains? (startup-report-problem report) "Nothing was turned on") ? values)
                 (check (plugin-active? good-plugin) => #f))))))))

    (test-case "unknown names and bad declarations fail the load"
      (call-with-temporary-directory
       (lambda (directory)
         (call-with-fresh-kernel []
           (lambda ()
             (let (problem (load-configuration (write-init directory "(use-plugin no-such-plugin)")))
               (check (contains? problem "Reference to unbound identifier") ? values)
               (check (contains? problem "init.ss\"@3.13") ? values))
             (check (contains? (load-configuration (write-init directory "(use-plugin 42)"))
                               "use-plugin needs a plugin")
                    ? values)
             (check (contains? (load-configuration (write-init directory
                                                               "(use-plugin good-plugin)"
                                                               "(use-plugin good-plugin)"))
                               "already declared at")
                    ? values)
             (check (contains? (load-configuration (write-init directory "(use-plugin plugin-named-init)"))
                               "reserved")
                    ? values)
             ;; Not at the top level, use-plugin is the user's own code,
             ;; where it fails when that code runs.
             (let (report (start (write-init directory "(when #t (use-plugin good-plugin))")))
               (check (contains? (detail report "your own code (plugin init)") "only at the top level")
                      ? values)
               (check (plugin-active? good-plugin) => #f)))))))

    (test-case "a load that loops is stopped and reported"
      (call-with-temporary-directory
       (lambda (directory)
         (let (path (write-init directory
                                "(use-plugin (let spin ((n 0)) (spin (if (fx< n 1000) (fx1+ n) 0))))"))
           (call-with-fresh-kernel []
             (lambda ()
               (parameterize ((load-time-limit 0.5))
                 (let (report (start path))
                   (check (startup-report-entries report) => [])
                   (check (contains? (startup-report-problem report) "did not finish within") ? values)))
               ;; The file is reloaded, not left stuck: fixed, it loads.
               (write-init directory "(use-plugin good-plugin)")
               (check (statuses (start path))
                      => '(("good-plugin" on) ("your own code (plugin init)" on)))))))))

    (test-case "an activation that hangs is stopped and rolled back; the rest come up"
      (call-with-temporary-directory
       (lambda (directory)
         (let (path (write-init directory
                                "(use-plugin hanging-plugin)"
                                "(use-plugin good-plugin)"))
           (call-with-fresh-kernel []
             (lambda ()
               (parameterize ((activation-time-limit 0.5))
                 (let (report (start path))
                   (check (statuses report)
                          => '(("hanging-plugin" failed) ("good-plugin" on)
                               ("your own code (plugin init)" on)))
                   (check (contains? (detail report "hanging-plugin") "rolled back") ? values)
                   (check (probe-on? 'hanging) => #f)
                   (check (plugin-active? hanging-plugin) => #f)))))))))

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
                   => '(keys-plugin web-transport-plugin settings-plugin echo-area-plugin
                        help-panel-plugin session-plugin rope-text-store-plugin buffers-plugin
                        autosave-plugin single-window-plugin window-commands-plugin
                        html-renderer-plugin basic-editing-plugin minibuffer-plugin demo-plugin))
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

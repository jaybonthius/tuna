;;; Plugin options in init.ss (tuna/lib/plugin-options.ss) and the
;;; configuration service with its report (tuna/services/configuration.ss):
;;; options are checked at load with every problem and its line, a load
;;; with a bad option changes nothing, options reach the plugin, and a
;;; changed option replaces the plugin with the running version as the
;;; fallback. Every test writes its files to its own temporary directory
;;; and runs in a fresh kernel.
(import :std/io
        :std/misc/ports
        :std/net/address
        :std/source
        :std/test
        :tuna/kernel
        :tuna/boot
        :tuna/lib/plugin-options
        :tuna/services/configuration
        :tuna/plugins/web
        "test-support/kernel"
        "test-support/config")
(export options-test)

(def test-plugins-module
  (path-expand "test-support/config" (path-expand (this-source-directory))))

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

;; A loopback port nothing listens on now.
(def (free-port) => :fixnum
  (using (socket (tcp-listen (string->address "inet4:127.0.0.1:0")) : ServerSocket)
    (let (address (socket.address))
      (socket.close)
      (:- (InetAddress-port address) :fixnum))))

(def options-test
  (test-suite "plugin options and the configuration report"
    (test-case "every option problem is reported with its line, and the load changes nothing"
      (call-with-temporary-directory
       (lambda (directory)
         (call-with-fresh-kernel []
           (lambda ()
             (let ((path (write-init directory "(use-plugin optioned-plugin greeting: \"hi\")"))
                   (before (activation-count 'optioned-plugin)))
               (start path)
               (check (last-greeting) => "hi")
               (write-init directory
                           "(use-plugin optioned-plugin greeting: hi times: 11"
                           "  greting: \"x\" times: 2)"
                           "(use-plugin good-plugin colour: \"red\")")
               (let* ((expected ["init.ss line 3: optioned-plugin option greeting must be a string"
                                 "init.ss line 3: optioned-plugin option times must be a whole number from 1 to 10"
                                 "init.ss line 4: optioned-plugin has no option greting; its options are greeting, times, fail"
                                 "init.ss line 4: optioned-plugin option times is given twice"
                                 "init.ss line 5: good-plugin has no option colour; it takes no options"])
                      (checked (check-configuration (make-config-choice path "--config")))
                      (report (reload-configuration!)))
                 (for-each (lambda (line)
                             (check (contains? checked line) ? values)
                             (check (contains? (reload-report-text report) line) ? values))
                           expected)
                 (check (contains? (reload-report-text report) "Nothing was changed.") ? values)
                 (check (contains? (reload-report-text report) "*** ERROR") => #f)
                 (check (changes report) => [])
                 (check (fx- (activation-count 'optioned-plugin) before) => 1)
                 (check (last-greeting) => "hi")
                 (check (probe-on? 'good) => #f)
                 (check (probe-on? 'optioned) => #t))))))))

    (test-case "options are data: quoted values and defaults"
      (call-with-temporary-directory
       (lambda (directory)
         (call-with-fresh-kernel []
           (lambda ()
             (let (path (write-init directory "(use-plugin optioned-plugin times: 3)"))
               (check (check-configuration (make-config-choice path "--config")) => #f)
               (start path)
               (check (plugin-option optioned-plugin 'times) => 3)
               (check (last-greeting) => "hello")
               (write-init directory "(use-plugin optioned-plugin greeting: 'hi)")
               (check (contains? (check-configuration (make-config-choice path "--config"))
                                 "init.ss line 3: optioned-plugin option greeting must be a string")
                      ? values)))))))

    (test-case "a changed option replaces the plugin; a failing new value keeps the running one"
      (call-with-temporary-directory
       (lambda (directory)
         (call-with-fresh-kernel []
           (lambda ()
             (let ((path (write-init directory "(use-plugin optioned-plugin greeting: \"hi\")"))
                   (before (activation-count 'optioned-plugin)))
               (start path)
               (write-init directory "(use-plugin optioned-plugin greeting: \"there\")")
               (let (report (reload-configuration!))
                 (check (changes report) => [["optioned-plugin" 'replaced]])
                 (check (last-greeting) => "there"))
               (write-init directory "(use-plugin optioned-plugin greeting: \"x\" fail: #t)")
               (let (report (reload-configuration!))
                 (check (changes report) => [["optioned-plugin" 'failed]])
                 (check (contains? (reload-report-text report) "the running version is back on") ? values)
                 (check (last-greeting) => "there")
                 (check (plugin-option optioned-plugin 'fail) => #f)
                 (check (probe-on? 'optioned) => #t))
               (write-init directory "(use-plugin optioned-plugin greeting: \"there\")")
               (check (changes (reload-configuration!)) => [])
               (write-init directory "(use-plugin optioned-plugin)")
               (check (changes (reload-configuration!)) => [["optioned-plugin" 'replaced]])
               (check (last-greeting) => "hello")
               ;; Start, replace, the failing value, the running one back, defaults.
               (check (fx- (activation-count 'optioned-plugin) before) => 5)))))))

    (test-case "the web transport's port option, and --port beats it"
      (let ((option-port (free-port))
            (flag-port (free-port)))
        (try
         (set-plugin-options! web-transport-plugin [(cons 'port option-port)])
         (call-with-fresh-kernel [web-transport-plugin]
           (lambda ()
             (check (contains? (web-transport-url)
                               (string-append "127.0.0.1:" (number->string option-port) "/"))
                    ? values)))
         (parameterize ((web-transport-listen-port flag-port))
           (call-with-fresh-kernel [web-transport-plugin]
             (lambda ()
               (check (contains? (web-transport-url)
                                 (string-append "127.0.0.1:" (number->string flag-port) "/"))
                      ? values))))
         (finally
          (set-plugin-options! web-transport-plugin [])))))

    (test-case "the configuration service: the last report, the summary, and reload"
      (call-with-temporary-directory
       (lambda (directory)
         (call-with-fresh-kernel []
           (lambda ()
             (let* ((path (write-init directory
                                      "(use-plugin good-plugin)"
                                      "(use-plugin failing-provider-plugin)"
                                      "(use-plugin dependent-plugin)"))
                    (report (start path)))
               (check (last-configuration-report) => (startup-report-text report))
               (check (startup-report-summary report)
                      => "Tuna start-up: failed: failing-provider-plugin; skipped: dependent-plugin. show-config-report shows the report.")
               (write-init directory "(use-plugin good-plugin)")
               (let (text (reload-configuration-report))
                 (check (contains? text "Tuna reload report") ? values)
                 (check (last-configuration-report) => text)))))
         (call-with-fresh-kernel []
           (lambda ()
             (check (startup-report-summary (start (write-init directory "(use-plugin good-plugin)")))
                    => #f))))))))

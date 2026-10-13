;;; Reloading init.ss (tuna/boot.ss) and `tuna reload` (tuna/control.ss):
;;; only what changed is touched; a failing new version leaves the running
;;; one on; a failed load changes nothing; startup-tier changes wait for
;;; the next start. Every test writes its files to its own temporary
;;; directory and runs in a fresh kernel.
(import :std/misc/ports
        :std/source
        :std/test
        :tuna/kernel
        :tuna/boot
        :tuna/control
        "test-support/kernel"
        "test-support/string-input"
        "test-support/config")
(export reload-test)

(def test-plugins-module
  (path-expand "test-support/config" (path-expand (this-source-directory))))

(def (call-with-temporary-directory proc)
  (let (directory (path-expand (string-append "tuna-reload-test-"
                                              (number->string (random-integer 1000000000)))
                               (getenv "TMPDIR" "/tmp")))
    (create-directory* directory)
    (try
     (proc directory)
     (finally
      (delete-file-or-directory directory #t)))))

;; Write DIRECTORY/init.ss: the language line, an import of the test
;; plugins and of DIRECTORY/mine.ss when it exists, then LINES.
(def (write-init (directory : :string) . lines) => :string
  (let (path (path-expand "init.ss" directory))
    (write-file-string
     path
     (string-join (append ["#lang :tuna/config"
                           (string-append "(import \"" test-plugins-module "\""
                                          (if (file-exists? (path-expand "mine.ss" directory))
                                            " \"mine\""
                                            "")
                                          ")")]
                          lines)
                  "\n"))
    path))

;; Write DIRECTORY/mine.ss, a user module defining mine-plugin with BODY.
(def (write-mine (directory : :string) (body : :string)) => :void
  (write-file-string
   (path-expand "mine.ss" directory)
   (string-append "(import :tuna/kernel \"" test-plugins-module "\")\n"
                  "(export mine-plugin)\n"
                  "(defplugin mine-plugin \"The user's own plugin.\" " body ")\n")))

(def (start (path : :string)) => startup-report
  (start-from-configuration (make-config-choice path "--config")))

;; The report's entries as (what status).
(def (statuses (entries : :list)) => :list
  (map (lambda ((e : report-entry)) [(report-entry-what e) (report-entry-status e)]) entries))

(def (reload) => reload-report
  (reload-configuration!))

(def (changes (report : reload-report)) => :list
  (statuses (reload-report-entries report)))

(def (detail (report : reload-report) (what : :string)) => :string
  (report-entry-detail
   (find (lambda ((e : report-entry)) (equal? (report-entry-what e) what))
         (reload-report-entries report))))

(def (contains? (text : :string) (part : :string)) => :boolean
  (and (string-contains text part) #t))

(def user-code "your own code (plugin init)")

(def reload-test
  (test-suite "reloading init.ss"
    (test-case "a reload with no changes touches nothing, twice in a row"
      (call-with-temporary-directory
       (lambda (directory)
         (let (path (write-init directory
                                "(use-plugin counted-plugin config: (note-activation! 'counted-block))"
                                "(note-activation! 'user)"))
           (call-with-fresh-kernel []
             (lambda ()
               (start path)
               (check (activation-count 'counted-plugin) => 1)
               (for-each
                (lambda (_)
                  (let (report (reload))
                    (check (changes report) => [])
                    (check (reload-report-unchanged report) => 3)
                    (check (reload-succeeded? report) => #t)
                    (check (contains? (reload-report-text report) "3 unchanged") ? values)))
                [1 2])
               (check (activation-count 'counted-plugin) => 1)
               (check (activation-count 'counted-block) => 1)
               (check (activation-count 'user) => 1)
               (check (probe-on? 'counted) => #t)))))))

    (test-case "added plugins are turned on and removed ones off"
      (call-with-temporary-directory
       (lambda (directory)
         (let (path (write-init directory "(use-plugin good-plugin)"))
           (call-with-fresh-kernel []
             (lambda ()
               (start path)
               (write-init directory "(use-plugin dependent-plugin)" "(use-plugin provider-plugin)")
               (let (report (reload))
                 (check (changes report)
                        => '(("good-plugin" off) ("provider-plugin" on) ("dependent-plugin" on)))
                 (check (detail report "good-plugin") => "no longer declared")
                 (check (reload-report-unchanged report) => 1))
               (check (probe-on? 'good) => #f)
               (check (probe-on? 'provider) => #t)
               (check (probe-on? 'dependent) => #t)))))))

    (test-case "a changed config: block is replaced; its plugin is left alone"
      (call-with-temporary-directory
       (lambda (directory)
         (let (path (write-init directory "(use-plugin counted-plugin config: (probe-on! 'block-1))"))
           (call-with-fresh-kernel []
             (lambda ()
               (start path)
               (let (activations (activation-count 'counted-plugin))
                 (write-init directory "(use-plugin counted-plugin config: (probe-on! 'block-2))")
                 (check (changes (reload)) => '(("config: block of counted-plugin" replaced)))
                 (check (activation-count 'counted-plugin) => activations))
               (check (probe-on? 'block-1) => #f)
               (check (probe-on? 'block-2) => #t)
               ;; A block that now fails is undone and the running one is
               ;; turned back on.
               (write-init directory "(use-plugin counted-plugin config: (probe-on! 'block-3) (error \"block 3 fails\"))")
               (let (report (reload))
                 (check (changes report) => '(("config: block of counted-plugin" failed)))
                 (check (detail report "config: block of counted-plugin")
                        => "block 3 fails; the running version is back on"))
               (check (probe-on? 'block-3) => #f)
               (check (probe-on? 'block-2) => #t)
               ;; Removing the block turns it off.
               (write-init directory "(use-plugin counted-plugin)")
               (check (changes (reload)) => '(("config: block of counted-plugin" off)))
               (check (probe-on? 'block-2) => #f)
               (check (probe-on? 'counted) => #t)))))))

    (test-case "a changed user module replaces its plugin; a failing new version keeps the old"
      (call-with-temporary-directory
       (lambda (directory)
         (write-mine directory "(probe-on! 'mine-1)")
         (let (path (write-init directory "(use-plugin mine-plugin)" "(use-plugin good-plugin)"))
           (call-with-fresh-kernel []
             (lambda ()
               (start path)
               (write-mine directory "(probe-on! 'mine-2)")
               (let (report (reload))
                 ;; The user's code is replaced too: it may use the module.
                 (check (changes report) => [["mine-plugin" 'replaced] [user-code 'replaced]]))
               (check (probe-on? 'mine-1) => #f)
               (check (probe-on? 'mine-2) => #t)
               (write-mine directory "(probe-on! 'mine-3) (error \"mine 3 fails\")")
               (let (report (reload))
                 (check (assoc "mine-plugin" (changes report)) => '("mine-plugin" failed))
                 (check (detail report "mine-plugin") => "mine 3 fails; the running version is back on")
                 (check (reload-succeeded? report) => #f))
               (check (probe-on? 'mine-3) => #f)
               (check (probe-on? 'mine-2) => #t)
               (check (probe-on? 'good) => #t)))))))

    (test-case "failing new user code keeps the running user code"
      (call-with-temporary-directory
       (lambda (directory)
         (let (path (write-init directory "(use-plugin good-plugin)" "(probe-on! 'user-1)"))
           (call-with-fresh-kernel []
             (lambda ()
               (start path)
               (write-init directory "(use-plugin good-plugin)" "(probe-on! 'user-2)" "(error \"user 2 fails\")")
               (let (report (reload))
                 (check (changes report) => [[user-code 'failed]])
                 (check (detail report user-code) => "user 2 fails; the running version is back on"))
               (check (probe-on? 'user-1) => #t)
               (check (probe-on? 'user-2) => #f)
               ;; Fixed, it replaces the running code.
               (write-init directory "(use-plugin good-plugin)" "(probe-on! 'user-3)")
               (check (changes (reload)) => [[user-code 'replaced]])
               (check (probe-on? 'user-1) => #f)
               (check (probe-on? 'user-3) => #t)))))))

    (test-case "a file that does not load changes nothing"
      (call-with-temporary-directory
       (lambda (directory)
         (let (path (write-init directory "(use-plugin good-plugin)" "(probe-on! 'user)"))
           (call-with-fresh-kernel []
             (lambda ()
               (start path)
               (write-init directory "(use-plugin provider-plugin)" "(probe-on! 'user")
               (let (report (reload))
                 (check (reload-report-entries report) => [])
                 (check (contains? (reload-report-problem report) (string-append path ":4:1: Incomplete form"))
                        ? values)
                 (check (contains? (reload-report-text report) "Nothing was changed.") ? values)
                 (check (reload-succeeded? report) => #f))
               (write-init directory "(use-plugin no-such-plugin)")
               (check (contains? (reload-report-problem (reload)) "init.ss:3:13: Reference to unbound identifier")
                      ? values)
               (check (probe-on? 'good) => #t)
               (check (probe-on? 'user) => #t)
               (check (plugin-active? provider-plugin) => #f)))))))

    (test-case "startup-tier changes wait for the next start while the editor loop runs"
      (call-with-temporary-directory
       (lambda (directory)
         (let (path (write-init directory "(use-plugin fixed-provider-plugin)"))
           (call-with-fresh-kernel []
             (lambda ()
               (start path)
               (activate-plugin! test-input-plugin)
               (start-editor-loop!)
               ;; Removing its provider is deferred.
               (write-init directory "")
               (let (report (call-on-editor-loop reload))
                 (check (changes report) => '(("fixed-provider-plugin" deferred)))
                 (check (detail report "fixed-provider-plugin")
                        => "provides the startup-tier service fixed, so turning it off takes effect at next start"))
               (check (probe-on? 'fixed) => #t)
               ;; A plugin that would take it over is refused and rolled back.
               (write-init directory "(use-plugin fixed-provider-plugin)" "(use-plugin better-fixed-provider-plugin)")
               (let (report (call-on-editor-loop reload))
                 (check (changes report) => '(("better-fixed-provider-plugin" deferred)))
                 (check (detail report "better-fixed-provider-plugin")
                        => "would take over the startup-tier service fixed, so it takes effect at next start"))
               (check (probe-on? 'better-fixed) => #f)
               (check (probe-on? 'fixed) => #t)))))))

    (test-case "a plugin that failed at start-up comes up once fixed, with what needs it"
      (call-with-temporary-directory
       (lambda (directory)
         (write-mine directory "(context-provide! (current-context) probe-service 'probe) (error \"broken\")")
         (let (path (write-init directory "(use-plugin mine-plugin)" "(use-plugin dependent-plugin)"))
           (call-with-fresh-kernel []
             (lambda ()
               (check (statuses (startup-report-entries (start path)))
                      => [["mine-plugin" 'failed] ["dependent-plugin" 'skipped] [user-code 'on]])
               (write-mine directory "(context-provide! (current-context) probe-service 'probe)")
               (let (report (reload))
                 (check (assoc "mine-plugin" (changes report)) => '("mine-plugin" on))
                 (check (assoc "dependent-plugin" (changes report)) => '("dependent-plugin" on)))
               (check (probe-on? 'dependent) => #t)))))))

    (test-case "a start-up that loaded nothing is fixed by a reload"
      (call-with-temporary-directory
       (lambda (directory)
         (let (path (write-init directory "(use-plugin good-plugin"))
           (call-with-fresh-kernel []
             (lambda ()
               (check (startup-report-entries (start path)) => [])
               (write-init directory "(use-plugin good-plugin)")
               (check (changes (reload)) => [["good-plugin" 'on] [user-code 'on]])
               (check (probe-on? 'good) => #t)))))))

    (test-case "tuna reload asks the running Tuna and prints its report"
      (call-with-temporary-directory
       (lambda (directory)
         (let ((path (write-init directory "(use-plugin good-plugin)"))
               (saved (getenv "XDG_RUNTIME_DIR" #f)))
           (setenv "XDG_RUNTIME_DIR" directory)
           (try
            (call-with-fresh-kernel []
              (lambda ()
                (start path)
                (activate-plugin! test-input-plugin)
                (start-editor-loop!)
                ;; Nothing listens yet; a stale socket file is deleted.
                (create-directory* (control-directory))
                (write-file-string (path-expand "999999999.sock" (control-directory)) "")
                (let (output (open-output-string))
                  (check (request-reloads output) => 1)
                  (check (get-output-string output) => "No running Tuna was found, so nothing was reloaded.\n"))
                (check (file-exists? (path-expand "999999999.sock" (control-directory))) => #f)
                (let (server (start-control-server!
                              (lambda ()
                                (call-on-editor-loop
                                 (lambda ()
                                   (let (report (reload-configuration!))
                                     (cons (reload-succeeded? report) (reload-report-text report))))))))
                  (try
                   (check (file-exists? (control-server-path server)) => #t)
                   (write-init directory "(use-plugin provider-plugin)")
                   (let* ((output (open-output-string))
                          (status (request-reloads output))
                          (text (get-output-string output)))
                     (check status => 0)
                     (check (contains? text "Tuna reload report") ? values)
                     (check (contains? text "  on       provider-plugin (init.ss:3)") ? values)
                     (check (contains? text "  off      good-plugin (init.ss:3): no longer declared") ? values))
                   (check (probe-on? 'provider) => #t)
                   (check (probe-on? 'good) => #f)
                   ;; A failed load is reported, with a failing exit status.
                   (write-init directory "(use-plugin provider-plugin")
                   (let* ((output (open-output-string))
                          (status (request-reloads output)))
                     (check status => 1)
                     (check (contains? (get-output-string output) "Nothing was changed.") ? values))
                   (finally
                    (stop-control-server! server void)))
                  (check (file-exists? (control-server-path server)) => #f))))
            (finally
             (if saved (setenv "XDG_RUNTIME_DIR" saved) (setenv "XDG_RUNTIME_DIR"))))))))))

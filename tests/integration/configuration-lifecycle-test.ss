;;; Generic configuration lifecycle: owner-bound callbacks and a single
;;; reversible restart participant, with no editor state in the program.
prelude: :gerbil/core
(import :std/error
        :std/misc/ports
        :std/test
        :tuna/kernel
        :tuna/boot
        :tuna/configuration
        "../../tuna/tests/support/kernel")
(export configuration-lifecycle-test)

(def configuration-lifecycle-test
  (test-suite "tuna/integration/configuration-lifecycle"
    (test-case "restart registration is owner-bound, exclusive and receipt-owned"
      (call-with-fresh-kernel [session-owner]
        (lambda ()
          (let ((probe (new-service 'lifecycle-probe symbol? tier: 'live doc: "Lifecycle ownership probe."))
                (events [])
                (fail-capture? #f)
                (owners-seen []))
            (def (record! (event : :symbol)) => :void
              (set! events (append events [event])))
            (defplugin (probe-provider ctx) "A service only the participant declares."
              provides: [probe]
              (context-provide! ctx probe 'probe))
            (defplugin (participant ctx) "Joins a restart."
              requires: [configuration-service probe]
              (context-set-restart-wrapper! ctx
                (lambda (owners apply rollback)
                  (check (service-provider probe) => 'probe)
                  (set! owners-seen owners)
                  (record! 'capture)
                  (when fail-capture? (error "capture failed"))
                  (with-catch
                    (lambda (e) (rollback) (record! 'rollback-restore) (raise e))
                    (lambda () (apply) (record! 'restore))))))
            (defplugin (second-participant ctx) "Must not replace another participant."
              requires: [configuration-service]
              (context-set-restart-wrapper! ctx
                (lambda (owners apply rollback) (apply))))
            (activate-plugin! probe-provider)
            (activate-plugin! participant)
            (call-with-configuration-restart '(first dependent)
              (lambda () (record! 'apply)) (lambda () (record! 'rollback)))
            (check owners-seen => '(first dependent))
            (check events => '(capture apply restore))
            (set! events [])
            (set! fail-capture? #t)
            (check-exception
              (call-with-configuration-restart '(first)
                (lambda () (record! 'apply)) (lambda () (record! 'rollback))) Error?)
            (check events => '(capture))
            (set! events [])
            (set! fail-capture? #f)
            (check-exception
              (call-with-configuration-restart '(first)
                (lambda () (record! 'apply) (error "apply failed"))
                (lambda () (record! 'rollback))) Error?)
            (check events => '(capture apply rollback rollback-restore))
            (let (failure (with-catch values
                            (lambda () (activate-plugin! second-participant) #f)))
              (check (Error? failure) => #t)
              (check (Error-irritants failure) => '(participant second-participant)))
            ;; A rejected registration did not remove the original one.
            (set! events [])
            (call-with-configuration-restart [] void void)
            (check events => '(capture restore))
            (deactivate-plugin! participant)
            (activate-plugin! second-participant)
            (deactivate-plugin! second-participant)
            (call-with-configuration-restart [] (lambda () (record! 'unwrapped)) void)
            (check events => '(capture restore unwrapped))))))
    (test-case "startup notification follows all activation; shutdown precedes receipts"
      (let* ((directory (path-expand (string-append "tuna-lifecycle-" (number->string (random-integer 1000000000)))
                                     (getenv "TMPDIR" "/tmp")))
             (path (path-expand "init.ss" directory))
             (fixture (path-expand "fixture.ss" directory)))
        (create-directory directory)
        (unwind-protect
          (begin
            (write-file-string fixture
              "(import :tuna/kernel :tuna/configuration)\n(export watcher late events)\n(def events [])\n(defplugin (watcher ctx) \"Watch lifecycle.\"\n (context-add-hook! ctx configuration-started-hook 'started\n  (lambda () (set! events (cons (list 'started (plugin-active? late)) events))))\n (context-add-hook! ctx configuration-stopping-hook 'stopping\n  (lambda () (set! events (cons (list 'stopping (plugin-active? late)) events))))\n (context-defer! ctx (lambda () (set! events (cons 'receipt events)))))\n(defplugin late \"Starts after the observer.\")\n")
            (write-file-string path
              "#lang :tuna/config\n(import \"fixture\")\n(use-plugin watcher)\n(use-plugin late)\n")
            (call-with-fresh-kernel []
              (lambda ()
                (let (report (start-from-configuration (make-config-choice path "--config")))
                  (check (startup-report-problem report) => #f)
                  (check (map report-entry-status (startup-report-entries report)) => '(on on on)))
                (check (evaluate-form 'events) => '((started #t)))
                (run-hook configuration-stopping-hook)
                (check (evaluate-form 'events) => '((stopping #t) (started #t)))
                (deactivate-plugin! (evaluate-form 'watcher))
                (check (evaluate-form 'events) => '(receipt (stopping #t) (started #t)))
                (run-hook configuration-stopping-hook)
                (check (evaluate-form 'events) => '(receipt (stopping #t) (started #t))))))
          (delete-file-or-directory directory #t))))))

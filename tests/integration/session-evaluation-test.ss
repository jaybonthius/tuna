;;; Interactive forms accumulate under the start-up owner, not under init
;;; or the plugin asking to evaluate them. Reload remains a separate path.
prelude: :gerbil/core

(import :std/error
        :std/misc/ports
        :std/test
        :tuna/kernel
        :tuna/boot
        (except-in :tuna/configuration activate-plugin!)
        :tuna/plugins/commands/contract
        :tuna/plugins/keys/contract
        "../../tuna/tests/support/kernel")
(export session-evaluation-test)

(def (write-evaluation-init (path : :string) (body : :string)) => :void
  (write-file-string path
    (string-append "#lang :tuna/config\n"
      "(import :tuna/plugins/commands/contract :tuna/plugins/keys/contract :tuna/plugins/commands/plugin :tuna/plugins/keys/plugin)\n"
      "(use-plugin commands)\n(use-plugin keys)\n" body "\n")))

(def (call-with-evaluation-session (thunk : :procedure)) => :t
  (let* ((directory (path-expand (string-append "tuna-evaluation-test-"
                                  (number->string (random-integer 1000000000)))
                                (getenv "TMPDIR" "/tmp")))
         (path (path-expand "init.ss" directory)))
    (create-directory* directory)
    (try
     (write-evaluation-init path "(keymap-set \"C-c x\" 'from-init)")
     (call-with-fresh-kernel []
       (lambda ()
         (let (report (start-from-configuration (make-config-choice path "--config")))
           (check (startup-report-problem report) => #f)
           (check (map report-entry-status (startup-report-entries report)) => '(on on on)))
         (thunk path)))
     (finally (delete-file-or-directory directory #t)))))

(def (binding-value (keys : :string)) => (Maybe :symbol)
  (let (binding (key-binding keys)) (and binding (entry-value binding))))

(def session-evaluation-test
  (test-suite "tuna/integration/session-evaluation"
    (test-case "evaluation inherits resolved relative and renamed init imports"
      (call-with-evaluation-session
        (lambda ((path : :string))
          (let (helper (path-expand "helper.ss" (path-directory path)))
            (write-file-string helper "(export answer hidden)\n(def answer 42)\n(def hidden 9)\n")
            (write-file-string path
              "#lang :tuna/config\n(import (rename-in (only-in \"helper\" answer) (answer imported-answer)))\n")
            ;; A new start, not reload, seeds a new evaluation environment.
            (deactivate-all-plugins!)
            (start-from-configuration (make-config-choice path "--config"))
            (check (evaluate-form 'imported-answer) => 42)
            (check-exception (evaluate-form 'hidden) unbound-global-exception?)
            (check-exception (evaluate-form '(keymap-set "C-c x" 'not-imported))
                             unbound-global-exception?)))))
    (test-case "reload updates imports while keeping evaluated definitions and imports"
      (call-with-evaluation-session
       (lambda ((path : :string))
         (evaluate-forms '((import :std/misc/ports)
                          (def evaluation-answer 17)))
         (let (helper (path-expand "reload-helper.ss" (path-directory path)))
           (write-file-string helper "(export answer)\n(def answer 42)\n")
           (write-evaluation-init path
             "(import (rename-in (only-in \"reload-helper\" answer) (answer reload-answer)))")
           (check (reload-succeeded? (reload-configuration!)) => #t)
           (check (evaluate-form 'reload-answer) => 42)
           (check (evaluate-form 'evaluation-answer) => 17)
           (check (evaluate-form '(procedure? read-file-string)) => #t)
           (write-file-string path "#lang :tuna/config\n(")
           (check (reload-succeeded? (reload-configuration!)) => #f)
           (check (evaluate-form 'reload-answer) => 42)))))
    (test-case "evaluation wins configuration ties and survives changed and failed reloads"
      (call-with-evaluation-session
       (lambda ((path : :string))
         (let (owner (service-provider configuration-service))
           (evaluate-form '(keymap-set "C-c x" 'from-evaluation))
           (check (binding-value "C-c x") => 'from-evaluation)
           (check (entry-owner (key-binding "C-c x")) => 'session-owner)
           (write-evaluation-init path "(keymap-set \"C-c x\" 'changed-init)")
           (check (reload-succeeded? (reload-configuration!)) => #t)
           (check (binding-value "C-c x") => 'from-evaluation)
           (write-file-string path "#lang :tuna/config\n(")
           (check (reload-succeeded? (reload-configuration!)) => #f)
           (check (binding-value "C-c x") => 'from-evaluation)
           (check (service-provider configuration-service) ? (cut eq? <> owner))
           (check (plugin-active? session-owner) => #t)))))

    (test-case "unchanged forms replace keys commands and named hooks without duplicates"
      (call-with-evaluation-session
       (lambda ((path : :string))
         (evaluate-forms '((import :tuna/kernel :tuna/plugins/keys/contract)
                          (def evaluation-map (new-keymap))
                          (def evaluation-hook (new-hook 'evaluation))
                          (def evaluation-count 0)))
         (let (forms '((defcommand (evaluated-command) "An evaluated command." 'first)
                       (keymap-set "C-c x" 'evaluated-command)
                       (keymap-set-in evaluation-map "C-c x" 'evaluated-command)
                       (def (evaluation-callback) (set! evaluation-count (+ evaluation-count 1)))
                       (context-add-hook! (current-context) evaluation-hook 'callback evaluation-callback)))
           (evaluate-forms forms)
           (evaluate-forms forms)
           (check (evaluate-form '(length (entry-table-entries evaluation-map "C-c x"))) => 1)
           (check (length (filter (cut eq? <> 'evaluated-command) (command-names))) => 1)
           (check (entry-owner (command-entry 'evaluated-command)) => 'session-owner)
           (evaluate-form '(run-hook evaluation-hook))
           (check (evaluate-form 'evaluation-count) => 1)
           (evaluate-form '(defcommand (evaluated-command) "Replacement." 'second))
           (check ((command-procedure (command-ref 'evaluated-command))) => 'second))
         (evaluate-form '(keymap-set "C-c y" 'evaluated-command))
         (check (binding-value "C-c x") => 'evaluated-command)
         (check (binding-value "C-c y") => 'evaluated-command))))

    (test-case "a named hook observes a redefinition without registering again"
      (call-with-evaluation-session
       (lambda ((path : :string))
         (evaluate-forms '((import :tuna/kernel)
                          (def evaluation-hook (new-hook 'late-evaluation))
                          (def evaluation-count 0)
                          (def (evaluation-callback) (set! evaluation-count 1))
                          (context-add-hook! (current-context) evaluation-hook 'callback evaluation-callback)))
         (evaluate-form '(run-hook evaluation-hook))
         (check (evaluate-form 'evaluation-count) => 1)
         (evaluate-form '(def (evaluation-callback) (set! evaluation-count 2)))
         (evaluate-form '(run-hook evaluation-hook))
         (check (evaluate-form 'evaluation-count) => 2))))

    (test-case "an evaluation error stops later forms but preserves earlier effects"
      (call-with-evaluation-session
       (lambda ((path : :string))
         (let (failure (with-catch values
                         (lambda ()
                           (evaluate-forms '((keymap-set "C-c e" 'before-error)
                                             (error "Evaluation failed")
                                             (keymap-set "C-c z" 'after-error)))
                           #f)))
           (check (Error? failure) => #t)
           (check (Error-message failure) => "Evaluation failed"))
         (check (binding-value "C-c e") => 'before-error)
         (check (binding-value "C-c z") => #f)
         (check (evaluate-form '(+ 20 22)) => 42)
         (check (void? (evaluate-forms [])) => #t))))

    (test-case "a declared evaluator client lends no checks or ownership to user code"
      (call-with-evaluation-session
       (lambda ((path : :string))
         (defplugin evaluation-client "Uses only the configuration contract."
           requires: [configuration-service]
           (evaluate-form '(keymap-set "C-c p" 'from-client)))
         (activate-plugin! evaluation-client)
         (deactivate-plugin! evaluation-client)
         (check (binding-value "C-c p") => 'from-client)
         (check (entry-owner (key-binding "C-c p")) => 'session-owner)
         (evaluate-forms '((import :tuna/kernel)
                          (def evaluation-service
                            (new-service 'evaluated (lambda (_) #t)
                                         tier: 'live doc: "Evaluated provider."))
                          (context-provide! (current-context) evaluation-service 'live)))
         (check (evaluate-form '(service-provider evaluation-service)) => 'live)
         (check (service-info-provider
                 (find (lambda ((info : service-info)) (eq? (service-info-name info) 'evaluated))
                       (describe-services))) => 'session-owner)
         (check (reload-succeeded? (reload-configuration!)) => #t)
         (check (evaluate-form '(service-provider evaluation-service)) => 'live))))))

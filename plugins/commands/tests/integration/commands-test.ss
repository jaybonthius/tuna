;;; Registry behavior without a Keys provider; package macros use Commands.
prelude: :gerbil/core
(import :std/test :std/error :tuna/kernel :tuna/plugins/commands/contract
        (only-in :tuna/prelude advise! advice-for advised-targets
                 advice-target-info-advice advice-info-name)
        :tuna/plugins/commands/plugin "../../../../tuna/tests/support/kernel" "../support/toy-commands")
(export commands-test)

(defplugin (actions ctx)
  "Two named actions, one not offered to a picker."
  requires: [commands-service]
  (defcommand (visible-action) "A documented action." (this-command))
  (context-define-command! ctx 'hidden-action (lambda () 'hidden)
                           visible?: (lambda (c origin) #f))
  (defcommand (wrapper-action) "Run the visible action by name."
    (call-command 'visible-action)
    (last-command)))

(def commands-test
  (test-suite "tuna/plugins/commands"
    (test-case "registrations made by a command belong to its defining plugin"
      (call-with-fresh-kernel [commands]
        (lambda ()
          (defplugin (owned-command ctx) "Registers a command from another command."
            requires: [commands-service]
            (defcommand (install-action) "Install another action."
              (defcommand (created-action) "Owned by this plugin." 'created)))
          (activate-plugin! owned-command)
          (call-command 'install-action)
          (check (entry-owner (command-entry 'created-action)) => 'owned-command)
          (check (call-command 'created-action) => 'created)
          (deactivate-plugin! owned-command)
          (check (command-entry 'created-action) => #f))))

    (test-case "the same owner's command leaves only its replacement"
      (for-each
        (lambda ((provider : plugin))
          (call-with-fresh-kernel [provider]
            (lambda ()
              (defplugin (repeated ctx) "Two definitions of one command."
                requires: [commands-service]
                (context-define-command! ctx 'same (lambda () 'old) doc: "Old.")
                (context-define-command! ctx 'same (lambda () 'new) doc: "New."))
              (activate-plugin! repeated)
              (check (command-names) => ['same])
              (check (command-doc (command-ref 'same)) => "New.")
              (check (call-command 'same) => 'new)
              (deactivate-plugin! repeated)
              (check (command-entry 'same) => #f))))
        [commands toy-commands]))

    (test-case "command advice follows the name across definitions and owner removal"
      (for-each
        (lambda ((provider : plugin))
          (call-with-fresh-kernel [provider]
            (lambda ()
              (defplugin (doubler ctx) "Runs the greeting twice."
                requires: [commands-service]
                (advise! ctx (command-target 'greet) 'twice
                  around: (lambda (original) (list (original) (original)))))
              (defplugin (greeter ctx) "Defines the greeting."
                requires: [commands-service]
                (context-define-command! ctx 'greet (lambda () 'hello)))
              ;; Advice may come before the command exists, as in Emacs.
              (activate-plugin! doubler)
              (activate-plugin! greeter)
              (check (call-command 'greet) => '(hello hello))
              (check (map advice-info-name (advice-target-info-advice (advice-for (command-target 'greet))))
                     => '(twice))
              (deactivate-plugin! greeter)
              (activate-plugin! greeter)
              (check (call-command 'greet) => '(hello hello))
              (deactivate-plugin! doubler)
              (check (call-command 'greet) => 'hello)
              (check (advised-targets) => '()))))
        [commands toy-commands]))

    (test-case "named calls run command hooks even without an input provider"
      (for-each
        (lambda ((provider : plugin))
          (call-with-fresh-kernel [provider actions]
            (lambda ()
              (let (events [])
                (defplugin (observer ctx)
                  "Observes command activations independently of input."
                  requires: [commands-service]
                  (context-add-hook! ctx pre-command-hook 'pre
                    (lambda () (set! events (append events [['pre (this-command)]]))))
                  (context-add-hook! ctx post-command-hook 'post
                    (lambda () (set! events (append events [['post (this-command)]])))))
                (activate-plugin! observer)
                (check (service-provider input-service) => #f)
                (check (call-command 'wrapper-action) => 'visible-action)
                (check events => '((pre wrapper-action) (pre visible-action)
                                  (post visible-action) (post wrapper-action)))
                (check (this-command) => #f)))))
        [commands toy-commands]))
    (test-case "commands work without an input provider and preserve provenance"
      (for-each
       (lambda ((provider : plugin))
          (call-with-fresh-kernel [provider actions]
            (lambda ()
              (check (service-provider input-service) => #f)
              (check (list-sort string<? (map symbol->string (command-names)))
                     => ["hidden-action" "visible-action" "wrapper-action"])
              (check (entry-owner (command-entry 'visible-action)) => 'actions)
              (check (command-doc (command-ref 'visible-action)) => "A documented action.")
              (check (string? (entry-source (command-entry 'visible-action))) => #t)
              (check ((command-visible? (command-ref 'hidden-action))
                      (command-ref 'hidden-action) #f) => #f)
              (check (call-command 'visible-action) => 'visible-action)
              (check (this-command) => #f)
              (check (last-command) => 'visible-action)
              (check (call-command 'hidden-action) => 'hidden)
              (check (last-command) => 'hidden-action)
              (check (call-command 'wrapper-action) => 'visible-action)
              (check (last-command) => 'visible-action)
              (check-exception (call-command 'missing-action) Error?)
              (deactivate-plugin! actions)
              (check (command-names) => [])
              (check (command-entry 'visible-action) => #f))))
      [commands toy-commands]))))

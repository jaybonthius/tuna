;;; Registry behavior without a Keys provider; package macros use Commands.
prelude: :gerbil/core
(import :std/test :std/error :tuna/kernel :tuna/services/commands
        :tuna/plugins/commands "../test-support/kernel" "../test-support/toy-commands")
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
      [commands-plugin toy-commands-plugin]))))

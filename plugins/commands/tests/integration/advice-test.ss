#lang :tuna/prelude
(import :std/test :std/error (only-in :gerbil/runtime/mop slot-ref) (only-in :tuna/lib/advice refresh-advice!) :tuna/kernel :tuna/plugins/commands/contract
        :tuna/plugins/commands/plugin "../support/toy-commands" "../support/advice-client"
        "../../../../tuna/tests/support/kernel" "../../../../tuna/tests/support/string-input")
(export advice-test)

(def events [])
(def (note! (event : :t)) => :void (set! events (append events [event])))
(def (live-callback) => :void (note! 'old-callback))
(def (layers) => :list (advice-target-info-advice (advice-for (command action))))
(def (with-provider (thunk : :procedure)) => :void
  (for-each (lambda ((provider : plugin))
              (call-with-fresh-kernel [provider] thunk))
            [commands toy-commands]))

(def advice-test
  (test-suite "commands own advice"
    (test-case "public routing, command type coexistence and ten shared kinds"
      (with-provider
       (lambda ()
         (let ((ctx #f) (base-result 'base))
           (defplugin (target ctx) "A zero-argument command." requires: [commands-service]
             (defcommand (action) "The action." (note! 'base) base-result))
           (defplugin (advisor owner) "Installs advice through public forms." requires: [commands-service]
             (set! ctx owner))
           (activate-plugin! target)
           (activate-plugin! advisor)
           ;; Deliberately shadow the historical router control identifiers.
           (let ((add #f) (remove #f) (inspect #f))
             (advise! ctx (command action) 'one before: (lambda () (note! 'advice)))
             (check (command? (command-ref 'action)) => #t)
             (check (advice-target-info-kind (advice-for (command action))) => 'command)
             (check (advice-target-info-name (advice-for (command action))) => 'action)
             (check (map advice-info-name (layers)) => '(one))
             (check (string? (advice-info-source (car (layers)))) => #t)
             (unadvise! ctx (command action) 'one))
           (for-each
            (lambda (kind)
              (set! events [])
              (set! base-result (if (eq? kind 'after-until) #f 'base))
              ;; Direct routing exercises normalized dynamic kinds without
              ;; duplicating the shared combinator suite's argument/value cases.
              (command-advice-target add: ctx 'action 'one kind
                (case kind
                  ((around) (lambda (original) (note! 'advice) (original)))
                  ((filter-args) (lambda (args) (note! 'advice) args))
                  ((filter-return) (lambda (value) (note! 'advice) value))
                  (else (lambda () (note! 'advice)
                          (if (eq? kind 'before-until) #f 'advice))))
                source: "kind-probe")
              (call-command 'action)
              (check events => (case kind
                                ((override) '(advice))
                                ((after filter-return after-while after-until) '(base advice))
                                (else '(advice base))))
              (unadvise! ctx (command action) 'one)
              (check (layers) => []))
            '(before after around override filter-args filter-return
              before-while before-until after-while after-until))
           (check (advised-commands) => [])
           (set! events [])
           (call-command 'action)
           (check events => '(base))))))

    (test-case "ordering, same-owner replacement and independent owner cleanup"
      (with-provider
       (lambda ()
         (let ((a #f) (b #f))
           (defplugin (target ctx) "Defines action." requires: [commands-service]
             (defcommand (action) "Base." (note! 'base)))
           (defplugin (first ctx) "Earlier declaration." requires: [commands-service] (set! a ctx))
           (defplugin (second ctx) "Later declaration." requires: [commands-service] (set! b ctx))
           (activate-plugin! target)
           (activate-plugin! first order: 1)
           (activate-plugin! second order: 2)
           ;; Registration is deliberately reversed relative to declaration order.
           (advise! b (command action) 'z before: (lambda () (note! 'second)))
           (advise! a (command action) 'z before: (lambda () (note! 'old)))
           (advise! a (command action) 'a before: (lambda () (note! 'a)))
           (advise! a (command action) 'z before: (lambda () (note! 'z)))
           (advise! b (command action) 'outer before: (lambda () (note! 'outer)) depth: -1)
           (set! events [])
           (call-command 'action)
           (check events => '(outer a z second base))
           (check (map advice-info-owner (layers)) => '(second first first second))
           (set-plugin-order! first 3)
           (refresh-advice!)
           (check (map advice-info-name (layers)) => '(outer z a z))
           (unadvise! b (command action) 'outer)
           (deactivate-plugin! first)
           (set! events [])
           (call-command 'action)
           (check events => '(second base))
           (check (map advice-info-owner (layers)) => '(second))
           (deactivate-plugin! second)
           (check (layers) => [])
           (check (advised-commands) => [])
           (set! events [])
           (call-command 'action)
           (check events => '(base))))))

    (test-case "advice precedes definitions, survives absence and re-enable, and follows fresh bases"
      (with-provider
       (lambda ()
         (let ((owner #f) (version 'first) (advisor-ctx #f))
           (defplugin (advisor ctx) "Advises an absent name." requires: [commands-service]
             (set! advisor-ctx ctx)
             (advise! ctx (command action) 'observe before: (lambda () (note! 'advice))))
           (defplugin (target ctx) "Removable definition." requires: [commands-service]
             (set! owner ctx)
             (context-define-command! ctx 'action (lambda () version) doc: "Original."))
           (activate-plugin! advisor)
           (let (identity (advice-target-info-identity (advice-for (command action))))
             (check (command-entry 'action) => #f)
             (check (map advice-target-info-name (advised-commands)) => '(action))
             (check (advice-target-info-source (car (advised-commands))) => #f)
             (activate-plugin! target)
             (check (call-command 'action) => 'first)
             (context-define-command! owner 'action (lambda () 'replacement) doc: "Replacement.")
             (check (call-command 'action) => 'replacement)
             (check (command-doc (command-ref 'action)) => "Replacement.")
             (deactivate-plugin! target)
             (check (command-entry 'action) => #f)
             (check (eq? identity (advice-target-info-identity (advice-for (command action)))) => #t)
             (set! version 'enabled)
             (activate-plugin! target)
             (set! events [])
             (check (call-command 'action) => 'enabled)
             (check events => '(advice))
             (unadvise! advisor-ctx (command action) 'observe)
             (check (call-command 'action) => 'enabled)
             (check (advised-commands) => []))))))

    (test-case "shadowed definitions rebuild from base and preserve current provenance and metadata"
      (with-provider
       (lambda ()
         (let ((advisor-ctx #f) (lower-ctx #f) (visible (lambda (c origin) (eq? origin 'allowed))))
           (defplugin (lower ctx) "Shadowed definition." requires: [commands-service]
             (set! lower-ctx ctx)
             (with-service-provider (provider commands-service Commands)
               (Commands-define-command! provider ctx
                 (make-command name: 'action procedure: (lambda () 'lower)
                               doc: "Lower doc." visible?: visible modes: '(text) arguments: '(prefix))
                 "lower-source")))
           (defplugin (upper ctx) "Winning definition." requires: [commands-service]
             (context-define-command! ctx 'action (lambda () 'upper) doc: "Upper doc." source: "upper-source"))
           (defplugin (advisor ctx) "Wraps all definitions." requires: [commands-service]
             (set! advisor-ctx ctx)
             (advise! ctx (command action) 'wrap around: (lambda (original) (list 'wrapped (original)))))
           (activate-plugin! lower order: 1)
           (activate-plugin! upper order: 2)
           (activate-plugin! advisor)
           (check (call-command 'action) => '(wrapped upper))
           (check (entry-owner (command-entry 'action)) => 'upper)
           (check (entry-source (command-entry 'action)) => "upper-source")
           (check (entry-doc (command-entry 'action)) => "Upper doc.")
           ;; Replacing under advice must not wrap yesterday's wrapper.
           (context-define-command! lower-ctx 'action (lambda () 'lower-new) doc: "New doc." source: "new-source")
           (deactivate-plugin! upper)
           (check (call-command 'action) => '(wrapped lower-new))
           (check (entry-owner (command-entry 'action)) => 'lower)
           (check (entry-source (command-entry 'action)) => "new-source")
           (unadvise! advisor-ctx (command action) 'wrap)
           (check (call-command 'action) => 'lower-new)
           ;; Reinstall all metadata through the actual interface.
           (with-service-provider (provider commands-service Commands)
             (Commands-define-command! provider lower-ctx
               (make-command name: 'action procedure: (lambda () 'metadata)
                             doc: "Metadata." visible?: visible modes: '(text) arguments: '(prefix))
               "metadata-source"))
           (advise! advisor-ctx (command action) 'wrap before: void)
           (let (c (command-ref 'action))
             (check (command-doc c) => "Metadata.")
             (check (eq? (command-visible? c) visible) => #t)
             (check ((command-visible? c) c 'allowed) => #t)
             (check (command-modes c) => '(text))
             (check (command-arguments c) => '(prefix)))
           (check (entry-source (command-entry 'action)) => "metadata-source")))))

    (test-case "ordinary command registries remain separate"
      (call-with-fresh-kernel [commands]
        (lambda ()
          (defplugin (target ctx) "Same name in both registries." requires: [commands-service]
            (defcommand (action) "Base." 'base))
          (defplugin (advisor ctx) "Only the outer registry is advised." requires: [commands-service]
            (advise! ctx (command action) 'replace override: (lambda () 'advised)))
          (activate-plugin! target)
          (activate-plugin! advisor)
          (check (call-command 'action) => 'advised)
          (call-with-fresh-kernel [commands target]
            (lambda ()
              (check (call-command 'action) => 'base)
              (check (layers) => [])
              (check (advised-commands) => [])))
          (check (call-command 'action) => 'advised))))

    (test-case "named callbacks stay live and advice failures name the advisor"
      (with-provider
       (lambda ()
         (let (ctx #f)
           (defplugin (target ctx) "Base." requires: [commands-service]
             (defcommand (action) "Base." 'base))
           (defplugin (advisor owner) "Named live callback." requires: [commands-service]
             (set! ctx owner)
             (advise! ctx (command action) 'live before: live-callback))
           (redefine (live-callback) (note! 'old-callback))
           (activate-plugin! target)
           (activate-plugin! advisor)
           (set! events [])
           (call-command 'action)
           (redefine (live-callback) (note! 'new-callback))
           (call-command 'action)
           (check events => '(old-callback new-callback))
           (advise! ctx (command action) 'live before: (lambda () (error "advisor-broke")))
           (let (failure (with-catch values (lambda () (call-command 'action))))
             (check (advice-error? failure) => #t)
             (check (car (error-irritants failure)) => 'advisor)
             (check (cadr (error-irritants failure)) => 'live))
           (check-exception (call-command 'action) advice-error?)))))

    (test-case "ordinary named callbacks and all three hygienic routes cross module boundaries"
      (with-provider
       (lambda ()
         (let (ctx #f)
           (defplugin (target ctx) "Base." requires: [commands-service]
             (defcommand (action) "Base." 'base))
           (defplugin (advisor owner) "Client module advice." requires: [commands-service]
             (set! ctx owner)
             (install-client-advice! ctx))
           (replace-client-callback! (lambda () 'initial))
           (activate-plugin! target)
           (activate-plugin! advisor)
           (check (call-command 'action) => 'initial)
           (replace-client-callback! (lambda () 'replacement))
           (check (call-command 'action) => 'replacement)
           (check (map advice-info-name (advice-target-info-advice (client-advice))) => '(client))
           (remove-client-advice! ctx)
           (check (call-command 'action) => 'base)
           (check (advice-target-info-advice (client-advice)) => [])))))

    (test-case "absent targets reuse owner receipt buckets across three add/remove cycles"
      (with-provider
       (lambda ()
         (let ((ctx #f) (identity #f))
           (defplugin (advisor owner) "Owns absent-target advice." requires: [commands-service]
             (set! ctx owner))
           (activate-plugin! advisor)
           (check (length (slot-ref ctx 'receipt)) => 0)
           (for-each
            (lambda (cycle)
              (advise! ctx (command action) 'one before: void)
              (unless identity
                (set! identity (advice-target-info-identity (advice-for (command action)))))
              (check (eq? identity (advice-target-info-identity (advice-for (command action)))) => #t)
              (check (length (slot-ref ctx 'receipt)) => 2)
              (unadvise! ctx (command action) 'one)
              (check (layers) => [])
              (check (advised-commands) => [])
              ;; Empty records still have a live owner's two cleanup notes.
              (check (eq? identity (advice-target-info-identity (advice-for (command action)))) => #t)
              (check (length (slot-ref ctx 'receipt)) => 2))
            '(1 2 3))
           (deactivate-plugin! advisor)
           (check (length (slot-ref ctx 'receipt)) => 0)
           (check (advised-commands) => [])
           (check (eq? (advice-target-info-identity (advice-for (command action)))
                       (advice-target-info-identity (advice-for (command action)))) => #f)))))

    (test-case "inspection and rejected registration do not cache possible targets"
      (with-provider
       (lambda ()
         (let (ctx #f)
           (defplugin (advisor owner) "Owns no installed advice." requires: [commands-service]
             (set! ctx owner))
           (activate-plugin! advisor)
           (check (eq? (advice-target-info-identity (advice-for (command action)))
                       (advice-target-info-identity (advice-for (command action)))) => #f)
           (check-exception (command-advice-target add: ctx 'action 'invalid 'invalid void) Error?)
           (check (eq? (advice-target-info-identity (advice-for (command action)))
                       (advice-target-info-identity (advice-for (command action)))) => #f)
           (check (length (slot-ref ctx 'receipt)) => 0)
           (check (advised-commands) => [])))))

    (test-case "an advised command restarting its own owner retires quietly"
      (with-provider
       (lambda ()
         (let ((outcomes []) (restarted? #f))
           (defplugin (target ctx) "Restarts itself." requires: [commands-service]
             (defcommand (action) "Restart this owner."
               (with-inhibit-quit
                 (deactivate-plugin! target)
                 (activate-plugin! target)
                 (set! restarted? #t))
               (check-quit)))
           (defplugin (advisor ctx) "Around advice remains during restart." requires: [commands-service]
             (advise! ctx (command action) 'wrap around: (lambda (original) (original))))
           (defplugin (watcher ctx) "Records task outcomes."
             (context-add-hook! ctx task-finished-hook 'finished
               (lambda (id name how) (set! outcomes (cons [name how] outcomes)))))
           (activate-plugin! test-input)
           (activate-plugin! target)
           (activate-plugin! advisor)
           (activate-plugin! watcher)
           (start-editor-loop!)
           (spawn-task! 'self-restart (lambda () (call-command 'action)))
           (check (wait-until (lambda () (assoc 'self-restart outcomes))) => #t)
           (check (assoc 'self-restart outcomes) => '(self-restart returned))
           (check restarted? => #t)
           (check (plugin-active? target) => #t)
           (check (call-on-editor-loop current-message) => "")
           (check (length (call-on-editor-loop layers)) => 1)))))

    (test-case "nested identity and hooks surround advice, not the reverse"
      (with-provider
       (lambda ()
         (defplugin (target ctx) "Nested calls." requires: [commands-service]
           (defcommand (inner) "Inner." (note! ['inner (this-command) (last-command)]))
           (defcommand (action) "Outer." (call-command 'inner)))
         (defplugin (observer ctx) "Hooks and advice." requires: [commands-service]
           (context-add-hook! ctx pre-command-hook 'pre (lambda () (note! ['pre (this-command)])))
           (context-add-hook! ctx post-command-hook 'post (lambda () (note! ['post (this-command)])))
           (advise! ctx (command action) 'before before: (lambda () (note! ['advice (this-command)]))))
         (activate-plugin! target)
         (activate-plugin! observer)
         (set! events [])
         (call-command 'action)
         (check events => '((pre action) (advice action) (pre inner) (inner inner #f) (post inner) (post action)))
         (check (this-command) => #f)
         (check (last-command) => 'inner))))

    (test-case "stopping the command owner quits a direct-style wait inside another owner's advice"
      (with-provider
       (lambda ()
         (let ((waiting #f) (cleaned? #f) (base-called? #f) (outcomes []))
           (defplugin (target ctx) "Owner of the advised command." requires: [commands-service]
             (defcommand (action) "Must not reach the base." (set! base-called? #t)))
           (defplugin (advisor ctx) "Suspends inside advice." requires: [commands-service]
             (advise! ctx (command action) 'wait around:
               (lambda (original)
                 (unwind-protect
                   (begin (suspend (lambda (s) (set! waiting s))) (original))
                   (set! cleaned? #t)))))
           (defplugin (watcher ctx) "Records task outcomes."
             (context-add-hook! ctx task-finished-hook 'finished
               (lambda (id name how) (set! outcomes (cons [name how] outcomes)))))
           (activate-plugin! test-input)
           (activate-plugin! target)
           (activate-plugin! advisor)
           (activate-plugin! watcher)
           (start-editor-loop!)
           (spawn-task! 'advised-wait (lambda () (call-command 'action)))
           (check (wait-until (lambda () waiting)) => #t)
           (call-on-editor-loop (lambda () (deactivate-plugin! target)))
           (check (wait-until (lambda () (assoc 'advised-wait outcomes))) => #t)
           (check (assoc 'advised-wait outcomes) => '(advised-wait quit))
           (check cleaned? => #t)
           (check base-called? => #f)
           (check (plugin-active? advisor) => #t)
           (check (map advice-target-info-name (call-on-editor-loop advised-commands)) => '(action))
           (check (call-on-editor-loop current-message) => "Quit")))))))

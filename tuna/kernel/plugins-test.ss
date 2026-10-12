(import (only-in :gerbil/runtime/hash HashTable)
        :std/error
        :std/interface
        :std/test
        :tuna/kernel)
(export plugins-test)

(include "test-fixtures.ss")

(interface Greeter
  (greet) => :string)

(defstruct greeter ((text : :string))
  final: #t)

(defmethod {greet greeter}
  (lambda (self) (greeter-text self)))

(def greeter-service
  (new-service 'greeter is-Greeter? tier: 'live doc: "Says hello."))

(def log [])
(def (note! item) (set! log (cons item log)))
(def (take-log!) (let (items (reverse log)) (set! log []) items))

(defplugin (greeter-a ctx)
  "Provides the greeter A."
  (context-provide! ctx greeter-service (make-greeter "a")))

(defplugin (greeter-b ctx)
  "Provides the greeter B."
  (context-provide! ctx greeter-service (make-greeter "b")))

(defplugin (greeting-user ctx)
  "Uses the greeter."
  requires: [greeter-service]
  (note! (Greeter-greet (Greeter (service-provider greeter-service))))
  (context-defer! ctx (lambda () (note! 'off))))

(defplugin (greeting-adapter ctx)
  "Uses the greeter and adapts to a new one."
  requires: [greeter-service]
  (note! (Greeter-greet (Greeter (service-provider greeter-service))))
  (context-adapt! ctx greeter-service
                  (lambda (old new)
                    (note! [(Greeter-greet (Greeter old)) '-> (Greeter-greet (Greeter new))])))
  (context-defer! ctx (lambda () (note! 'adapter-off))))

(def test-hook (new-hook 'test doc: "A hook for the tests."))

(defplugin (hooked ctx)
  "Adds three callbacks to the test hook; one fails."
  (context-add-hook! ctx test-hook 'late (lambda (x) (note! ['late x])) depth: 10)
  (context-add-hook! ctx test-hook 'broken (lambda (x) (error "broken callback")))
  (context-add-hook! ctx test-hook 'early (lambda (x) (note! ['early x])) depth: -10))

(def table (new-entry-table))

(defplugin (slot-a ctx)
  "Sets the shared slot to a."
  (context-add-entry! ctx table 'slot 'a))

(defplugin (slot-b ctx)
  "Sets the shared slot to b."
  (context-add-entry! ctx table 'slot 'b))

(defplugin (slot-urgent ctx)
  "Sets the shared slot at a higher priority."
  (context-add-entry! ctx table 'slot 'urgent priority: 10))

(def (slot-value)
  (let (best (entry-table-ref table 'slot))
    (and best (entry-value best))))

(defplugin (second-input ctx)
  "Tries to replace the input service."
  (context-provide! ctx input-service (make-test-input (make-hash-table))))

(def plugins-test
  (test-suite "tuna/kernel/plugins"
    (test-case "receipts undo in reverse order"
      (call-with-test-kernel
       (lambda ()
         (defplugin (three-undos ctx)
           "Records three undos."
           (for-each (lambda (n) (context-defer! ctx (lambda () (note! n)))) [1 2 3]))
         (take-log!)
         (activate-plugin! three-undos)
         (check (plugin-active? three-undos) => #t)
         (deactivate-plugin! three-undos)
         (check (take-log!) => [3 2 1])
         (check (plugin-active? three-undos) => #f))))

    (test-case "a failed activation undoes what it registered"
      (call-with-test-kernel
       (lambda ()
         (defplugin (half-done ctx)
           "Registers a command, then fails."
           (define-command ctx (half-done-command) "Never usable." (void))
           (error "activation failed"))
         (check-exception (activate-plugin! half-done) Error?)
         (check (command-ref 'half-done-command) => #f)
         (check (plugin-active? half-done) => #f))))

    (test-case "registrations record their plugin, source, and documentation"
      (call-with-test-kernel
       (lambda ()
         (defplugin (documented ctx)
           "Defines one command."
           (define-command ctx (documented-command) "Does nothing." (void)))
         (activate-plugin! documented)
         (let (e (command-entry 'documented-command))
           (check (entry-owner e) => 'documented)
           (check (entry-doc e) => "Does nothing.")
           (check (and (string? (entry-source e))
                       (string-contains (entry-source e) "plugins-test.ss"))
                  ? values))
         (check (plugin-doc documented) => "Defines one command."))))

    (test-case "owner-tagged entries survive deactivation in either order"
      (call-with-test-kernel
       (lambda ()
         (activate-plugin! slot-a)
         (activate-plugin! slot-b)
         (check (slot-value) => 'b)
         (deactivate-plugin! slot-a)
         (check (slot-value) => 'b)
         (activate-plugin! slot-a)
         (check (slot-value) => 'a)
         (deactivate-plugin! slot-a)
         (check (slot-value) => 'b)
         (activate-plugin! slot-a)
         (deactivate-plugin! slot-b)
         (check (slot-value) => 'a)
         (deactivate-plugin! slot-a)
         (check (slot-value) => #f)
         (activate-plugin! slot-urgent)
         (activate-plugin! slot-a)
         (check (slot-value) => 'urgent)
         (deactivate-plugin! slot-urgent)
         (check (slot-value) => 'a))))

    (test-case "dependents wait for services and follow provider changes"
      (call-with-test-kernel
       (lambda ()
         (take-log!)
         (activate-plugin! greeting-user)
         (check (plugin-active? greeting-user) => #f)
         (activate-plugin! greeter-a)
         (check (plugin-active? greeting-user) => #t)
         (activate-plugin! greeter-b)
         (deactivate-plugin! greeter-b)
         (check (take-log!) => ["a" 'off "b" 'off "a"])
         (deactivate-plugin! greeter-a)
         (check (plugin-active? greeting-user) => #f)
         (activate-plugin! greeter-b)
         (check (plugin-active? greeting-user) => #t)
         (check (take-log!) => ['off "b"]))))

    (test-case "adapting dependents migrate in place, until no provider is left"
      (call-with-test-kernel
       (lambda ()
         (take-log!)
         (activate-plugin! greeter-a)
         (activate-plugin! greeting-adapter)
         (activate-plugin! greeter-b)
         (deactivate-plugin! greeter-b)
         (check (take-log!) => ["a" ["a" '-> "b"] ["b" '-> "a"]])
         (check (plugin-active? greeting-adapter) => #t)
         (deactivate-plugin! greeter-a)
         (check (plugin-active? greeting-adapter) => #f)
         (check (take-log!) => ['adapter-off])
         (activate-plugin! greeter-b)
         (check (take-log!) => ["b"]))))

    (test-case "hooks run by depth, drop a failing callback, and go with their plugin"
      (call-with-test-kernel
       (lambda ()
         (take-log!)
         (activate-plugin! test-input-plugin)
         (activate-plugin! hooked)
         (check (hook-callback-names test-hook) => '(early broken late))
         (run-hook test-hook 1)
         (check (take-log!) => [['early 1] ['late 1]])
         (check (hook-callback-names test-hook) => '(early late))
         (check (string-prefix? "Hook test callback broken" (current-message)) => #t)
         (deactivate-plugin! hooked)
         (check (hook-callback-names test-hook) => '()))))

    (test-case "describe-services lists tier, provider, and dependents"
      (call-with-test-kernel
       (lambda ()
         (activate-plugin! greeter-a)
         (activate-plugin! greeting-user)
         (activate-plugin! test-input-plugin)
         (check (map (lambda (info)
                       [(service-info-name info) (service-info-tier info)
                        (service-info-provider info) (service-info-dependents info)])
                     (describe-services))
                => [['greeter 'live 'greeter-a ['greeting-user]]
                    ['input 'startup 'test-input-plugin []]
                    ['messages 'live 'test-input-plugin []]]))))

    (test-case "startup-tier services refuse live replacement"
      (call-with-test-kernel
       (lambda ()
         (activate-plugin! test-input-plugin)
         (activate-plugin! greeter-a)
         (start-editor-loop!)
         (check-exception (call-on-editor-loop (lambda () (activate-plugin! second-input)))
                          startup-service-error?)
         (check (call-on-editor-loop (lambda () (plugin-active? second-input))) => #f)
         (check-exception (call-on-editor-loop (lambda () (deactivate-plugin! test-input-plugin)))
                          startup-service-error?)
         (check (call-on-editor-loop (lambda () (plugin-active? test-input-plugin))) => #t)
         ;; Live-tier services can still be replaced.
         (call-on-editor-loop (lambda () (activate-plugin! greeter-b)))
         (check (Greeter-greet (Greeter (call-on-editor-loop
                                         (lambda () (service-provider greeter-service)))))
                => "b")
         (stop-editor-loop!)
         (activate-plugin! second-input)
         (check (plugin-active? second-input) => #t))))))

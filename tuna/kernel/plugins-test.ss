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

;; A greeter's greeting, or #f.
(def (greeting provider)
  (and provider (Greeter-greet (Greeter provider))))

(defplugin (lifecycle-watcher ctx)
  "Notes plugin events, whether the plugin is then active, and greeter changes."
  (context-add-hook! ctx plugin-activated-hook 'note-activated
                     (lambda (p) (note! ['activated (plugin-name p) (plugin-active? p)])))
  (context-add-hook! ctx plugin-deactivated-hook 'note-deactivated
                     (lambda (p) (note! ['deactivated (plugin-name p) (plugin-active? p)])))
  (context-add-hook! ctx service-changed-hook 'note-greeter
                     (lambda (svc old new)
                       (when (eq? svc greeter-service)
                         (note! ['greeter (greeting old) (greeting new)
                                 (eq? new (service-provider greeter-service))])))))

(defplugin (lifecycle-breaker ctx)
  "Adds a plugin-activated callback that fails."
  (context-add-hook! ctx plugin-activated-hook 'broken
                     (lambda (p) (error "broken lifecycle callback"))))

(defplugin (lifecycle-meddler ctx)
  "Tries to activate greeter-a when greeter-b activates."
  (context-add-hook! ctx plugin-activated-hook 'meddle
                     (lambda (p)
                       (when (eq? (plugin-name p) 'greeter-b)
                         (activate-plugin! greeter-a)))))

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

;; A stateful service whose providers hand their state over.
(interface Counter
  (label) => :symbol
  (count) => :fixnum
  (set-count! (n : :fixnum)) => :void)

(defclass counter ((name : :symbol) (n : :fixnum))
  final: #t)

(implement Counter counter
  (label (lambda (self) self.name))
  (count (lambda (self) self.n))
  (set-count! (lambda (self n) (set! self.n n))))

(def counter-service
  (new-service 'counter is-Counter? tier: 'live doc: "Counts."
               handover: (lambda (outgoing incoming)
                           (note! ['handover (Counter-label (Counter outgoing)) '-> (Counter-label (Counter incoming))])
                           (Counter-set-count! (Counter incoming) (Counter-count (Counter outgoing))))))

(defplugin (counter-a ctx)
  "Provides the counter A."
  (context-provide! ctx counter-service (Counter (counter name: 'a n: 0))))

(defplugin (counter-b ctx)
  "Provides the counter B, outranking A."
  (context-provide! ctx counter-service (Counter (counter name: 'b n: 100)) priority: 10))

(defplugin (counter-user ctx)
  "Uses the counter; restarts when it is replaced."
  requires: [counter-service]
  (note! ['user-sees (Counter-count (Counter (service-provider counter-service)))]))

(def (counter-value)
  (Counter-count (Counter (service-provider counter-service))))

(defplugin (slots-early ctx)
  "Registers the session slot alpha."
  (context-add-session-slot! ctx 'alpha version: 1 save: (lambda () 'a) restore: void))

(defplugin (slots-late ctx)
  "Registers the session slots beta, and alpha at a higher priority."
  (context-add-session-slot! ctx 'beta version: 2 save: (lambda () 'b) restore: void)
  (context-add-session-slot! ctx 'alpha version: 3 save: (lambda () 'a2) restore: void
                             priority: 10))

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
           "Registers an entry, then fails."
           (context-add-entry! ctx table 'half-done 'never-usable)
           (error "activation failed"))
         (check-exception (activate-plugin! half-done) Error?)
         (check (entry-table-ref table 'half-done) => #f)
         (check (plugin-active? half-done) => #f))))

    (test-case "registrations record their plugin, source, and documentation"
      (call-with-test-kernel
       (lambda ()
         (defplugin (documented ctx)
           "Adds one entry."
           (context-add-entry! ctx table 'documented 'value doc: "Does nothing." source: "here:1"))
         (activate-plugin! documented)
         (let (e (entry-table-ref table 'documented))
           (check (entry-owner e) => 'documented)
           (check (entry-doc e) => "Does nothing.")
           (check (entry-source e) => "here:1"))
         (check (plugin-doc documented) => "Adds one entry.")
         (check (and (string? (plugin-source documented))
                     (string-contains (plugin-source documented) "plugins-test.ss"))
                ? values))))

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

    (test-case "lifecycle hooks announce each change once, after the whole operation"
      (call-with-test-kernel
       (lambda ()
         (take-log!)
         (activate-plugin! lifecycle-watcher)
         (check (take-log!) => [['activated 'lifecycle-watcher #t]])
         (activate-plugin! greeter-a)
         (check (take-log!) => [['greeter #f "a" #t] ['activated 'greeter-a #t]])
         (activate-plugin! greeting-user)
         (check (take-log!) => ["a" ['activated 'greeting-user #t]])
         ;; Replacing the greeter restarts its user. The announcements wait
         ;; until the user has restarted, so the user is active again by the
         ;; time its deactivation is announced.
         (activate-plugin! greeter-b)
         (check (take-log!) => ['off "b"
                                ['deactivated 'greeting-user #t]
                                ['greeter "a" "b" #t]
                                ['activated 'greeter-b #t]
                                ['activated 'greeting-user #t]])
         (deactivate-plugin! greeter-b)
         (check (take-log!) => ['off "a"
                                ['deactivated 'greeting-user #t]
                                ['greeter "b" "a" #t]
                                ['deactivated 'greeter-b #f]
                                ['activated 'greeting-user #t]])
         (deactivate-plugin! greeter-a)
         (check (take-log!) => ['off
                                ['deactivated 'greeting-user #f]
                                ['greeter "a" #f #t]
                                ['deactivated 'greeter-a #f]]))))

    (test-case "a failing lifecycle callback is removed and activation carries on"
      (call-with-test-kernel
       (lambda ()
         (activate-plugin! test-input-plugin)
         (activate-plugin! lifecycle-breaker)
         (check (plugin-active? lifecycle-breaker) => #t)
         (check (string-prefix? "Hook plugin-activated callback broken (from lifecycle-breaker)"
                                (current-message))
                => #t)
         (check (hook-callback-names plugin-activated-hook) => '())
         (activate-plugin! greeter-a)
         (check (plugin-active? greeter-a) => #t))))

    (test-case "lifecycle callbacks must not activate or deactivate plugins"
      (call-with-test-kernel
       (lambda ()
         (activate-plugin! test-input-plugin)
         (activate-plugin! lifecycle-meddler)
         (activate-plugin! greeter-b)
         (check (plugin-active? greeter-b) => #t)
         (check (plugin-active? greeter-a) => #f)
         (check (string-contains (current-message)
                                 "Lifecycle hook callbacks must not activate or deactivate plugins")
                ? values)
         (check (hook-callback-names plugin-activated-hook) => '()))))

    (test-case "a kernel dropped without deactivating its plugins leaves no callbacks behind"
      (take-log!)
      (parameterize ((current-kernel (new-kernel)))
        (activate-plugin! hooked)
        (activate-plugin! lifecycle-watcher)
        (check (hook-callback-names test-hook) => '(early broken late)))
      (take-log!)
      (call-with-test-kernel
       (lambda ()
         (check (hook-callback-names test-hook) => '())
         (check (hook-callback-names plugin-activated-hook) => '())
         (run-hook test-hook 2)
         (activate-plugin! greeter-a)
         (check (take-log!) => [])
         (activate-plugin! hooked)
         (check (hook-callback-names test-hook) => '(early broken late)))))

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

    (test-case "a service's handover moves state between providers, before dependents restart"
      (call-with-test-kernel
       (lambda ()
         (activate-plugin! counter-a)
         (activate-plugin! counter-user)
         (Counter-set-count! (Counter (service-provider counter-service)) 7)
         (take-log!)
         (activate-plugin! counter-b)
         (check (take-log!) => [['handover 'a '-> 'b] ['user-sees 7]])
         (Counter-set-count! (Counter (service-provider counter-service)) 8)
         (deactivate-plugin! counter-b)
         (check (take-log!) => [['handover 'b '-> 'a] ['user-sees 8]])
         (check (counter-value) => 8)
         ;; With no provider left, there is no one to hand over to.
         (deactivate-plugin! counter-a)
         (check (take-log!) => []))))

    (test-case "session slots follow their plugins; the oldest name comes first"
      (call-with-test-kernel
       (lambda ()
         (let (slots (lambda ()
                       (map (lambda (slot) [(session-slot-name slot) (session-slot-version slot)
                                            ((session-slot-save slot))])
                            (session-slots))))
           (activate-plugin! slots-early)
           (activate-plugin! slots-late)
           (check (slots) => [['alpha 3 'a2] ['beta 2 'b]])
           (deactivate-plugin! slots-late)
           (check (slots) => [['alpha 1 'a]])
           (deactivate-plugin! slots-early)
           (check (slots) => [])))))

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

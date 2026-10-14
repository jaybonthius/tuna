(import :std/error
        :std/interface
        :std/test
        :tuna/kernel
        (only-in :tuna/kernel/state new-kernel current-kernel)
        (only-in :tuna/kernel/plugins startup-service-error?)
        (only-in :tuna/kernel/hooks hook-callback-names)
        (only-in :tuna/kernel/entries entry-table-remove!)
        "../test-support/kernel"
        "../test-support/string-input")
(export plugins-test)
(declare (separate))

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

(def (late-hook-callback (item : :t)) => :void (note! ['before item]))

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

(def (greeter-dispatch-context (svc : service)) => (Maybe context)
  (with-service-provider (provider svc Greeter)
    (Greeter-greet provider)
    (current-context)))

(defplugin (lifecycle-watcher ctx)
  "Notes plugin events, whether the plugin is then active, and greeter changes."
  optional: [greeter-service]
  (context-add-hook! ctx plugin-activated-hook 'note-activated
                     (lambda (p) (note! ['activated (plugin-name p) (plugin-active? p)])))
  (context-add-hook! ctx plugin-deactivated-hook 'note-deactivated
                     (lambda (p) (note! ['deactivated (plugin-name p) (plugin-active? p)])))
  (context-add-hook! ctx service-changed-hook 'note-greeter
                     (lambda (svc old new)
                       (when (eq? svc greeter-service)
                         (note! ['greeter (greeting old) (greeting new)
                                 (eq? new (service-provider greeter-service))])))))

(defplugin (greeter-then-fails ctx)
  "Provides a greeter that outranks A, then fails to activate."
  (context-provide! ctx greeter-service (make-greeter "bad") priority: 5)
  (error "activation failed"))

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

(defplugin (second-input ctx)
  "Tries to replace the input service."
  (context-provide! ctx input-service (make-test-input (make-hash-table))))

;; Call THUNK and return what it wrote to stdout and to stderr.
(def (captured-output thunk)
  (let ((out (open-output-string))
        (err (open-output-string)))
    (parameterize ((current-output-port out)
                   (current-error-port err))
      (thunk))
    [(get-output-string out) (get-output-string err)]))

(def plugins-test
  (test-suite "tuna/kernel/plugins"

    (test-case "warm service cells follow providers, ranks, aliases and withdrawal"
      (call-with-fresh-kernel []
        (lambda ()
          (let (alias (new-service 'greeter is-Greeter? tier: 'live doc: "Same slot."))
            (check (service-provider greeter-service) => #f)
            (check (service-provider alias) => #f)
            (activate-plugin! greeter-a order: 1)
            (let (a-context (greeter-dispatch-context greeter-service))
              (activate-plugin! greeter-b order: 2)
              (let (b-context (greeter-dispatch-context greeter-service))
                (check (greeting (service-provider alias)) => "b")
                (set-plugin-order! greeter-a 3)
                (check (greeting (service-provider greeter-service)) => "a")
                (check (greeter-dispatch-context alias) => a-context)
                (activate-plugin! greeter-b order: 4)
                (check (greeting (service-provider alias)) => "b")
                (check (greeter-dispatch-context greeter-service) => b-context)
                (deactivate-plugin! greeter-b)
                (check (greeter-dispatch-context alias) => a-context)
                (deactivate-plugin! greeter-a)
                (check (service-provider greeter-service) => #f)
                (check (service-provider alias) => #f)))))))

    (test-case "warm dispatch retains activation, active and cleanup owner scopes"
      (call-with-fresh-kernel []
        (lambda ()
          (take-log!)
          (let (owner-context #f)
            (defplugin (cache-owner ctx) "Warms dispatch while activating and cleaning up."
              (set! owner-context ctx)
              (context-provide! ctx greeter-service (make-greeter "cached"))
              (check (greeter-dispatch-context greeter-service) => ctx)
              (context-defer! ctx
                (lambda () (note! (greeter-dispatch-context greeter-service)))))
            (activate-plugin! cache-owner)
            (check (current-context) => #f)
            (check (greeter-dispatch-context greeter-service) => owner-context)
            (check (call-with-context (:- owner-context context)
                     (lambda () (greeter-dispatch-context greeter-service)))
                   => owner-context)
            (check (current-context) => #f)
            (deactivate-plugin! cache-owner)
            (check (take-log!) => [owner-context])
            (check (service-provider greeter-service) => #f)))))

    (test-case "warm cells recover the provider and owner after failed activation"
      (call-with-fresh-kernel [greeter-a]
        (lambda ()
          (let (a-context (greeter-dispatch-context greeter-service))
            (defplugin (cached-failure ctx) "Provides, warms dispatch, then fails."
              (context-provide! ctx greeter-service (make-greeter "bad") priority: 5)
              (check (greeter-dispatch-context greeter-service) => ctx)
              (error "activation failed"))
            (check-exception (activate-plugin! cached-failure) Error?)
            (check (greeting (service-provider greeter-service)) => "a")
            (check (greeter-dispatch-context greeter-service) => a-context)))))

    (test-case "service cells and self-use checks follow nested kernel selection"
      (call-with-fresh-kernel [greeter-a]
        (lambda ()
          (let ((alias (new-service 'greeter is-Greeter? tier: 'live doc: "Same slot."))
                (a-context (greeter-dispatch-context greeter-service)))
            (check (greeting (service-provider alias)) => "a")
            (call-with-fresh-kernel [greeter-b]
              (lambda ()
                (check (greeting (service-provider greeter-service)) => "b")
                (check (greeting (service-provider alias)) => "b")
                (check (with-catch exception-summary
                         (lambda ()
                           (call-with-context (:- a-context context)
                             (lambda () (service-provider greeter-service)))))
                       => "Plugin used an undeclared service greeter-a greeter")))
            (check (greeting (service-provider alias)) => "a")
            (check (greeter-dispatch-context greeter-service) => a-context)))))
    (test-case "an undeclared activating owner is rejected even without a provider"
      (call-with-fresh-kernel []
        (lambda ()
          (check (service-provider greeter-service) => #f)
          (defplugin (undeclared ctx) "Undeclared lookup."
            (service-provider greeter-service))
          (check (with-catch exception-summary (lambda () (activate-plugin! undeclared)))
                 => "Plugin used an undeclared service undeclared greeter")
          (check (plugin-active? undeclared) => #f)
          (defplugin (optional-user ctx) "Explicit guarded lookup."
            optional: [greeter-service]
            (note! (service-provider greeter-service)))
          (take-log!)
          (activate-plugin! optional-user)
          (check (take-log!) => [#f])
          (activate-plugin! greeter-a)
          (deactivate-plugin! greeter-a)
          (check (plugin-active? optional-user) => #t))))

    (test-case "kernel message needs no declaration, with a provider or stderr"
      (call-with-fresh-kernel []
        (lambda ()
          (defplugin (logging-owner ctx) "Uses the kernel message facility."
            (message "No Messages provider")
            (context-add-hook! ctx test-hook 'log (lambda (item) (message item))))
          (check (captured-output (lambda () (activate-plugin! logging-owner)))
                 => ["" "No Messages provider\n"])
          (activate-plugin! test-messages-plugin)
          (run-hook test-hook "A Messages provider")
          (check (current-message) => "A Messages provider")
          (defplugin (raw-messages-user ctx) "Raw service access still needs a declaration."
            (service-provider messages-service))
          (check (with-catch exception-summary (lambda () (activate-plugin! raw-messages-user)))
                 => "Plugin used an undeclared service raw-messages-user messages"))))

    (test-case "a provider may use its own service, including while shadowed"
      (call-with-fresh-kernel []
        (lambda ()
          (defplugin (self-user ctx) "Provides and uses Greeter without requiring itself."
            (context-provide! ctx greeter-service (make-greeter "self"))
            (note! (call-with-service-provider greeter-service
                     (lambda (implementation) (Greeter-greet (Greeter implementation)))))
            (context-add-hook! ctx test-hook 'self
              (lambda (item) (note! (Greeter-greet (Greeter (service-provider greeter-service)))))))
          (take-log!)
          (activate-plugin! self-user order: 1)
          (check (take-log!) => ["self"])
          (activate-plugin! greeter-b order: 2)
          (check (plugin-active? self-user) => #t)
          (run-hook test-hook #f)
          (check (take-log!) => ["b"]))))

    (test-case "same-owner provider replacement still hands over and restarts dependents"
      (call-with-fresh-kernel []
        (lambda ()
          (let (provider-context #f)
            (defplugin (repeated-provider ctx) "Keeps a context for replacement."
              (set! provider-context ctx)
              (context-provide! ctx counter-service (Counter (counter name: 'old n: 17))))
            (defplugin (replace-provider ctx) "Replaces the same owner's contribution."
              (context-provide! (:- provider-context context) counter-service
                                (Counter (counter name: 'new n: 100))))
            (activate-plugin! repeated-provider)
            (activate-plugin! counter-user)
            (take-log!)
            (activate-plugin! replace-provider)
            (check (take-log!) => '((handover old -> new) (user-sees 17)))
            (check (counter-value) => 17)
            (deactivate-plugin! repeated-provider)
            (check (service-provider counter-service) => #f)
            (check (plugin-active? counter-user) => #f)))))

    (test-case "same-owner startup provider replacement is still rejected while live"
      (call-with-fresh-kernel []
        (lambda ()
          (let (provider-context #f)
            (defplugin (owned-input ctx) "Keeps the original input context."
              (set! provider-context ctx)
              (context-provide! ctx input-service (make-test-input (make-hash-table))))
            (defplugin (replace-input ctx) "Attempts a same-owner input replacement."
              (context-provide! (:- provider-context context) input-service
                                (make-test-input (make-hash-table))))
            (activate-plugin! owned-input)
            (let (before (service-provider input-service))
              (start-editor-loop!)
              (check-exception (call-on-editor-loop (lambda () (activate-plugin! replace-input)))
                               startup-service-error?)
              (check (service-provider input-service) => before)
              (check (plugin-active? owned-input) => #t)
              (check (plugin-active? replace-input) => #f))))))

    (test-case "entry ties follow supplied rank when the older owner reloads"
      (call-with-fresh-kernel []
        (lambda ()
          (activate-plugin! slot-a order: 1)
          (activate-plugin! slot-b order: 2)
          (check (slot-value) => 'b)
          (deactivate-plugin! slot-a)
          (activate-plugin! slot-a)
          (check (slot-value) => 'b)
          (set-plugin-order! slot-a 3)
          (check (slot-value) => 'a))))

    (test-case "same owner and slot replaces; a stale inverse leaves the replacement alone"
      (call-with-fresh-kernel []
        (lambda ()
          (defplugin (duplicates ctx) "Re-register one slot."
            (let (old (context-add-entry! ctx table 'slot 'old))
              (context-add-entry! ctx table 'slot 'new)
              (entry-table-remove! table 'slot old)))
          (activate-plugin! duplicates)
          (check (slot-value) => 'new)
          (check (length (entry-table-entries table 'slot)) => 1)
          (deactivate-plugin! duplicates)
          (check (slot-value) => #f))))

    (test-case "a named hook follows redefinition and duplicate registration leaves one"
      (call-with-fresh-kernel []
        (lambda ()
          (let (before late-hook-callback)
            (unwind-protect
              (begin
                (defplugin (named-hook ctx) "A named module callback."
                  (context-add-hook! ctx test-hook 'late late-hook-callback)
                  (context-add-hook! ctx test-hook 'late late-hook-callback))
                (activate-plugin! named-hook)
                (check (hook-callback-names test-hook) => '(late))
                (take-log!)
                (run-hook test-hook 1)
                (check (take-log!) => [['before 1]])
                (set! late-hook-callback (lambda (item) (note! ['after item])))
                (run-hook test-hook 2)
                (check (take-log!) => [['after 2]])
                (deactivate-plugin! named-hook)
                (check (hook-callback-names test-hook) => '()))
              (set! late-hook-callback before))))))

    (test-case "receipts undo in reverse order"
      (call-with-fresh-kernel []
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
      (call-with-fresh-kernel []
       (lambda ()
         (defplugin (half-done ctx)
           "Registers an entry, then fails."
           (context-add-entry! ctx table 'half-done 'never-usable)
           (error "activation failed"))
         (check-exception (activate-plugin! half-done) Error?)
         (check (entry-table-ref table 'half-done) => #f)
         (check (plugin-active? half-done) => #f))))

    (test-case "registrations record their plugin, source, and documentation"
      (call-with-fresh-kernel []
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
      (call-with-fresh-kernel []
       (lambda ()
         (activate-plugin! slot-a)
         (activate-plugin! slot-b)
         (check (slot-value) => 'b)
         (deactivate-plugin! slot-a)
         (check (slot-value) => 'b)
         (activate-plugin! slot-a)
         (check (slot-value) => 'b)
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
      (call-with-fresh-kernel []
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
      (call-with-fresh-kernel []
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
      (call-with-fresh-kernel []
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
      (call-with-fresh-kernel []
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

    (test-case "an operation that raises still announces what it changed, in order"
      (call-with-fresh-kernel []
       (lambda ()
         (activate-plugin! lifecycle-watcher)
         (activate-plugin! greeter-a)
         (activate-plugin! greeting-user)
         (take-log!)
         ;; The failing provider restarts the user and is rolled back, so the
         ;; greeter flips to bad and back to a before the user returns.
         (check-exception (activate-plugin! greeter-then-fails) Error?)
         (check (take-log!) => ['off "a"
                                ['deactivated 'greeting-user #t]
                                ['greeter "a" "bad" #f]
                                ['greeter "bad" "a" #t]
                                ['activated 'greeting-user #t]])
         (check (plugin-active? greeter-then-fails) => #f))))

    (test-case "a failing lifecycle callback is removed and activation carries on"
      (call-with-fresh-kernel []
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
      (call-with-fresh-kernel []
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
      (call-with-fresh-kernel []
       (lambda ()
         (check (hook-callback-names test-hook) => '())
         (check (hook-callback-names plugin-activated-hook) => '())
         (run-hook test-hook 2)
         (activate-plugin! greeter-a)
         (check (take-log!) => [])
         (activate-plugin! hooked)
         (check (hook-callback-names test-hook) => '(early broken late)))))

    (test-case "describe-services lists tier, provider, and dependents"
      (call-with-fresh-kernel []
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
      (call-with-fresh-kernel []
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

    (test-case "message writes to stderr, not stdout, while no plugin provides Messages"
      (call-with-fresh-kernel []
       (lambda ()
         (check (captured-output (lambda () (message "hello"))) => ["" "hello\n"])
         (check (captured-output (lambda () (message ""))) => ["" ""]))))

    (test-case "a plugin failure goes to stderr exactly once, and to Messages when provided"
      (call-with-fresh-kernel []
       (lambda ()
         (defplugin (failing-undo ctx)
           "Registers an undo that fails."
           (context-defer! ctx (lambda () (error "undo failed"))))
         (let (report "Plugin failing-undo failed while deactivating: undo failed")
           (activate-plugin! failing-undo)
           (check (captured-output (lambda () (deactivate-plugin! failing-undo)))
                  => ["" (string-append report "\n")])
           (activate-plugin! test-input-plugin)
           (activate-plugin! failing-undo)
           (check (captured-output (lambda () (deactivate-plugin! failing-undo)))
                  => ["" (string-append report "\n")])
           (check (current-message) => report)))))

    (test-case "startup-tier services refuse live replacement"
      (call-with-fresh-kernel []
       (lambda ()
         (activate-plugin! test-input-plugin)
         (activate-plugin! greeter-a)
         (start-editor-loop!)
         (check-exception (call-on-editor-loop (lambda () (activate-plugin! second-input order: 1)))
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

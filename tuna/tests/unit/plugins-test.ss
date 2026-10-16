(import (only-in :gerbil/runtime/mop slot-ref)
        :std/error
        :std/interface
        :std/test
        :tuna/kernel
        (only-in :tuna/kernel/state new-kernel current-kernel)
        (only-in :tuna/kernel/hooks hook-callback-names)
        (only-in :tuna/kernel/entries entry-table-remove!)
        "../support/kernel"
        "../support/string-input")
(export plugins-test)
(declare (separate))

(service-interface Greeter
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
  provides: [greeter-service]
  (context-provide! ctx greeter-service (make-greeter "a") view: Greeter-service-view))

(defplugin (greeter-b ctx)
  "Provides the greeter B."
  provides: [greeter-service]
  (context-provide! ctx greeter-service (make-greeter "b") view: Greeter-service-view))

(defplugin (greeting-user ctx)
  "Uses the greeter."
  requires: [greeter-service]
  (note! (Greeter-greet (Greeter (service-provider greeter-service))))
  (context-defer! ctx (lambda () (note! 'off))))

(def test-hook (new-hook 'test doc: "A hook for the tests."))

(defplugin (hooked ctx)
  "Adds three callbacks to the test hook; one fails."
  (context-add-hook! ctx test-hook 'late (lambda (x) (note! ['late x])) depth: 10)
  (context-add-hook! ctx test-hook 'broken (lambda (x) (error "broken callback")))
  (context-add-hook! ctx test-hook 'early (lambda (x) (note! ['early x])) depth: -10))

;; A greeter's greeting, or #f.
(def (greeting provider)
  (and provider (Greeter-greet (Greeter provider))))

(def (greeter-dispatch (svc : service)) => :string
  (with-service-provider (provider svc Greeter) (Greeter-greet provider)))

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
  provides: [greeter-service]
  (context-provide! ctx greeter-service (make-greeter "bad") view: Greeter-service-view)
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
(service-interface Counter
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
  (new-service 'counter is-Counter? tier: 'live doc: "Counts."))

(defplugin (counter-a ctx)
  "Provides the counter A."
  provides: [counter-service]
  (context-provide! ctx counter-service (Counter (counter name: 'a n: 0)) view: Counter-service-view))

(defplugin (counter-b ctx)
  "Provides the counter B, outranking A."
  provides: [counter-service]
  (context-provide! ctx counter-service (Counter (counter name: 'b n: 100)) view: Counter-service-view))

(defplugin (counter-user ctx)
  "Uses the counter; restarts when it is replaced."
  requires: [counter-service]
  (note! ['user-sees (Counter-count (Counter (service-provider counter-service)))]))

(def (counter-value)
  (Counter-count (Counter (service-provider counter-service))))

(defplugin (second-input ctx)
  "Tries to replace the input service."
  provides: [input-service]
  (context-provide! ctx input-service (make-string-input (make-hash-table)) view: Input-service-view))

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

    (test-case "warm service cells follow one provider, ranks, aliases and withdrawal"
      (call-with-fresh-kernel []
        (lambda ()
          (let (alias (new-service 'greeter is-Greeter? tier: 'live doc: "Same slot."))
            (check (service-provider alias) => #f)
            (activate-plugin! greeter-a order: 1)
            (check (greeter-dispatch greeter-service) => "a")
            (set-plugin-order! greeter-a 3)
            (check (greeter-dispatch alias) => "a")
            (check (with-catch exception-summary (lambda () (activate-plugin! greeter-b)))
                   => "Service already has a provider greeter greeter-a greeter-b")
            (check (greeter-dispatch alias) => "a")
            (deactivate-plugin! greeter-a)
            (check (service-provider alias) => #f)
            (activate-plugin! greeter-b)
            (check (greeter-dispatch alias) => "b")))))

    (test-case "later hook registrations belong to the callback owner"
      (call-with-fresh-kernel []
        (lambda ()
          (defplugin (registering-hook ctx) "Registers an entry when its hook runs."
            (context-add-hook! ctx test-hook 'register
              (lambda (_) (context-add-entry! (current-context) table 'hook-slot 'owned))))
          (activate-plugin! registering-hook)
          (run-hook test-hook #f)
          (check (entry-owner (entry-table-ref table 'hook-slot)) => 'registering-hook)
          (deactivate-plugin! registering-hook)
          (check (entry-table-ref table 'hook-slot) => #f))))

    (test-case "warm cells clear the provider after failed activation"
      (call-with-fresh-kernel []
        (lambda ()
          (defplugin (cached-failure ctx) "Provides, warms dispatch, then fails."
            provides: [greeter-service]
            (context-provide! ctx greeter-service (make-greeter "bad") view: Greeter-service-view)
            (check (greeter-dispatch greeter-service) => "bad")
            (error "activation failed"))
          (check (with-catch exception-summary (lambda () (activate-plugin! cached-failure)))
                 => "activation failed")
          (check (plugin-active? cached-failure) => #f)
          (check (service-provider greeter-service) => #f)
          (activate-plugin! greeter-a)
          (check (greeting (service-provider greeter-service)) => "a")
          (check (current-context) => #f))))

    (test-case "service cells follow nested kernel selection"
      (call-with-fresh-kernel [greeter-a]
        (lambda ()
          (let (alias (new-service 'greeter is-Greeter? tier: 'live doc: "Same slot."))
            (check (greeter-dispatch alias) => "a")
            (call-with-fresh-kernel [greeter-b]
              (lambda ()
                (check (greeter-dispatch greeter-service) => "b")
                (check (greeter-dispatch alias) => "b")))
            (check (greeter-dispatch alias) => "a")
            (check (greeter-dispatch greeter-service) => "a")))))
    (test-case "optional services do not delay activation or create required dependents"
      (call-with-fresh-kernel []
        (lambda ()
          (defplugin (optional-user ctx) "Explicit guarded lookup."
            optional: [greeter-service]
            (note! (service-provider greeter-service)))
          (take-log!)
          (activate-plugin! optional-user)
          (check (take-log!) => [#f])
          (activate-plugin! greeter-a)
          (deactivate-plugin! greeter-a)
          (check (plugin-active? optional-user) => #t))))

    (test-case "kernel message uses a provider or stderr"
      (call-with-fresh-kernel []
        (lambda ()
          (defplugin (logging-owner ctx) "Uses the kernel message facility."
            (message "No Messages provider")
            (context-add-hook! ctx test-hook 'log (lambda (item) (message item))))
          (check (captured-output (lambda () (activate-plugin! logging-owner)))
                 => ["" "No Messages provider\n"])
          (activate-plugin! test-messages)
          (run-hook test-hook "A Messages provider")
          (check (current-message) => "A Messages provider"))))

    (test-case "a provider may use its own service"
      (call-with-fresh-kernel []
        (lambda ()
          (defplugin (self-user ctx) "Provides and uses Greeter."
            provides: [greeter-service]
            (context-provide! ctx greeter-service (make-greeter "self") view: Greeter-service-view)
            (note! (Greeter-greet (Greeter (service-provider greeter-service)))))
          (take-log!)
          (activate-plugin! self-user)
          (check (take-log!) => ["self"]))))

    (test-case "even the same owner cannot provide a service twice"
      (call-with-fresh-kernel []
        (lambda ()
          (defplugin (duplicate-provider ctx) "Registers twice."
            provides: [counter-service]
            (context-provide! ctx counter-service (Counter (counter name: 'old n: 17)) view: Counter-service-view)
            (context-provide! ctx counter-service (Counter (counter name: 'new n: 100)) view: Counter-service-view))
          (check (with-catch exception-summary (lambda () (activate-plugin! duplicate-provider)))
                 => "Service already has a provider counter duplicate-provider duplicate-provider")
          (check (service-provider counter-service) => #f))))


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

    (test-case "replacing entries and named hooks replaces their cleanup receipts"
      (call-with-fresh-kernel []
        (lambda ()
          (let ((owner #f)
                (other-table (new-entry-table))
                (other-hook (new-hook 'other)))
            (defplugin (replacing-owner ctx) "Replaces its registrations repeatedly."
              (set! owner ctx)
              (context-add-entry! ctx other-table 'slot 'other)
              (context-add-hook! ctx other-hook 'same (lambda () (void)))
              (for-each (lambda (n)
                          (context-add-entry! ctx table 'slot n)
                          (context-add-hook! ctx test-hook 'same (lambda (x) (note! [n x]))))
                        (iota 1000)))
            (activate-plugin! replacing-owner)
            (check (length (slot-ref owner 'receipt)) => 4)
            (check (slot-value) => 999)
            (check (length (entry-table-entries table 'slot)) => 1)
            (check (hook-callback-names test-hook) => '(same))
            (take-log!)
            (run-hook test-hook 'latest)
            (check (take-log!) => [[999 'latest]])
            (deactivate-plugin! replacing-owner)
            (check (slot-ref owner 'receipt) => [])
            (check (slot-value) => #f)
            (check (entry-table-ref other-table 'slot) => #f)
            (check (hook-callback-names test-hook) => [])
            (check (hook-callback-names other-hook) => [])))))

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

    (test-case "dependents wait for services and restart after provider teardown"
      (call-with-fresh-kernel []
        (lambda ()
          (take-log!)
          (activate-plugin! greeting-user)
          (check (plugin-active? greeting-user) => #f)
          (activate-plugin! greeter-a)
          (check (map plugin-name (plugin-deactivation-closure greeter-a)) => '(greeter-a greeting-user))
          (deactivate-plugin! greeter-a)
          (check (plugin-active? greeting-user) => #f)
          (activate-plugin! greeter-b)
          (check (take-log!) => '("a" off "b"))
          (check (plugin-active? greeting-user) => #t))))

    (test-case "hooks run by depth, drop a failing callback, and go with their plugin"
      (call-with-fresh-kernel []
       (lambda ()
         (take-log!)
         (activate-plugin! test-input)
         (activate-plugin! hooked)
         (check (hook-callback-names test-hook) => '(early broken late))
         (run-hook test-hook 1)
         (check (take-log!) => [['early 1] ['late 1]])
         (check (hook-callback-names test-hook) => '(early late))
         (check (string-prefix? "Hook test callback broken" (current-message)) => #t)
         (deactivate-plugin! hooked)
         (check (hook-callback-names test-hook) => '()))))

    (test-case "lifecycle events name the removed and new provider separately"
      (call-with-fresh-kernel []
        (lambda ()
          (activate-plugin! lifecycle-watcher)
          (activate-plugin! greeter-a)
          (activate-plugin! greeting-user)
          (take-log!)
          (deactivate-plugin! greeter-a)
          (check (take-log!) => '(off (deactivated greeting-user #f) (greeter "a" #f #t) (deactivated greeter-a #f)))
          (activate-plugin! greeter-b)
          (check (take-log!) => '("b" (greeter #f "b" #t) (activated greeter-b #t) (activated greeting-user #t))))))

    (test-case "a failed provider announces provision and withdrawal, without activating users"
      (call-with-fresh-kernel []
        (lambda ()
          (activate-plugin! lifecycle-watcher)
          (activate-plugin! greeting-user)
          (take-log!)
          (check-exception (activate-plugin! greeter-then-fails) Error?)
          (check (take-log!) => '((greeter #f "bad" #f) (greeter "bad" #f #t)))
          (check (plugin-active? greeting-user) => #f))))

    (test-case "a failing lifecycle callback is removed and activation carries on"
      (call-with-fresh-kernel []
       (lambda ()
         (activate-plugin! test-input)
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
         (activate-plugin! test-input)
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
         (activate-plugin! test-input)
         (check (map (lambda (info)
                       [(service-info-name info) (service-info-tier info)
                        (service-info-provider info) (service-info-dependents info)])
                     (describe-services))
                => [['greeter 'live 'greeter-a ['greeting-user]]
                    ['input 'startup 'test-input []]
                    ['messages 'live 'test-input []]]))))

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
           (activate-plugin! test-input)
           (activate-plugin! failing-undo)
           (check (captured-output (lambda () (deactivate-plugin! failing-undo)))
                  => ["" (string-append report "\n")])
           (check (current-message) => report)))))

    (test-case "startup tier is metadata, not a kernel teardown restriction"
      (call-with-fresh-kernel [test-input greeter-a]
        (lambda ()
          (start-editor-loop!)
          (check-exception (call-on-editor-loop (lambda () (activate-plugin! second-input))) Error?)
          (call-on-editor-loop (lambda () (deactivate-plugin! test-input)))
          (check (plugin-active? test-input) => #f)
          (call-on-editor-loop (lambda () (activate-plugin! second-input)))
          (check (plugin-active? second-input) => #t))))))

prelude: :gerbil/core
(import :std/test :std/interface :std/list/list
        :tuna/kernel :tuna/lib/advice
        (only-in :tuna/prelude advise! advice-for advised-functions advised-service-operations)
        :tuna/plugins/advice-help/plugin
        :tuna/plugins/commands/contract
        :tuna/plugins/completion/contract
        :tuna/plugins/help/contract
        "../../../../tuna/tests/support/kernel"
        "../../../commands/tests/support/toy-commands"
        "../support/service-fixture"
        (prefix-in "../support/target-a" a-)
        (prefix-in "../support/target-b" b-))
(export advice-help-test)

(def seen-table #f)
(def read-count 0)
(def choose (make-parameter
             (lambda ((table : completion-table))
               (candidate-value (car table.items)))))

(defclass inspection-completion () final: #t)
(implement Completion inspection-completion
  (completing-read (lambda (self question table require-match initial history default)
                     (check question => "Describe advice for target: ")
                     (check require-match => #t)
                     (set! read-count (fx1+ read-count))
                     (set! seen-table table)
                     ((choose) table)))
  (current-session (lambda (self) #f))
  (styles (lambda (self) (new-entry-table)))
  (annotators (lambda (self) (new-entry-table))))

(defclass inspection-help ((output :? help-output)) final: #t)
(implement Help inspection-help
  (show-help! (lambda (self output) (set! self.output output)))
  (current-help (lambda (self) self.output)))

(defplugin (inspection-providers ctx)
  "Completion and help captures; no buffers, minibuffer or renderer."
  provides: [completion-service help-service]
  (context-provide! ctx completion-service (Completion (inspection-completion)) view: Completion-service-view)
  (context-provide! ctx help-service (Help (inspection-help output: #f)) view: Help-service-view))

(def (with-inspection (advisors : :list) (body : :procedure)) => :t
  (set! seen-table #f)
  (set! read-count 0)
  (call-with-fresh-kernel (append [toy-commands inspection-providers advice-help] advisors) body))

(def (help-lines) => :list
  (check (help-output-title (current-help)) => "Advice")
  (help-output-lines (current-help)))

(def (candidate-kind (c : candidate)) => :symbol
  (advice-target-info-kind c.value))

(def (choose-kind (table : completion-table) (kind : :symbol)) => advice-target-info
  (candidate-value (find (lambda ((c : candidate)) (eq? (candidate-kind c) kind)) table.items)))

(def (registry-targets) => :list
  (append (advised-commands) (advised-service-operations)))

(def advice-help-test
  (test-suite "plugins/advice-help/plugin"
    (test-case "no advice shows useful help without prompting"
      (with-inspection []
        (lambda ()
          (call-command 'describe-advice)
          (check read-count => 0)
          (check seen-table => #f)
          (check (help-lines) => ["No advice is currently installed."]))))

    (test-case "selection shows target and every layer outermost first, with override warning"
      (defplugin (inner-owner ctx) "Inner observer."
        (advise! ctx a-probe 'inner after: (lambda (n) (void)) depth: 20))
      (defplugin (replacement-owner ctx) "Replacement."
        (advise! ctx a-probe 'replace override: (lambda (n) 100)))
      (defplugin (outer-owner ctx) "Outer observer."
        (advise! ctx a-probe 'outer around: (lambda (original n) (original n)) depth: -10))
      (with-inspection [inner-owner replacement-owner outer-owner]
        (lambda ()
          (call-command 'describe-advice)
          (check read-count => 1)
          (check (completion-table-category seen-table) => 'advice-target)
          (let* ((target (advice-for a-probe))
                 (source (advice-target-info-source target))
                 (records (advice-target-info-advice target))
                 (candidate (car (completion-table-items seen-table))))
            (check (map advice-info-name records) => '(outer replace inner))
            (check (string? source) => #t)
            (check (every (lambda ((record : advice-info)) (string? record.source)) records) => #t)
            (check (candidate-text candidate) => (string-append "Function: probe — " source))
            (check (eq? (candidate-key candidate) (advice-target-info-identity target)) => #t)
            (check (help-lines)
              => [(string-append "Function: probe")
                  (string-append "Source: " source)
                  "Advice layers (outermost first):"
                  (string-append "Owner: outer-owner  Name: outer  Kind: around  Depth: -10  Source: "
                                 (advice-info-source (car records)))
                  (string-append "Owner: replacement-owner  Name: replace  Kind: override  Depth: 0  Source: "
                                 (advice-info-source (cadr records)))
                  (string-append "Owner: inner-owner  Name: inner  Kind: after  Depth: 20  Source: "
                                 (advice-info-source (caddr records)))
                  "WARNING: override advice suppresses all inner advice and the original target."])
            (check (a-probe 1) => 100)))))

    (test-case "same-spelled functions have distinct labels, keys and selection values"
      (defplugin (twins ctx) "Two separate functions with one spelling."
        (advise! ctx a-probe 'from-a before: (lambda (n) (void)))
        (advise! ctx b-probe 'from-b before: (lambda (n) (void))))
      (with-inspection [twins]
        (lambda ()
          (for-each
           (lambda ((target : advice-target-info))
             (parameterize ((choose
                            (lambda ((table : completion-table))
                              (check (length table.items) => 2)
                              (let ((first (car table.items)) (second (cadr table.items)))
                                (check (equal? (candidate-text first) (candidate-text second)) => #f)
                                (check (equal? (candidate-key first) (candidate-key second)) => #f))
                              (candidate-value
                               (find (lambda ((c : candidate))
                                       (equal? (advice-target-info-source c.value) target.source))
                                     table.items)))))
               (call-command 'describe-advice)
               (check (cadr (help-lines)) => (string-append "Source: " target.source))
               (check (cadddr (help-lines))
                 => (string-append "Owner: twins  Name: "
                                   (if (equal? target.source (advice-target-info-source (advice-for a-probe)))
                                     "from-a" "from-b")
                                   "  Kind: before  Depth: 0  Source: "
                                   (advice-info-source (car target.advice))))))
           [(advice-for a-probe) (advice-for b-probe)]))))

    (test-case "advice removed while prompting is not rendered from the old snapshot"
      (defplugin (temporary-owner ctx) "Removed by the prompt double."
        (advise! ctx a-probe 'temporary override: (lambda (n) 100)))
      (with-inspection [temporary-owner]
        (lambda ()
          (let (source (advice-target-info-source (advice-for a-probe)))
            (parameterize ((choose (lambda ((table : completion-table))
                                     (deactivate-plugin! temporary-owner)
                                     (candidate-value (car table.items)))))
              (call-command 'describe-advice)
              (check (help-lines) => ["Function: probe" (string-append "Source: " source)
                                     "No advice is currently installed for this target."])
              (check (a-probe 1) => 2))))))

    (test-case "advice added while prompting is read after selection"
      (defplugin (first-owner ctx) "Initial observer."
        (advise! ctx a-probe 'first before: (lambda (n) (void))))
      (defplugin (new-owner ctx) "Observer added during the prompt."
        (advise! ctx a-probe 'new after: (lambda (n) (void)) depth: 10))
      (with-inspection [first-owner]
        (lambda ()
          (parameterize ((choose (lambda ((table : completion-table))
                                   (activate-plugin! new-owner)
                                   (candidate-value (car table.items)))))
            (call-command 'describe-advice)
            (let (record (cadr (advice-target-info-advice (advice-for a-probe))))
              (check (car (reverse (help-lines)))
                => (string-append "Owner: new-owner  Name: new  Kind: after  Depth: 10  Source: "
                                  (advice-info-source record))))))))

    (test-case "mixed pending targets retain opaque identities and distinguish kinds and function sources"
      (defplugin (mixed-owner ctx) "All kinds, without command definitions or a service provider."
        requires: [commands-service]
        (advise! ctx a-probe 'from-a before: (lambda (n) (void)))
        (advise! ctx b-probe 'from-b before: (lambda (n) (void)))
        (advise! ctx (command probe) 'command-layer before: void)
        (advise! ctx (service probe-service probe) 'service-layer before: void))
      (with-inspection [mixed-owner]
        (lambda ()
          (check (command-ref 'probe) => #f)
          (check (service-provider probe-service) => #f)
          (for-each
           (lambda ((target : advice-target-info))
             (parameterize ((choose
                             (lambda ((table : completion-table))
                               (check table.category => 'advice-target)
                               (check (length table.items) => 4)
                               (let (c (find (lambda ((c : candidate)) (eq? c.key target.identity)) table.items))
                                 (check (eq? (advice-target-info-identity (candidate-value c)) target.identity) => #t)
                                 (check (length (filter (lambda ((other : candidate))
                                                          (eq? other.key (candidate-key c))) table.items)) => 1)
                                 (check (length (filter (lambda ((other : candidate))
                                                          (equal? other.text (candidate-text c))) table.items)) => 1)
                                 (check (candidate-text c)
                                   => (string-append
                                        (case target.kind
                                          ((function) "Function: ") ((command) "Command: ")
                                          ((service) "Service operation: "))
                                        (symbol->string target.name) " — " (or target.source "unknown source")))
                                 (candidate-value c)))))
               (call-command 'describe-advice)
               (check (car (help-lines))
                 => (string-append (case target.kind
                                     ((function) "Function: ") ((command) "Command: ")
                                     ((service) "Service operation: "))
                                   (symbol->string target.name)))
               (check (cadr (help-lines)) => (string-append "Source: " (or target.source "unknown source")))
               (check (length (help-lines)) => 4)))
           (append (advised-functions) (registry-targets))))))

    (test-case "registry layers retain owner order, source and override warning without sorting by display name"
      (defplugin (inner-owner ctx) "Inner registry advice."
        requires: [commands-service]
        (advise! ctx (command probe) 'a-inner after: void depth: 20)
        (advise! ctx (service probe-service probe) 'a-inner after: void depth: 20))
      (defplugin (replacement-owner ctx) "Registry override."
        requires: [commands-service]
        (advise! ctx (command probe) 'm-replace override: (lambda () 100))
        (advise! ctx (service probe-service probe) 'm-replace override: (lambda () 100)))
      (defplugin (outer-owner ctx) "Outer registry advice."
        requires: [commands-service]
        (advise! ctx (command probe) 'z-outer before: void depth: -10)
        (advise! ctx (service probe-service probe) 'z-outer before: void depth: -10))
      (with-inspection [inspection-probe inner-owner replacement-owner outer-owner]
        (lambda ()
          (for-each
           (lambda (kind)
             (parameterize ((choose (lambda ((table : completion-table)) (choose-kind table kind))))
               (call-command 'describe-advice)
               (let* ((target (find (lambda ((target : advice-target-info)) (eq? target.kind kind)) (registry-targets)))
                      (records (advice-target-info-advice target)))
                 (check (map advice-info-name records) => '(z-outer m-replace a-inner))
                 (check (help-lines)
                   => [(if (eq? kind 'command) "Command: probe" "Service operation: inspection-probe/probe")
                       "Source: unknown source"
                       "Advice layers (outermost first):"
                       (string-append "Owner: outer-owner  Name: z-outer  Kind: before  Depth: -10  Source: "
                                      (advice-info-source (car records)))
                       (string-append "Owner: replacement-owner  Name: m-replace  Kind: override  Depth: 0  Source: "
                                      (advice-info-source (cadr records)))
                       (string-append "Owner: inner-owner  Name: a-inner  Kind: after  Depth: 20  Source: "
                                      (advice-info-source (caddr records)))
                       "WARNING: override advice suppresses all inner advice and the original target."]))))
           '(command service)))))

    (test-case "pending registry advice remains inspectable after its definition and provider retire"
      (defplugin (definitions ctx) "A removable command definition."
        requires: [commands-service]
        (define-command ctx (probe) "Fixture command." 7))
      (defplugin (pending-owner ctx) "Advice on absent definitions and missing operations."
        requires: [commands-service]
        (advise! ctx (command probe) 'pending before: void)
        (advise! ctx (service probe-service missing-operation) 'pending before: void))
      (with-inspection [definitions inspection-probe pending-owner]
        (lambda ()
          (check (call-command 'probe) => 7)
          (parameterize ((choose (lambda ((table : completion-table)) (choose-kind table 'service))))
            (call-command 'describe-advice)
            (check (car (help-lines)) => "Service operation: inspection-probe/missing-operation"))
          (deactivate-plugin! definitions)
          (deactivate-plugin! inspection-probe)
          (check (command-ref 'probe) => #f)
          (check (service-provider probe-service) => #f)
          (call-command 'describe-advice)
          (check (length (completion-table-items seen-table)) => 2)
          (check (length (help-lines)) => 4))))

    (test-case "registry selection after advisor cleanup is empty even when the same name is advised again"
      (defplugin (temporary-owner ctx) "Prompt removes this owner."
        requires: [commands-service]
        (advise! ctx (command probe) 'old override: (lambda () 100))
        (advise! ctx (service probe-service probe) 'old override: (lambda () 100)))
      (defplugin (replacement-owner ctx) "Same names, new target identities."
        requires: [commands-service]
        (advise! ctx (command probe) 'new before: void)
        (advise! ctx (service probe-service probe) 'new before: void))
      (for-each
       (lambda (kind)
         (with-inspection [temporary-owner]
           (lambda ()
             (parameterize ((choose
                             (lambda ((table : completion-table))
                               (let (selected (choose-kind table kind))
                                 (deactivate-plugin! temporary-owner)
                                 (activate-plugin! replacement-owner)
                                 selected))))
               (call-command 'describe-advice)
               (check (help-lines)
                 => [(if (eq? kind 'command) "Command: probe" "Service operation: inspection-probe/probe")
                     "Source: unknown source" "No advice is currently installed for this target."])
               (check (length (registry-targets)) => 2)))))
       '(command service)))

    (test-case "registry layers added during completion are read from the current owners"
      (defplugin (first-owner ctx) "Initial registry advice."
        requires: [commands-service]
        (advise! ctx (command probe) 'first before: void)
        (advise! ctx (service probe-service probe) 'first before: void))
      (defplugin (new-owner ctx) "Added during completion."
        requires: [commands-service]
        (advise! ctx (command probe) 'new after: void depth: 10)
        (advise! ctx (service probe-service probe) 'new after: void depth: 10))
      (for-each
       (lambda (kind)
         (with-inspection [first-owner]
           (lambda ()
             (parameterize ((choose (lambda ((table : completion-table))
                                     (activate-plugin! new-owner)
                                     (choose-kind table kind))))
               (call-command 'describe-advice)
               (let* ((target (find (lambda ((target : advice-target-info)) (eq? target.kind kind)) (registry-targets)))
                      (record (cadr (advice-target-info-advice target))))
                 (check (car (reverse (help-lines)))
                   => (string-append "Owner: new-owner  Name: new  Kind: after  Depth: 10  Source: "
                                     (advice-info-source record))))))))
       '(command service)))

    (test-case "functions remain module-wide while command and service candidates stay registry-local"
      (defplugin (scoped-owner ctx) "Advice in the outer registry."
        requires: [commands-service]
        (advise! ctx a-probe 'shared before: void)
        (advise! ctx (command probe) 'local before: void)
        (advise! ctx (service probe-service probe) 'local before: void))
      (with-inspection [scoped-owner]
        (lambda ()
          (check (length (registry-targets)) => 2)
          (call-with-fresh-kernel [toy-commands inspection-providers advice-help]
            (lambda ()
              (call-command 'describe-advice)
              (check (map candidate-kind (completion-table-items seen-table)) => '(function))
              (check (registry-targets) => [])))
          (call-command 'describe-advice)
          (check (length (completion-table-items seen-table)) => 3))))

    (test-case "deactivation removes only the inspection command, not another owner's advice"
      (defplugin (persistent-owner ctx) "Outlives the inspection plugin."
        requires: [commands-service]
        (advise! ctx a-probe 'persistent override: (lambda (n) 100))
        (advise! ctx (command probe) 'persistent override: (lambda () 100))
        (advise! ctx (service probe-service probe) 'persistent override: (lambda () 100)))
      (with-inspection [persistent-owner]
        (lambda ()
          (check (entry-owner (command-entry 'describe-advice)) => 'advice-help)
          (check (plugin-requires advice-help) => [commands-service completion-service help-service])
          (check (plugin-optional advice-help) => [completion-ui-service])
          (deactivate-plugin! advice-help)
          (check (command-ref 'describe-advice) => #f)
          (check (map advice-info-name (advice-target-info-advice (advice-for a-probe)))
                 => '(persistent))
          (check (a-probe 1) => 100)
          (check (length (registry-targets)) => 2)
          (check (map (lambda ((target : advice-target-info)) (map advice-info-name target.advice))
                      (registry-targets)) => '((persistent) (persistent)))
          (activate-plugin! advice-help)
          (call-command 'describe-advice)
          (check read-count => 1)))
      (check (a-probe 1) => 2))))

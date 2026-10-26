;;; describe-advice through the help plugin, with a stand-in for
;;; completion that records the table it is asked to choose from.
prelude: :gerbil/core
(import :std/test :std/interface :std/list/list
        :tuna/kernel :tuna/lib/advice
        (only-in :tuna/prelude advise! advice-for)
        :tuna/plugins/commands/contract
        :tuna/plugins/completion/contract
        :tuna/plugins/help/contract
        :tuna/plugins/keys/plugin
        :tuna/plugins/text-store/plugin
        :tuna/plugins/settings/plugin
        :tuna/plugins/buffers/plugin
        :tuna/plugins/layout/plugin
        :tuna/plugins/help/plugin
        "../../../../tuna/tests/support/kernel"
        "../../../commands/tests/support/toy-commands"
        "../../../session/tests/support/session"
        (prefix-in "../support/target-a" a-)
        (prefix-in "../support/target-b" b-))
(export describe-advice-test)

(def seen-table #f)
(def read-count 0)
(def choose (make-parameter
             (lambda ((table : completion-table))
               (candidate-value (car table.items)))))

(defclass inspection-completion () final: #t)
(implement Completion inspection-completion
  (completing-read (lambda (self question sources require-match initial history default setup)
                     (check question => "Describe advice for: ")
                     (check (length sources) => 1)
                     (check require-match => #t)
                     (set! read-count (fx1+ read-count))
                     (set! seen-table (car sources))
                     ((choose) (car sources))))
  (current-session (lambda (self) #f))
  (styles (lambda (self) (new-entry-table)))
  (annotators (lambda (self) (new-entry-table))))

(defplugin (inspection-completion-provider ctx)
  "Completion captures; no minibuffer or renderer."
  provides: [completion-service]
  (context-provide! ctx completion-service (Completion (inspection-completion))))

(def help-plugins
  [toy-commands keys rope-text-store settings no-session buffers layout
   inspection-completion-provider help])

(def (with-inspection (advisors : :list) (body : :procedure)) => :t
  (set! seen-table #f)
  (set! read-count 0)
  (call-with-fresh-kernel (append help-plugins advisors) body))

(def (help-lines) => :list
  (check (help-output-title (current-help)) => "Advice")
  (help-output-lines (current-help)))

(def describe-advice-test
  (test-suite "plugins/help/describe-advice"
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
            (check (candidate-key candidate) => (advice-target-info-target target))
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
                  "WARNING: override advice suppresses all inner advice and the original."])
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
                                     "No advice is currently installed."])
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

    (test-case "a command target shows the command and its current definition's source"
      (defplugin (greeting ctx) "Defines and advises a command." requires: [commands-service]
        (defcommand (greet) "Say hello." 'hello)
        (advise! ctx (command-target 'greet) 'loud filter-return: (lambda (word) 'HELLO)))
      (with-inspection [greeting]
        (lambda ()
          (call-command 'describe-advice)
          (let (source (entry-source (command-entry 'greet)))
            (check (string? source) => #t)
            (check (take (help-lines) 2)
                   => ["Command: greet" (string-append "Source: " source)])
            (check (call-command 'greet) => 'HELLO)))))

    (test-case "deactivation removes only the help plugin's command, not another owner's advice"
      (defplugin (persistent-owner ctx) "Outlives the inspection plugin."
        (advise! ctx a-probe 'persistent override: (lambda (n) 100)))
      (with-inspection [persistent-owner]
        (lambda ()
          (check (entry-owner (command-entry 'describe-advice)) => 'help)
          (check (plugin-optional help) => [completion-service completion-ui-service])
          (deactivate-plugin! help)
          (check (command-ref 'describe-advice) => #f)
          (check (map advice-info-name (advice-target-info-advice (advice-for a-probe)))
                 => '(persistent))
          (check (a-probe 1) => 100)
          (activate-plugin! help)
          (call-command 'describe-advice)
          (check read-count => 1)))
      (check (a-probe 1) => 2))))

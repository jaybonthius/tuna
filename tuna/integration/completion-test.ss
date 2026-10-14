;;; Behavior through real commands, prompt tasks, node clicks and redraws.
prelude: :gerbil/core
(import :tuna/services/commands
        :std/test :std/interface :tuna/kernel
        :tuna/services/keys :tuna/services/buffers :tuna/services/minibuffer
        :tuna/services/layout
        :tuna/services/completion :tuna/services/settings :tuna/services/renderer
        :tuna/plugins/commands :tuna/plugins/keys :tuna/plugins/rope
        :tuna/plugins/settings :tuna/plugins/buffers :tuna/plugins/layout
        :tuna/plugins/basic-editing :tuna/plugins/minibuffer :tuna/plugins/html-renderer
        :tuna/plugins/completion-engine :tuna/plugins/completion-vertical :tuna/plugins/extended-command
        :tuna/plugins/orderless :tuna/plugins/command-annotations
        "../test-support/kernel" "../test-support/keys" "../test-support/session"
        "../test-support/string-input" "../test-support/toy-completion-ui")
(export completion-test)

(def results [])
(def reads-table #f)
(def must-match? #t)
(def default-text #f)
(def annotations [])
(def redraws [])

(def (on-editor (thunk : :procedure)) => :t (call-on-editor-loop thunk))
(def (session) => (Maybe CompletionSession) (current-completion-session))
(def (texts) => :list (map candidate-text (CompletionSession-session-candidates (session))))
(def (prompt-nodes (kind : :symbol)) => :list
  (let (p (active-prompt))
    (if p
      (filter (lambda ((n : node)) (eq? (node-kind n) kind))
              (node-children (buffer-root (current-buffer)))) [])))
(def (row-nodes) => :list
  (let (lists (prompt-nodes 'completion-list))
    (if (null? lists) []
      (filter (lambda ((n : node)) (eq? (node-kind n) 'completion-row)) (node-children (car lists))))))
(def (row-texts) => :list
  (map (lambda ((n : node)) (candidate-text (node-attribute n 'candidate))) (row-nodes)))
(def (html) => :string (Renderer-render-screen (Renderer (service-provider renderer-service))))
(def (contains? (text : :string) (part : :string)) => :boolean (and (string-contains text part) #t))

(defclass completion-display () final: #t)
(defmethod {redisplay! completion-display}
  (lambda (self)
    (when (session)
      (set! redraws (cons [(CompletionSession-session-input (session)) (texts) (row-texts)] redraws)))))

(defplugin (fixture ctx)
  "Reads, commands and a redraw observer for completion integration tests."
  provides: [display-service]
  requires: [commands-service input-service completion-service minibuffer-service buffers-service]
  (context-provide! ctx display-service (completion-display))
  (define-command ctx (test-alpha) "An alpha action.\nMore details on the next line." (set! results (cons 'alpha results)))
  (define-command ctx (test-beta) "A beta action." (set! results (cons 'beta results)))
  (context-define-command! ctx 'test-hidden void visible?: (lambda (c origin) #f))
  (keymap-set "C-c a" 'test-alpha)
  (define-command ctx (fixture-read) "A configurable read."
    (set! results (cons (completing-read "Pick: " reads-table require-match: must-match?
                                       history: 'picks default: default-text) results)))
  (keymap-set "C-c f" 'fixture-read)
  (define-command ctx (fixture-nested) "Ask inside an existing prompt."
    (set! results (cons (completing-read "Inner: " (make-completion-table category: 'test
                                        items: (strings->candidates ["inner"]))) results)))
  (keymap-set "C-c n" 'fixture-nested))

(defplugin (count-two ctx)
  "Shows two rows."
  requires: [settings-service]
  (context-set-setting! ctx completion-count 2))

(defplugin (test-annotator ctx)
  "An annotator that records its buffer and only the shown candidates."
  requires: [completion-service buffers-service]
  (context-define-annotator! ctx 'test
    (lambda ((c : candidate))
      (set! annotations (cons [(candidate-text c) (buffer-name (current-buffer))] annotations))
      [(make-annotation-field "registered" 'doc)])))

(defplugin (test-style ctx)
  "A matching style and a category override."
  requires: [completion-service settings-service]
  (context-define-completion-style! ctx
    (make-completion-style 'only-beta
      (lambda (input) (lambda (text) (and (equal? text "beta") []))) "Only beta."))
  (context-set-setting! ctx completion-category-overrides '((test only-beta))))

(defplugin (orderless-default ctx)
  "Prefer Orderless, retaining substring if its plugin is removed."
  requires: [settings-service]
  (context-set-setting! ctx completion-styles '(orderless substring)))

(defplugin (origin-bindings ctx)
  "A local binding at the origin focus, not on the minibuffer."
  requires: [input-service buffers-service]
  (let* ((focus (or (view-node (selected-view)) (buffer-root (current-buffer))))
         (before (node-keymap focus))
         (map (new-keymap)))
    (set-node-keymap! focus map)
    (context-defer! ctx (lambda () (set-node-keymap! focus before)))
    (keymap-set-in ctx map "C-a" 'test-alpha)
    (keymap-set-in ctx map "C-c a" 'test-beta)))

(def completion-engine-plugins
  [commands-plugin keys-plugin test-messages-plugin rope-text-store-plugin settings-plugin no-session-plugin
   buffers-plugin layout-plugin basic-editing-plugin minibuffer-plugin html-renderer-plugin
   completion-engine-plugin extended-command-plugin fixture])

(def (run-completion (ui :? plugin) (thunk : :procedure)) => :t
  (set! results []) (set! annotations []) (set! redraws [])
  (set! must-match? #t) (set! default-text #f)
  (set! reads-table (make-completion-table category: 'test items: (strings->candidates ["alpha" "beta" "gamma"])))
  (call-with-fresh-kernel completion-engine-plugins
    (lambda () (when ui (activate-plugin! ui)) (start-editor-loop!) (thunk))))

(def completion-test
  (test-suite "completion integration"
    (test-case "Orderless M-x highlights every component and command rows show key and first doc line"
      (run-completion completion-vertical-plugin
        (lambda ()
          (on-editor (lambda () (activate-plugin! orderless-default) (activate-plugin! orderless-plugin)
                                (activate-plugin! annotations-plugin) (activate-plugin! origin-bindings)))
          (type! "M-x" "a" "l" "p" "h" "a" "SPC" "t" "e" "s" "t")
          (check (on-editor texts) => ["test-alpha"])
          (check (on-editor (lambda ()
            (let (fields (node-attribute (car (row-nodes)) 'annotations))
              (map (lambda ((field : annotation-field)) [(annotation-field-class field) (annotation-field-text field)])
                   fields)))) => [['key "C-a"] ['doc "An alpha action."]])
          (check (on-editor (lambda () (contains? (html) "<mark>test</mark>-<mark>alpha</mark>"))) => #t)
          (check (on-editor (lambda () (contains? (html) "completion-doc"))) => #t)
          (check (on-editor (lambda () (contains? (html) "More details"))) => #f)
          (type! "RET")
          (check (on-editor session) => #f)
          (check results => ['alpha]))))
    (test-case "removing annotations restores M-x key-only fallback; removing Orderless restores substring"
      (run-completion completion-vertical-plugin
        (lambda ()
          (on-editor (lambda () (activate-plugin! orderless-default) (activate-plugin! orderless-plugin)
                                (activate-plugin! annotations-plugin)))
          (type! "M-x" "a" "l" "p" "h" "a")
          (check (on-editor (lambda () (contains? (html) "An alpha action."))) => #t)
          (type! "C-g")
          (on-editor (lambda () (deactivate-plugin! annotations-plugin)))
          (type! "M-x" "a" "l" "p" "h" "a" "SPC" "t" "e" "s" "t")
          (check (on-editor texts) => ["test-alpha"])
          (check (on-editor (lambda ()
            (map annotation-field-class (node-attribute (car (row-nodes)) 'annotations)))) => ['key])
          (check (on-editor (lambda () (contains? (html) "C-c a"))) => #t)
          (type! "RET")
          (check (on-editor session) => #f)
          (check results => ['alpha])
          (on-editor (lambda () (deactivate-plugin! orderless-plugin)))
          (type! "M-x" "a" "l" "p" "h" "a" "SPC" "t" "e" "s" "t")
          (check (on-editor texts) => [])
          (type! "C-g" "M-x" "a" "l" "p" "h" "a" "RET")
          (check (on-editor session) => #f)
          (check results => ['alpha 'alpha]))))
    (test-case "Orderless and annotations remain optional with no list: plain M-x runs an exact name"
      (run-completion #f
        (lambda ()
          (on-editor (lambda () (activate-plugin! orderless-default) (activate-plugin! orderless-plugin)
                                (activate-plugin! annotations-plugin)))
          (type! "M-x" "t" "e" "s" "t" "-" "a" "l" "p" "h" "a")
          (check (on-editor row-texts) => [])
          (check (on-editor (lambda () (contains? (html) "completion-doc"))) => #f)
          (type! "RET")
          (check (on-editor session) => #f)
          (check results => ['alpha])
          (check (on-editor session) => #f))))
    (test-case "annotators for unrelated categories are never called"
      (run-completion completion-vertical-plugin
        (lambda ()
          (on-editor (lambda () (activate-plugin! test-annotator) (activate-plugin! annotations-plugin)
            (set! reads-table (make-completion-table category: 'unknown
              items: [(make-candidate text: "test-alpha" value: 'test-alpha key: 'test-alpha)]))))
          (type! "C-c" "f")
          (check annotations => [])
          (check (on-editor (lambda () (node-attribute (car (row-nodes)) 'annotations))) => [])
          (type! "RET")
          (check (on-editor session) => #f)
          (check results => ['test-alpha]))))
    (test-case "M-x: visibility, same-redraw matches, navigate, run and recency history"
      (run-completion completion-vertical-plugin
        (lambda ()
          (type! "M-x" "t" "e" "s" "t" "-")
          (check (on-editor texts) => ["test-beta" "test-alpha"])
          (check (on-editor (lambda () (contains? (html) "C-c a"))) => #t)
          (check (on-editor (lambda () (contains? (html) "<mark>test-</mark>"))) => #t)
          (check (wait-until (lambda () (member ["test-" ["test-beta" "test-alpha"]
                                                     ["test-beta" "test-alpha"]] redraws))) => #t)
          (type! "<down>" "RET")
          (check (on-editor session) => #f)
          (check results => ['alpha])
          (check (on-editor last-command) => 'test-alpha)
          (check (on-editor (lambda () (minibuffer-history 'extended-command))) => ["test-alpha"])
          (type! "M-x" "t" "e" "s" "t" "-")
          (check (on-editor texts) => ["test-alpha" "test-beta"])
          (type! "C-g")
          (check (on-editor (lambda () (minibuffer-history 'extended-command))) => ["test-alpha"]))))
    (test-case "keys, editing, prompts and completion work without optional messages"
      (run-completion completion-vertical-plugin
        (lambda ()
          (on-editor (lambda () (deactivate-plugin! test-messages-plugin)
                                (check (service-provider messages-service) => #f)))
          (type! "M-x" "t" "e" "s" "t" "-" "a" "l" "p" "h" "a" "RET")
          (check (on-editor session) => #f)
          (check results => ['alpha])
          (type! "C-c" "f" "b")
          (check (on-editor row-texts) => ["beta"])
          (type! "RET")
          (check (on-editor session) => #f)
          (check results => ["beta" 'alpha]))))
    (test-case "without a UI, RET validates an exact name and M-x still runs"
      (run-completion #f
        (lambda ()
          (type! "M-x" "t" "e" "s" "t" "-" "RET")
          (check (on-editor (lambda () (CompletionSession-session-input (session)))) => "test-")
          (check (on-editor (lambda () (minibuffer-history 'extended-command))) => [])
          (check (on-editor row-texts) => [])
          (type! "b" "e" "t" "a" "RET")
          (check (on-editor session) => #f)
          (check results => ['beta])
          (check (on-editor (lambda () (minibuffer-history 'extended-command))) => ["test-beta"]))))
    (test-case "click a row, stale row identity cannot choose a replacement"
      (run-completion completion-vertical-plugin
        (lambda ()
          (type! "C-c" "f")
          (let (ids (on-editor (lambda () [(view-id (selected-view)) (node-id (cadr (row-nodes)))])))
            (on-editor (lambda () (select-view (find (lambda (v) (equal? (buffer-name (view-showing v)) "*scratch*"))
                                                    (view-list)))))
            (click 'view (car ids) node: (cadr ids))
            (check (on-editor session) => #f)
            (check results => ["alpha"])
            (type! "C-c" "f")
            (click 'view (car ids) node: (cadr ids))
            (check (on-editor (lambda () (and (session) #t))) => #t)
            (check results => ["alpha"])
            (type! "C-g")))))
    (test-case "UI off during a read removes nodes and restores plain RET; toy UI swaps in"
      (run-completion completion-vertical-plugin
        (lambda ()
          (type! "C-c" "f" "b")
          (check (on-editor row-texts) => ["beta"])
          (on-editor (lambda () (deactivate-plugin! completion-vertical-plugin)))
          (check (on-editor row-texts) => [])
          (type! "RET")
          (check (on-editor (lambda () (and (session) #t))) => #t)
          (on-editor (lambda () (activate-plugin! toy-completion-ui-plugin)))
          (type! "e")
          (check (on-editor (lambda () (node-text-projection (car (prompt-nodes 'toy-completion-summary)))))
                 => "Toy UI: 1 choices; be")
          (type! "RET")
          (check (on-editor session) => #f)
          (check results => ["beta"])
          (on-editor (lambda () (deactivate-plugin! toy-completion-ui-plugin)
                                 (activate-plugin! completion-vertical-plugin)))
          (type! "C-c" "f")
          (check (on-editor (lambda () (pair? (row-nodes)))) => #t)
          (type! "C-g"))))
    (test-case "records return values, selection stays by key across fresh source records"
      (run-completion completion-vertical-plugin
        (lambda ()
          (on-editor (lambda ()
            (set! reads-table (make-completion-table category: 'test sort: values
              items: (lambda (input)
                       [(make-candidate text: "car" value: 1 key: 'a)
                        (make-candidate text: "car" value: 2 key: 'b)])))))
          (type! "C-c" "f" "C-n" "c" "a")
          (check (on-editor (lambda () (candidate-key (CompletionSession-session-selected (session))))) => 'b)
          (type! "RET")
          (check (on-editor session) => #f)
          (check results => [2])
          (check (on-editor (lambda () (minibuffer-history 'picks))) => ["car"]))))
    (test-case "configuration selects one UI at a time"
      (run-completion completion-vertical-plugin
        (lambda ()
          (type! "C-c" "f" "b")
          (on-editor (lambda () (deactivate-plugin! completion-vertical-plugin)
                                 (activate-plugin! toy-completion-ui-plugin)))
          (check (on-editor row-texts) => [])
          (check (on-editor (lambda () (length (prompt-nodes 'toy-completion-summary)))) => 1)
          (on-editor (lambda () (deactivate-plugin! toy-completion-ui-plugin)
                                 (activate-plugin! completion-vertical-plugin)))
          (check (on-editor row-texts) => ["beta"])
          (check (on-editor (lambda () (prompt-nodes 'toy-completion-summary))) => [])
          (type! "RET")
          (check (on-editor session) => #f)
          (check results => ["beta"]))))
    (test-case "M-RET takes literal input when allowed; required matches and defaults validate"
      (run-completion completion-vertical-plugin
        (lambda ()
          (on-editor (lambda () (set! must-match? #f)
             (set! reads-table (make-completion-table category: 'test
               items: [(make-candidate text: "beta" value: 42 key: 'b)]))))
          (type! "C-c" "f" "b" "e" "t" "a" "M-RET")
          (check (on-editor session) => #f)
          (check results => ["beta"])
          (on-editor (lambda () (set! must-match? #t)))
          (type! "C-c" "f" "z" "M-RET")
          (check (on-editor (lambda () (CompletionSession-session-input (session)))) => "z")
          (type! "C-g")
          (on-editor (lambda () (set! default-text "beta")))
          (type! "C-c" "f" "M-RET")
          (check (on-editor session) => #f)
          (check results => [42 "beta"]))))
    (test-case "TAB inserts selected text; first/last and up/down clamp at edges"
      (run-completion completion-vertical-plugin
        (lambda ()
          (type! "C-c" "f" "M->")
          (check (on-editor (lambda () (candidate-text (CompletionSession-session-selected (session))))) => "gamma")
          (type! "M-<" "<up>")
          (check (on-editor (lambda () (candidate-text (CompletionSession-session-selected (session))))) => "beta")
          ;; The test transport uses a browser key-event, not a native command.
          (press "Tab")
          (check (on-editor (lambda () (CompletionSession-session-input (session)))) => "beta")
          (type! "RET")
          (check (on-editor session) => #f)
          (check results => ["beta"]))))
    (test-case "only visible rows are annotated, registry before fallback, in the origin buffer"
      (run-completion completion-vertical-plugin
        (lambda ()
          (on-editor (lambda () (activate-plugin! count-two) (activate-plugin! test-annotator)
            (set! reads-table (make-completion-table category: 'test
              items: (strings->candidates ["a" "b" "c" "d"])
              annotate: (lambda (c) [(make-annotation-field "fallback" 'key)])))))
          (type! "C-c" "f")
          (check (on-editor (lambda () annotations)) => [["b" "*scratch*"] ["a" "*scratch*"]])
          (check (on-editor (lambda () (contains? (html) "registered"))) => #t)
          (check (on-editor (lambda () (contains? (html) "fallback"))) => #f)
          (on-editor (lambda () (deactivate-plugin! test-annotator)))
          (type! "C-n")
          (check (on-editor (lambda () (contains? (html) "fallback"))) => #t)
          (type! "C-g"))))
    (test-case "category style overrides use the registry; removing a style falls back to substring"
      (run-completion completion-vertical-plugin
        (lambda ()
          (on-editor (lambda () (activate-plugin! test-style)))
          (type! "C-c" "f")
          (check (on-editor texts) => ["beta"])
          (on-editor (lambda () (deactivate-plugin! test-style)))
          (type! "a")
          (check (on-editor texts) => ["beta" "alpha" "gamma"])
          (type! "C-g"))))
    (test-case "nested reads have independent sessions and restore the outer selection and rows"
      (run-completion completion-vertical-plugin
        (lambda ()
          (type! "C-c" "f" "C-n")
          (let (outer (on-editor session))
            (check (on-editor (lambda () (CompletionSession-session-command outer))) => 'fixture-read)
            (type! "C-c" "n")
            (check (on-editor (lambda () (eq? outer (session)))) => #f)
            (check (on-editor texts) => ["inner"])
            (type! "RET")
            (check (on-editor session) => outer)
            (check (on-editor row-texts) => ["beta" "alpha" "gamma"])
            (check (on-editor (lambda () (candidate-text (CompletionSession-session-selected outer)))) => "alpha")
            (type! "RET")
            (check (on-editor session) => #f)
            (check results => ["alpha" "inner"])))))))

#lang :tuna/prelude
;;; M-x is a command over the public commands/completion contracts.
(import :tuna/plugins/commands/contract
        :tuna/kernel :tuna/plugins/keys/contract :tuna/plugins/buffers/contract :tuna/plugins/completion/contract)
(export extended-command)

(def (visible-command-candidates (origin : buffer)) => :list
  (filter-map (lambda ((name : :symbol))
                (let (c (command-ref name))
                  (and c ((command-visible? c) c origin)
                       (make-candidate text: (symbol->string name) value: name key: name))))
              (command-names)))

(def (command-binding (c : candidate) (focus : node)) => :list
  (let (keys (where-is (candidate-value c) focus))
    (if (null? keys) [] [(make-annotation-field (car keys) 'key)])))

(defplugin (extended-command ctx)
  "M-x: choose and run a visible command, remembering recent choices."
  requires: [commands-service completion-service input-service buffers-service]
  optional: [completion-ui-service]
  (define-command ctx (execute-extended-command) "Choose a command by name, then run it as if its keys were pressed."
    (let* ((origin (current-buffer))
           (focus (or (view-node (selected-view)) (buffer-root origin)))
           (table (make-completion-table category: 'command
                    items: (lambda (input) (visible-command-candidates origin))
                    annotate: (lambda ((c : candidate)) (command-binding c focus))))
           (choice (completing-read "M-x " table history: 'extended-command)))
      (call-command choice)))
  (keymap-set "M-x" 'execute-extended-command))

;;; Category annotators add typed fields, independent of the completion UI.
prelude: :gerbil/core
(import :tuna/plugins/commands/contract
        :tuna/kernel :tuna/plugins/completion/contract :tuna/plugins/keys/contract
        :tuna/plugins/buffers/contract)
(export annotations)

;; The engine supplies the session's origin selected-view snapshot, including
;; its focused node; looking at the prompt's maps would hide local bindings.
(def (annotate-command (c : candidate)) => (Maybe :list)
  (let* ((name (candidate-value c))
         (command (and (symbol? name) (command-ref name))))
    (and command
         (let* ((focus (or (view-node (selected-view)) (buffer-root (current-buffer))))
                (keys (where-is name focus))
                (doc (command-doc command))
                (end (or (string-index doc #\newline) (string-length doc))))
           [(make-annotation-field (if (null? keys) "" (car keys)) 'key)
            (make-annotation-field (substring doc 0 end) 'doc)]))))

(defplugin (annotations ctx)
  "Command key bindings and first-line documentation beside completion candidates."
  requires: [completion-service commands-service input-service buffers-service]
  (context-define-annotator! ctx 'command annotate-command))

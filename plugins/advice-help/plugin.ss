#lang :tuna/prelude
;;; Function advice inspection, independent of the help/completion providers.
(import :std/list/list
        :tuna/kernel
        :tuna/plugins/commands/contract
        :tuna/plugins/completion/contract
        :tuna/plugins/help/contract)
(export advice-help)

(def (function-label (target : function-advice-info)) => :string
  (string-append (symbol->string target.name) " — " (or target.source "unknown source")))

(def (advice-line (record : advice-info)) => :string
  (string-append "Owner: " (symbol->string record.owner)
                 "  Name: " (symbol->string record.name)
                 "  Kind: " (symbol->string record.kind)
                 "  Depth: " (number->string record.depth)
                 "  Source: " (or record.source "unknown source")))

(def (function-description (selected : function-advice-info)) => :list
  ;; A prompt yields: use its name/source identity, never its old advice snapshot.
  (let* ((current (find (lambda ((target : function-advice-info))
                          (and (eq? target.name selected.name)
                               (equal? target.source selected.source)))
                        (advised-functions)))
         (records (if current (function-advice-info-advice current) [])))
    (append [ (string-append "Function: " (symbol->string selected.name))
              (string-append "Source: " (or selected.source "unknown source")) ]
      (if (null? records)
        ["No advice is currently installed for this function."]
        (append ["Advice layers (outermost first):"]
                (map advice-line records)
                (if (ormap (lambda ((record : advice-info)) (eq? record.kind 'override)) records)
                  ["WARNING: override advice suppresses all inner advice and the original function."]
                  []))))))

(defplugin (advice-help ctx)
  "Inspect the advice currently wrapping a package function."
  requires: [commands-service completion-service help-service]
  optional: [completion-ui-service]
  (define-command ctx (describe-advice) "Choose an advised function and show its current advice, outermost first."
    (let (targets (advised-functions))
      (if (null? targets)
        (show-help "Function advice" ["No function advice is currently installed."])
        (let* ((table (make-completion-table category: 'function-advice
                        items: (map (lambda ((target : function-advice-info))
                                      (make-candidate text: (function-label target) value: target
                                                      key: (cons target.name target.source)))
                                    targets)))
               (selected (: (completing-read "Describe advice for function: " table) function-advice-info)))
          (show-help "Function advice" (function-description selected)))))))

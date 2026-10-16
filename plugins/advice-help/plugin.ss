#lang :tuna/prelude
;;; Advice inspection, independent of the help/completion providers.
(import :std/list/list
        :tuna/kernel
        :tuna/plugins/commands/contract
        :tuna/plugins/completion/contract
        :tuna/plugins/help/contract)
(export advice-help)

(def (advised-targets) => :list
  (append (advised-functions) (advised-commands) (advised-service-operations)))

(def (target-heading (target : advice-target-info)) => :string
  (string-append (case target.kind
                   ((function) "Function: ")
                   ((command) "Command: ")
                   ((service) "Service operation: "))
                 (symbol->string target.name)))

(def (target-label (target : advice-target-info)) => :string
  (string-append (target-heading target) " — " (or target.source "unknown source")))

(def (advice-line (record : advice-info)) => :string
  (string-append "Owner: " (symbol->string record.owner)
                 "  Name: " (symbol->string record.name)
                 "  Kind: " (symbol->string record.kind)
                 "  Depth: " (number->string record.depth)
                 "  Source: " (or record.source "unknown source")))

(def (target-description (selected : advice-target-info)) => :list
  ;; A prompt yields: requery all owners by identity, never the old advice snapshot.
  (let* ((current (find (lambda ((target : advice-target-info))
                          (eq? target.identity selected.identity))
                        (advised-targets)))
         (target (: (or current selected) advice-target-info))
         (records (if current (advice-target-info-advice current) [])))
    (append [ (target-heading target)
              (string-append "Source: " (or (advice-target-info-source target) "unknown source")) ]
      (if (null? records)
        ["No advice is currently installed for this target."]
        (append ["Advice layers (outermost first):"]
                (map advice-line records)
                (if (ormap (lambda ((record : advice-info)) (eq? record.kind 'override)) records)
                  ["WARNING: override advice suppresses all inner advice and the original target."]
                  []))))))

(defplugin (advice-help ctx)
  "Inspect advice on functions, commands and service operations."
  requires: [commands-service completion-service help-service]
  optional: [completion-ui-service]
  (define-command ctx (describe-advice) "Choose an advised target and show its current advice, outermost first."
    (let (targets (advised-targets))
      (if (null? targets)
        (show-help "Advice" ["No advice is currently installed."])
        (let* ((table (make-completion-table category: 'advice-target
                        items: (map (lambda ((target : advice-target-info))
                                      (make-candidate text: (target-label target) value: target
                                                      key: target.identity))
                                    targets)))
               (selected (: (completing-read "Describe advice for target: " table) advice-target-info)))
          (show-help "Advice" (target-description selected)))))))

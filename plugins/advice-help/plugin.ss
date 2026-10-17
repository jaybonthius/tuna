#lang :tuna/prelude
;;; Advice inspection, independent of the help/completion providers.
(import :std/list/list
        :tuna/kernel
        :tuna/plugins/commands/contract
        :tuna/plugins/completion/contract
        :tuna/plugins/help/contract)
(export advice-help)

(def (target-heading (info : advice-target-info)) => :string
  (string-append (case info.kind
                   ((function) "Function: ")
                   ((command) "Command: ")
                   (else (string-append (symbol->string info.kind) ": ")))
                 (symbol->string info.name)))

;; A command target describes a name, so its source is the current definition's.
(def (target-source (info : advice-target-info)) => (Maybe :string)
  (or info.source
      (and (eq? info.kind 'command)
           (let (e (command-entry info.name)) (and e (entry-source e))))))

(def (target-label (info : advice-target-info)) => :string
  (string-append (target-heading info) " — " (or (target-source info) "unknown source")))

(def (advice-line (record : advice-info)) => :string
  (string-append "Owner: " (symbol->string record.owner)
                 "  Name: " (symbol->string record.name)
                 "  Kind: " (symbol->string record.kind)
                 "  Depth: " (number->string record.depth)
                 "  Source: " (or record.source "unknown source")))

(def (target-description (selected : advice-target-info)) => :list
  ;; A prompt yields: describe the target's advice now, not the old snapshot.
  (let (records (advice-target-records (advice-target-info-target selected)))
    (append [ (target-heading selected)
              (string-append "Source: " (or (target-source selected) "unknown source")) ]
      (if (null? records)
        ["No advice is currently installed."]
        (append ["Advice layers (outermost first):"]
                (map advice-line records)
                (if (ormap (lambda ((record : advice-info)) (eq? record.kind 'override)) records)
                  ["WARNING: override advice suppresses all inner advice and the original."]
                  []))))))

(defplugin (advice-help ctx)
  "Inspect the advice currently wrapping functions and commands."
  requires: [commands-service completion-service help-service]
  optional: [completion-ui-service]
  (define-command ctx (describe-advice) "Choose an advised function or command and show its advice, outermost first."
    (let (targets (advised-targets))
      (if (null? targets)
        (show-help "Advice" ["No advice is currently installed."])
        (let* ((table (make-completion-table category: 'advice-target
                        items: (map (lambda ((info : advice-target-info))
                                      (make-candidate text: (target-label info) value: info
                                                      key: (advice-target-info-target info)))
                                    targets)))
               (selected (: (completing-read "Describe advice for: " table) advice-target-info)))
          (show-help "Advice" (target-description selected)))))))

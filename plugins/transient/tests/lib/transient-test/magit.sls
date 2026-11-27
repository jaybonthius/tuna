#!tuna
(import (transient) (commands) (keys) (minibuffer) (options))

(options:define-option merge-arguments '() (lambda (v) (and (list? v) (for-all string? v)))
  "The arguments the merge menu starts with.")

(transient:define-menu merge-menu "Git's merge menu."
  (title "Merge")
  (arguments merge-arguments)
  (incompatible ("--ff-only" "--no-ff")))

(define %merges '())

(define (merges) %merges)

(commands:define-command (merge-branch [arguments (transient:arguments merge-menu)])
  "Merges a branch into the current one with ARGUMENTS."
  (set! %merges (cons arguments %merges)))

(commands:define-command (merge)
  "Shows the merge menu."
  (transient:show! merge-menu))

(transient:add! merge-menu "Arguments"
  (transient:switch "- f" "Fast-forward only" "--ff-only")
  (transient:switch "- n" "No fast-forward" "--no-ff")
  (transient:valued-switch "- s" "Strategy" "--strategy=" minibuffer:read))
(transient:add! merge-menu "Actions"
  (transient:command "m" "Merge" merge-branch))
(keys:bind! keys:global "C-c m" merge)

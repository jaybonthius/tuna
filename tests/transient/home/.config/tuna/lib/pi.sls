#!tuna
(import (transient) (commands) (keys) (tables))

(define-record-type chat (fields name (mutable model)))

(define the-chat (make-chat "notes" "sonnet"))

(define (current-chat) the-chat)

(define %auto-compact #f)

(define (auto-compact?) %auto-compact)

(define-record-type template (fields name))

(define templates (list (make-template "Review") (make-template "Explain")))

(define (chat-templates) templates)

(define %ran '())

(define (ran) %ran)

(define (note! what) (set! %ran (cons what %ran)))

(commands:define-command (new-session) "Starts a session." (note! 'new))
(commands:define-command (resume-session) "Resumes a session." (note! 'resume))
(commands:define-command (rename-session) "Renames the session." (note! 'rename))
(commands:define-command (select-model) "Selects a model." (chat-model-set! the-chat "opus") (note! 'model))
(commands:define-command (toggle-auto-compact) "Toggles auto-compaction." (set! %auto-compact (not %auto-compact)))
(commands:define-command (run-template [t #f]) "Runs a template." (note! (template-name t)))

(tables:define-table keymap "The chat's keys.")

(transient:define-menu menu "The chat menu."
  (title (lambda () (string-append "Pi, " (chat-name (current-chat))))))

(define (model-description)
  (string-append "Model (" (chat-model (current-chat)) ")"))

(transient:define-menu templates-menu "The chat's templates.")

(commands:define-command (show-menu)
  "Shows the chat menu."
  (transient:show! menu))

(transient:add! menu "Session"
  (transient:command "n" "New" new-session)
  (transient:command "r" "Resume" resume-session)
  (transient:command "N" "Rename" rename-session))
(transient:add! menu "Model"
  (transient:command "m" model-description select-model)
  (transient:staying-command "a" (lambda () (if (auto-compact?) "Auto-compact (on)" "Auto-compact (off)"))
                             toggle-auto-compact))

(transient:add-computed! templates-menu "Templates"
  (lambda ()
    (let* ([letters (string->list "abcdefghijklmnopqrstuvwxyz")]
           [templates (chat-templates)]
           [shown (list-head templates (min (length templates) (length letters)))])
      (map (lambda (template letter)
             (transient:command (string letter) (template-name template) run-template template))
           shown (list-head letters (length shown))))))

(keys:bind! keymap "C-c C-p" show-menu)

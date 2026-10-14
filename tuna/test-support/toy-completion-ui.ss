;;; A deliberately different UI: one text summary, no candidate rows.
prelude: :gerbil/core
(import :tuna/services/commands
        :std/interface (only-in :gerbil/runtime/hash HashTable)
        :tuna/kernel :tuna/services/keys :tuna/services/buffers
        :tuna/services/minibuffer :tuna/services/completion)
(export toy-completion-ui-plugin)

(defclass toy-completion-ui ((shown : HashTable) (keymap : entry-table)) final: #t)

(implement CompletionUI toy-completion-ui
  (present (lambda (self session prompt)
    (let* ((b (prompt-buffer prompt)) (root (buffer-root b))
           (kept (or (hash-get self.shown b)
                     (let* ((answer (prompt-answer-node prompt))
                            (summary (new-node 'toy-completion-summary))
                            (fresh [summary answer (node-keymap answer)]))
                       (set-node-keymap! answer self.keymap)
                       (set-node-children! root (append (node-children root) [summary]))
                       (hash-put! self.shown b fresh)
                       fresh))))
      (set-node-attribute! (car kept) 'content
        (string-append "Toy UI: " (number->string (length (CompletionSession-session-candidates session)))
                       " choices; " (CompletionSession-session-input session)))))))

(defplugin (toy-completion-ui-plugin ctx)
  "A one-line test completion UI, proving presentation is replaceable."
  provides: [completion-ui-service]
  requires: [commands-service completion-service input-service buffers-service]
  (context-define-node-kind! ctx 'toy-completion-summary project: (lambda (n) (node-attribute n 'content)))
  (let (self (toy-completion-ui shown: (make-hash-table-eq) keymap: (new-keymap)))
    (context-define-command! ctx 'toy-completion-select
      (lambda () (CompletionSession-session-exit! (current-completion-session) #f))
      visible?: (lambda (c origin) #f))
    (keymap-set-in ctx (toy-completion-ui-keymap self) "RET" 'toy-completion-select)
    (keymap-set-in ctx (toy-completion-ui-keymap self) "M-RET" 'completion-accept-input)
    (context-add-hook! ctx kill-buffer-hook 'toy-completion-ui
      (lambda (b) (hash-remove! (toy-completion-ui-shown self) b)))
    (let ((provider (CompletionUI self))
          (clear! (lambda ()
                    (hash-for-each
                      (lambda (b kept)
                        (when (memq b (buffer-list))
                          (let (root (buffer-root b))
                            (set-node-children! root (remq (car kept) (node-children root)))
                            (when (eq? (node-keymap (cadr kept)) (toy-completion-ui-keymap self))
                              (set-node-keymap! (cadr kept) (caddr kept))))))
                      (toy-completion-ui-shown self))
                    (hash-clear! (toy-completion-ui-shown self)))))
      (context-add-hook! ctx service-changed-hook 'toy-completion-ui
        (lambda (svc outgoing incoming)
          (when (and (eq? svc completion-ui-service) (eq? outgoing provider)) (clear!)))
        depth: -10)
      (context-defer! ctx clear!)
      (context-provide! ctx completion-ui-service provider))))

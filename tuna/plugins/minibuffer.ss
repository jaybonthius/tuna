#lang :tuna/prelude
;;; The minibuffer (live tier). Each prompt gets its own internal buffer
;;; holding one text node, a view pushed as the focus view, so basic
;;; editing types into the answer, and an input target whose keymap binds
;;; RET and C-g. Prompts nest: only the innermost receives keys, and
;;; answers are delivered innermost first.
(import :std/interface
        :tuna/kernel
        :tuna/services/keys
        :tuna/services/buffers
        :tuna/services/minibuffer)
(export minibuffer-plugin)

(defclass prompt ((question : :string)
                  (answer   : node)            ; the text node holding the answer
                  (holder   : buffer)          ; its internal buffer
                  (focus    : view)            ; its focus view while it waits
                  (target   : input-target)
                  (waiting  :? :t))             ; its suspension, once suspended
  final: #t)

(defclass minibuffer ((prompts : :list)          ; waiting prompts, innermost first
                      (keymap  : entry-table))   ; the minibuffer's own bindings
  final: #t)

(def (ask! (self : minibuffer) (question : :string) (initial : :string)) => :string
  (let* ((node (new-text-node (new-text initial)))
         (b (new-buffer (string-append " *Minibuf-" (number->string (next-id!)) "*") node)))
    (using (p (prompt question: question answer: node holder: b focus: (new-view b)
                      target: (make-input-target 'minibuffer self.keymap) waiting: #f)
              : prompt)
      (add-buffer! b)
      (set! self.prompts (cons p self.prompts))
      (push-focus-view! p.focus)
      (goto-char (point-max))
      (push-input-target! p.target)
      (unwind-protect
        (suspend (lambda (s) (set! p.waiting s)))
        (end-prompt! self p)))))

;; Undo what ask! set up; the focus returns to the next prompt out, or to
;; the selected view.
(def (end-prompt! (self : minibuffer) (p : prompt)) => :void
  (set! self.prompts (remq p self.prompts))
  (remove-input-target! p.target)
  (remove-focus-view! p.focus)
  (kill-buffer p.holder))

(def (innermost (self : minibuffer)) => prompt
  (match self.prompts
    ([p . _] p)
    ([] (error "Not in the minibuffer"))))

(implement Minibuffer minibuffer
  (read-from-minibuffer (lambda (self question initial) (ask! self question initial)))
  (active-prompt (lambda (self)
                   (match self.prompts
                     ([p . _] (make-prompt-display (prompt-question p) (prompt-answer p)))
                     ([] #f)))))

(defplugin (minibuffer-plugin ctx)
  "Asks questions in the minibuffer: read-string. RET answers, C-g abandons."
  requires: [input-service buffers-service]
  (using (self (minibuffer prompts: [] keymap: (new-keymap)) : minibuffer)
    (defcommand (exit-minibuffer) "Answer the innermost prompt with the text typed."
      (using (p (innermost self) : prompt)
        (resume! p.waiting (text-string (text-node-content p.answer)))))
    (defcommand (abort-minibuffers) "Abandon the innermost prompt; its command receives quit."
      (using (p (innermost self) : prompt)
        (resume-quit! p.waiting)))
    (keymap-set-in self.keymap "RET" 'exit-minibuffer)
    (keymap-set-in self.keymap "C-g" 'abort-minibuffers)
    (context-provide! ctx minibuffer-service (Minibuffer self))
    ;; Prompts still waiting when the plugin goes are abandoned.
    (context-defer! ctx (lambda ()
                          (for-each (lambda ((p : prompt)) (resume-quit! p.waiting))
                                    self.prompts)))))

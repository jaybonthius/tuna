#lang :tuna/prelude
;;; The minibuffer (live tier). It puts its idle buffer, which shows
;;; nothing, in a locked view in the bar at the bottom of the layout. Each
;;; prompt gets its own internal buffer: a `minibuffer` node holding the
;;; question and a text node for the answer. The prompt's buffer shows in
;;; the minibuffer view nearest the selected view (or, with none visible,
;;; wherever display-buffer puts it), and that view is selected, so basic
;;; editing types into the answer.
;;;
;;; RET and C-g belong to the prompt's buffer: they are bound in the
;;; keymap of its root node, so they answer or abandon the question only
;;; while focus is in that buffer. Elsewhere RET and C-g mean what they
;;; always do (a newline; keyboard-quit, which leaves the question
;;; waiting, as in Emacs), and the prompt waits until its view is selected
;;; again.
;;;
;;; Prompts nest: answers are delivered innermost first. When a prompt
;;; ends, its view shows what it showed before and the previously selected
;;; view is selected again.
(import :std/interface
        :tuna/kernel
        :tuna/services/keys
        :tuna/services/buffers
        :tuna/services/renderer
        :tuna/services/layout
        :tuna/services/minibuffer)
(export minibuffer-plugin)

(defclass prompt ((question        : :string)
                  (answer          : node)       ; the text node holding the answer
                  (holder          : buffer)     ; its internal buffer
                  (shown-in        : view)       ; the view showing it while it waits
                  (previous-buffer :? buffer)    ; what that view showed before
                  (previous-view   : view)       ; the view selected before
                  (waiting         :? :t))       ; its suspension, once suspended
  final: #t)

(defclass minibuffer ((prompts : :list)          ; waiting prompts, innermost first
                      (keymap  : entry-table)    ; the keymap of every prompt's buffer
                      (idle    : buffer))        ; shown while nothing is asked
  final: #t)

;; An internal buffer whose root is a minibuffer node holding CHILDREN,
;; with KEYMAP if any, drawn without a status line.
(def (minibuffer-buffer (name : :string) (children : :list) (keymap :? entry-table)) => buffer
  (let (b (new-buffer name (new-node minibuffer-node-kind children: children keymap: keymap)))
    (set-buffer-setting! b show-status-line #f)
    b))

(def (live? (b : buffer)) => :boolean
  (and (memq b (buffer-list)) #t))

(def (ask! (self : minibuffer) (question : :string) (initial : :string)) => :string
  (let* ((answer (new-text-node (new-text initial)))
         (b (minibuffer-buffer (string-append " *Minibuf-" (number->string (next-id!)) "*")
                               [(new-node 'minibuffer-prompt attributes: [['content . question]])
                                answer]
                               self.keymap)))
    (add-buffer! b)
    (let* ((before (selected-view))
           (showing (map (lambda ((v : view)) (cons v (view-showing v))) (view-list)))
           (v (or (nearest-view before minibuffer-view?) (display-buffer b)))
           (previous (assq v showing)))
      (using (p (prompt question: question answer: answer holder: b shown-in: v
                        previous-buffer: (and previous (cdr previous)) previous-view: before
                        waiting: #f)
                : prompt)
        (set-view-buffer v b)
        (select-view v)
        (goto-char (point-max))
        (set! self.prompts (cons p self.prompts))
        (unwind-protect
          (suspend (lambda (s) (set! p.waiting s)))
          (end-prompt! self p))))))

;; Undo what ask! set up: the prompt's view shows what it showed before
;; (the idle buffer if that is gone), the view selected before is selected
;; again, and the prompt's buffer goes.
(def (end-prompt! (self : minibuffer) (p : prompt)) => :void
  (set! self.prompts (remq p self.prompts))
  (let ((v p.shown-in)
        (views (view-list)))
    (when (and (memq v views) (eq? (view-showing v) p.holder) p.previous-buffer)
      (let (back (cond
                  ((live? p.previous-buffer) p.previous-buffer)
                  ((live? self.idle) self.idle)
                  (else #f)))
        (when back
          (set-view-buffer v back))))
    (when (and (eq? (selected-view) v) (memq p.previous-view views))
      (select-view p.previous-view)))
  (kill-buffer p.holder))

;; The prompt whose buffer is current, and the prompts inside it,
;; innermost first: RET and C-g act where they are typed.
(def (prompts-here (self : minibuffer)) => :list
  (let (b (current-buffer))
    (let lp ((rest self.prompts) (inside []))
      (match rest
        ([] (error "Not in a minibuffer"))
        ([p . more]
         (if (eq? (prompt-holder p) b)
           (reverse (cons p inside))
           (lp more (cons p inside))))))))

(implement Minibuffer minibuffer
  (read-from-minibuffer (lambda (self question initial) (ask! self question initial)))
  (active-prompt (lambda (self)
                   (match self.prompts
                     ([p . _] (make-prompt-display (prompt-question p) (prompt-answer p)))
                     ([] #f)))))

(defplugin (minibuffer-plugin ctx)
  "Asks questions in the minibuffer, a view in the bar: read-string. RET answers, C-g abandons."
  requires: [input-service buffers-service layout-service]
  (context-define-node-kind! ctx minibuffer-node-kind doc: "A prompt's question and answer, or nothing.")
  (context-define-node-kind! ctx 'minibuffer-prompt doc: "A prompt's question."
                             project: (lambda (n) (node-attribute n 'content)))
  (context-define-node-renderer! ctx minibuffer-node-kind 'html
                                 (lambda (n children) `(div (@ (class "minibuffer")) ,@children)))
  (context-define-node-renderer! ctx 'minibuffer-prompt 'html
                                 (lambda (n children) `(span (@ (class "prompt")) ,(node-attribute n 'content))))
  (let (idle (minibuffer-buffer " *Minibuf-0*" [] #f))
    (set-buffer-setting! idle no-other-view #t)
    (context-add-buffer! ctx idle)
    (add-locked-view idle side: 'bottom size: 'content)
    (using (self (minibuffer prompts: [] keymap: (new-keymap) idle: idle) : minibuffer)
      (defcommand (exit-minibuffer) "Answer the prompt here with the text typed; it must be the innermost."
        (match (prompts-here self)
          ([p] (using (p : prompt)
                 (resume! p.waiting (text-string (text-node-content p.answer)))))
          (else (error "Not in the innermost minibuffer"))))
      (defcommand (abort-minibuffers) "Abandon the prompt here and any inside it; their commands receive quit."
        (for-each (lambda ((p : prompt)) (resume-quit! p.waiting))
                  (prompts-here self)))
      (keymap-set-in self.keymap "RET" 'exit-minibuffer)
      (keymap-set-in self.keymap "C-g" 'abort-minibuffers)
      (context-provide! ctx minibuffer-service (Minibuffer self))
      ;; Prompts still waiting when the plugin goes are abandoned.
      (context-defer! ctx (lambda ()
                            (for-each (lambda ((p : prompt)) (resume-quit! p.waiting))
                                      self.prompts))))))

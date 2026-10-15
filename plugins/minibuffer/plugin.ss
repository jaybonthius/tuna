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
(import :tuna/plugins/commands/contract
        :std/interface
        (only-in :gerbil/runtime/hash HashTable)
        :tuna/kernel
        :tuna/plugins/keys/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/renderer/contract
        :tuna/plugins/layout/contract
        :tuna/plugins/minibuffer/contract
        :tuna/plugins/settings/contract
        :tuna/plugins/session/contract)
(export minibuffer minibuffer-history-length)

(defsetting minibuffer-history-length 100
  "Maximum entries in each named minibuffer history; #f keeps every entry, 0 keeps none.")

(defclass minibuffer-state ((ctx : context) (prompts : :list)
                      (keymap : entry-table)
                      (idle : buffer)
                      (histories : HashTable))
  final: #t)

(defclass prompt ((owner : minibuffer-state)
                  (question : :string)
                  (answer : node)
                  (holder : buffer)
                  (keymap : entry-table)
                  (shown-in : view)
                  (previous-buffer :? buffer)
                  (previous-view : view)
                  (waiting :? :t)
                  (exit-check : :procedure)
                  (history-name :? :symbol)
                  (history-items : :list)
                  (history-position : :fixnum)
                  (draft : :string))
  final: #t)

;; Deduplicate and trim on read, save and restore as well as insertion, so
;; a live length-setting change applies to every list without a hook.
(def (trim-history (items : :list)) => :list
  (let ((limit (setting-value minibuffer-history-length))
        (seen (make-hash-table)))
    (unless (or (not limit) (and (fixnum? limit) (fx>= limit 0)))
      (error "History length must be a nonnegative fixnum or #f" limit))
    (let lp ((rest items) (count 0))
      (match rest
        ([] [])
        ([item . more]
         (cond
          ((and limit (fx>= count limit)) [])
          ((hash-key? seen item) (lp more count))
          (else
           (hash-put! seen item #t)
           (cons item (lp more (fx1+ count))))))))))

(def (history-list (self : minibuffer-state) (name : :symbol)) => :list
  (trim-history (hash-ref self.histories name [])))

(def (save-histories (self : minibuffer-state)) => :list
  (hash-map (lambda ((name : :symbol) (items : :list)) (cons name (trim-history items)))
            self.histories))

(def (restore-histories! (self : minibuffer-state) (data : :t)) => :void
  (unless (and (list? data)
               (andmap (lambda (row)
                         (and (pair? row) (symbol? (car row))
                              (list? (cdr row)) (andmap string? (cdr row))))
                       data))
    (error "Invalid minibuffer histories" data))
  (hash-clear! self.histories)
  (for-each (lambda (row) (hash-put! self.histories (car row) (trim-history (cdr row)))) data))

(implement Prompt prompt
  (prompt-buffer (lambda (self) self.holder))
  (prompt-answer-node (lambda (self) self.answer))
  (prompt-keymap (lambda (self) self.keymap))
  (prompt-input (lambda (self) (text-string (text-node-content self.answer))))
  (prompt-set-exit-check! (lambda (self check)
                            (set! self.exit-check (context-bind (current-context) check))))
  (prompt-exit! (lambda (self value history-text)
                  (call-with-context (minibuffer-state-ctx self.owner)
                    (lambda ()
                  (using (owner self.owner : minibuffer-state)
                    (unless (and self.waiting (eq? self (car owner.prompts)))
                      (error "Not in the innermost minibuffer"))
                    (let (refusal (self.exit-check (prompt-input (Prompt self))))
                      (if refusal
                        (message (:- refusal :string))
                        (begin
                          (when self.history-name
                            (hash-put! owner.histories self.history-name
                                       (trim-history (cons history-text
                                                          (history-list owner self.history-name)))))
                          (resume! self.waiting value))))))))))

;; Navigation saves the unfinished input on first M-p; M-n returns to it.
(def (move-history! (p : prompt) (delta : :fixnum)) => :void
  (let (next (fx+ p.history-position delta))
    (cond
     ((or (fx< next 0) (fx> next (length p.history-items)))
      (message "No further minibuffer history"))
     (else
      (when (fxzero? p.history-position)
        (set! p.draft (prompt-input (Prompt p))))
      (let* ((input (if (fxzero? next) p.draft (list-ref p.history-items (fx1- next))))
             (t (text-node-content p.answer)))
        (text-replace! t 1 (fx1+ (text-size t)) input)
        (goto-char (fx1+ (string-length input)))
        (set! p.history-position next))))))

;; An internal buffer whose root is a minibuffer node holding CHILDREN,
;; with KEYMAP if any, drawn without a status line.
(def (minibuffer-buffer (name : :string) (children : :list) (keymap :? entry-table)) => buffer
  (let (b (new-buffer name (new-node minibuffer-node-kind children: children keymap: keymap)))
    (set-buffer-setting! b show-status-line #f)
    b))

(def (live? (b : buffer)) => :boolean
  (and (memq b (buffer-list)) #t))

(def (ask! (self : minibuffer-state) (question : :string) (initial : :string)
           (history :? :symbol) (setup :? :procedure)) => :t
  (let* ((items (if history (history-list self history) []))
         (keymap (new-keymap))
         (answer (new-text-node (new-text initial)))
         (b (minibuffer-buffer (string-append " *Minibuf-" (number->string (next-id!)) "*")
                               [(new-node 'minibuffer-prompt attributes: [['content . question]])
                                answer]
                               self.keymap)))
    (set-node-keymap! answer keymap)
    (add-buffer! b)
    (let* ((before (selected-view))
           (showing (map (lambda ((v : view)) (cons v (view-showing v))) (view-list)))
           (v (or (nearest-view before minibuffer-view?) (display-buffer b)))
           (previous (assq v showing)))
      (using (p (prompt owner: self question: question answer: answer holder: b keymap: keymap shown-in: v
                        previous-buffer: (and previous (cdr previous)) previous-view: before
                        waiting: #f exit-check: (lambda (input) #f)
                        history-name: history history-items: items
                        history-position: 0 draft: initial)
                : prompt)
        (set-view-buffer v b)
        (select-view v)
        (goto-char (point-max))
        (set! self.prompts (cons p self.prompts))
        (unwind-protect
          (suspend (lambda (s)
                     (set! p.waiting s)
                     (when setup (setup (Prompt p)))))
          (end-prompt! self p))))))

;; Undo what ask! set up: the prompt's view shows what it showed before
;; (the idle buffer if that is gone), the view selected before is selected
;; again, and the prompt's buffer goes.
(def (end-prompt! (self : minibuffer-state) (p : prompt)) => :void
  (set! p.waiting #f)
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
(def (prompts-here (self : minibuffer-state)) => :list
  (let (b (current-buffer))
    (let lp ((rest self.prompts) (inside []))
      (match rest
        ([] (error "Not in a minibuffer"))
        ([p . more]
         (if (eq? (prompt-holder p) b)
           (reverse (cons p inside))
           (lp more (cons p inside))))))))

(implement Minibuffer minibuffer-state
  (read-from-minibuffer (lambda (self question initial history setup) (ask! self question initial history setup)))
  (minibuffer-history (lambda (self name) (history-list self name)))
  (active-prompt (lambda (self)
                   (match self.prompts
                     ([p . _] (make-prompt-display (prompt-question p) (prompt-answer p)))
                     ([] #f)))))

(defplugin (minibuffer ctx)
  "Asks questions in the minibuffer, a view in the bar: read-string. RET answers, C-g abandons."
  provides: [minibuffer-service]
  requires: [commands-service input-service buffers-service layout-service settings-service session-service]
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
    (using (self (minibuffer-state ctx: ctx prompts: [] keymap: (new-keymap) idle: idle histories: (make-hash-table-eq)) : minibuffer-state)
      (context-add-session-slot! ctx 'minibuffer-history version: 1
                                 save: (lambda () (save-histories self))
                                 restore: (lambda (data) (restore-histories! self data)))
      (defcommand (previous-minibuffer-history) "Replace the prompt input with an older answer."
        (move-history! (car (prompts-here self)) 1))
      (defcommand (next-minibuffer-history) "Replace the prompt input with a newer answer, or the unfinished input."
        (move-history! (car (prompts-here self)) -1))
      (defcommand (exit-minibuffer) "Answer the prompt here with the text typed; it must be the innermost."
        (match (prompts-here self)
          ([p] (using (p : prompt)
                 (prompt-exit! (Prompt p) (prompt-input (Prompt p)))))
          (else (error "Not in the innermost minibuffer"))))
      (defcommand (abort-minibuffers) "Abandon the prompt here and any inside it; their commands receive quit."
        (for-each (lambda ((p : prompt)) (resume-quit! p.waiting))
                  (prompts-here self)))
      ;; Prompt-only commands are executable but not picker candidates.
      (for-each (lambda ((name : :symbol))
                  (let (c (command-ref name))
                    (set! (command-visible? c)
                          (lambda (command origin) #f))))
                '(exit-minibuffer abort-minibuffers previous-minibuffer-history next-minibuffer-history))
      (keymap-set-in self.keymap "M-p" 'previous-minibuffer-history)
      (keymap-set-in self.keymap "M-n" 'next-minibuffer-history)
      (keymap-set-in self.keymap "RET" 'exit-minibuffer)
      (keymap-set-in self.keymap "C-g" 'abort-minibuffers)
      (context-provide! ctx minibuffer-service (Minibuffer self))
      ;; Prompts still waiting when the plugin goes are abandoned.
      (context-defer! ctx (lambda ()
                            (for-each (lambda ((p : prompt)) (resume-quit! p.waiting))
                                      self.prompts))))))

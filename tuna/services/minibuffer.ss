;;; The minibuffer service: prompts that suspend the asking command (ADR 3,
;;; ADR 8). Commands stay direct-style:
;;;   (let (name (read-string "New name: ")) ...)
;;; The command waits at the prompt without the baton, so the editor keeps
;;; handling keys; only the innermost waiting prompt receives them.
;;;
;;; A prompt is a buffer, its question and answer both part of what it
;;; shows, in an ordinary view (ADR 13): the minibuffer view nearest the
;;; selected view, which is selected while the prompt waits. A view is a
;;; minibuffer view when its buffer's root is a `minibuffer` node.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel
        :tuna/services/buffers)
(export (interface-out Minibuffer)
        (interface-out Prompt)
        read-from-minibuffer minibuffer-history
        prompt-buffer prompt-answer-node prompt-keymap prompt-input prompt-set-exit-check! prompt-exit!
        minibuffer-service
        (struct-out prompt-display)
        minibuffer-node-kind
        minibuffer-view?
        read-string
        active-prompt)

;; What the innermost prompt asks: its question and the text node holding
;; the answer being typed.
(defstruct prompt-display ((question : :string)
                           (answer   : node))       ; a text node
  final: #t)

;; The kind of the root node of the buffers minibuffer views show.
(def minibuffer-node-kind 'minibuffer)

;; Whether V shows a minibuffer buffer, idle or asking.
(def (minibuffer-view? (v : view)) => :boolean
  (eq? (node-kind (buffer-root (view-showing v))) minibuffer-node-kind))

(interface Minibuffer
  ;; SETUP receives a Prompt handle on the baton, before yielding.
  ;; HISTORY is a named string history or #f. Return the exit value.
  (read-from-minibuffer (question : :string) (initial : :string)
                        (history :? :symbol) (setup :? :procedure)) => :t
  (minibuffer-history (name : :symbol)) => :list
  ;; The innermost waiting prompt, as a prompt-display, or #f.
  (active-prompt) => :t)

(interface Prompt
  ;; Add nodes through the ordinary buffers contract, not a second UI API.
  (prompt-buffer) => buffer
  ;; The answer node belongs to this handle, even while another prompt is active.
  (prompt-answer-node) => node
  ;; A prompt-local map, before its shared RET/C-g map.
  (prompt-keymap) => entry-table
  (prompt-input) => :string
  ;; CHECK receives typed text: #f accepts, a string refuses with a message.
  (prompt-set-exit-check! (check : :procedure)) => :void
  ;; History text is separate from a record-valued answer.
  (prompt-exit! (value : :t) (history-text : :string)) => :void)

(def (prompt-buffer (p : Prompt)) => buffer (Prompt-prompt-buffer p))
(def (prompt-answer-node (p : Prompt)) => node (Prompt-prompt-answer-node p))
(def (prompt-keymap (p : Prompt)) => entry-table (Prompt-prompt-keymap p))
(def (prompt-input (p : Prompt)) => :string (Prompt-prompt-input p))
(def (prompt-set-exit-check! (p : Prompt) (check : :procedure)) => :void
  (Prompt-prompt-set-exit-check! p check))
(def (prompt-exit! (p : Prompt) (value : :t)
                   history-text: (history-text : :string := (prompt-input p))) => :void
  (Prompt-prompt-exit! p value history-text))

(def minibuffer-service
  (new-service 'minibuffer is-Minibuffer? tier: 'live
               doc: "Asks questions in the minibuffer."))

(def (current-minibuffer) => Minibuffer
  (let (provider (service-provider minibuffer-service))
    (unless provider
      (error "No plugin provides the minibuffer"))
    (Minibuffer provider)))

(def (read-from-minibuffer (question : :string) (initial : :string := "")
                           history: (history :? :symbol := #f)
                           setup: (setup :? :procedure := #f)) => :t
  (Minibuffer-read-from-minibuffer (current-minibuffer) question initial history setup))

;; The plain string reader is only a typed user of the prompt protocol.
(def (read-string (question : :string) (initial : :string := "")
                  history: (history :? :symbol := #f)) => :string
  (:- (read-from-minibuffer question initial history: history) :string))

;; Newest first; callers treat the returned list as immutable.
(def (minibuffer-history (name : :symbol)) => :list
  (Minibuffer-minibuffer-history (current-minibuffer) name))

(def (active-prompt) => (Maybe prompt-display)
  (let (provider (service-provider minibuffer-service))
    (and provider (Minibuffer-active-prompt (Minibuffer provider)))))

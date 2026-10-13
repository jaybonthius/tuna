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
  ;; Ask QUESTION with INITIAL as the answer so far, and return the answer.
  ;; A yield point: the calling task suspends until the prompt is answered,
  ;; and raises quit if it is abandoned.
  (read-from-minibuffer (question : :string) (initial : :string)) => :string
  ;; The innermost waiting prompt, as a prompt-display, or #f.
  (active-prompt) => :t)

(def minibuffer-service
  (new-service 'minibuffer is-Minibuffer? tier: 'live
               doc: "Asks questions in the minibuffer."))

(def (current-minibuffer) => Minibuffer
  (let (provider (service-provider minibuffer-service))
    (unless provider
      (error "No plugin provides the minibuffer"))
    (Minibuffer provider)))

;; Ask QUESTION in the minibuffer and return the answer (Emacs
;; `read-string`). Call it from a task.
(def (read-string (question : :string) (initial : :string := "")) => :string
  (Minibuffer-read-from-minibuffer (current-minibuffer) question initial))

(def (active-prompt) => (Maybe prompt-display)
  (let (provider (service-provider minibuffer-service))
    (and provider (Minibuffer-active-prompt (Minibuffer provider)))))

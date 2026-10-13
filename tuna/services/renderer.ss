;;; The renderer service (ADR 7): editor state to a screen.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel
        :tuna/services/buffers)
(export (interface-out Renderer)
        renderer-service
        status-line-text)

(interface Renderer
  ;; Render the current editor state as an HTML fragment whose root element
  ;; has the id "screen". Runs on the baton.
  (render-screen) => :string)

(def renderer-service
  (new-service 'renderer is-Renderer? tier: 'live
               doc: "Turns editor state into a screen."))

;; The text of the status line (Emacs's mode line) of view V: the buffer,
;; the line and column of V's point, and, for the selected view, the
;; running command.
(def (status-line-text (v : view) (selected? : :boolean)) => :string
  (let ((command (and selected? (current-task-name)))
        (n (view-node v)))
    (string-append
     "Tuna · " (buffer-name (view-showing v))
     (if n
       (let* ((t (text-node-content n))
              (p (view-point v)))
         (string-append " · line " (number->string (text-line-at t p))
                        ", column " (number->string (text-column t p))))
       "")
     (if command
       (string-append " · running " (symbol->string command))
       ""))))

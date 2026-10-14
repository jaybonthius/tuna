;;; Buttons (live tier; Emacs button.el): draws button nodes (the buttons
;;; contract) as buttons, and binds a left click on one, `<mouse-1>` in
;;; `button-keymap`, to `push-button`, which runs the action of the button
;;; clicked. The binding shadows the global `<view> <mouse-1>`, so clicking
;;; a button does not select its view.
;;;
;;; Only a click pushes a button: keyboard focus is in a text node or at a
;;; buffer's root, never in a button, so RET is not bound. A button is a
;;; real <button>, out of the browser's tab order (tabindex -1), since
;;; keyboard focus is Tuna's, not the browser's; it is marked clickable
;;; from its keymap like any node.
prelude: :gerbil/core

(import :tuna/services/commands
        :tuna/kernel
        :tuna/services/keys
        :tuna/services/buffers
        :tuna/services/layout
        :tuna/services/buttons)
(export buttons-plugin)

;; N, or the nearest node above it, if it is a button; else #f.
(def (button-at (n :? node)) => (Maybe node)
  (let up ((n n))
    (cond
     ((not n) #f)
     ((eq? (node-kind n) button-node-kind) n)
     (else (up (node-parent n))))))

(defplugin (buttons-plugin ctx)
  "Buttons in buffers: a click on one runs its action."
  requires: [commands-service input-service buffers-service layout-service]
  optional: [messages-service]
  (context-define-node-kind! ctx button-node-kind
                             doc: "A button: a label, and an action run when it is clicked."
                             project: (lambda (n) (node-attribute n 'label)))
  (context-define-node-renderer! ctx button-node-kind 'html
                                 (lambda (n children)
                                   `(button (@ (type "button") (class "button") (tabindex "-1"))
                                            ,(node-attribute n 'label))))
  (define-command ctx (push-button) "Run the action of the button clicked (Emacs push-button)."
    (let (p (event-start (last-command-event)))
      (if p
        (let (b (button-at (posn-node p)))
          (if b
            ((button-action b) b)
            (report-stale-click p what: "button")))
        (message "push-button runs only from a click"))))
  (keymap-set-in ctx button-keymap "<mouse-1>" 'push-button))

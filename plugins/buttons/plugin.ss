#lang :tuna/prelude
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

(import :tuna/plugins/commands/contract
        :tuna/kernel
        :tuna/plugins/stylesheets/contract
        :tuna/plugins/keys/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/layout/contract
        :tuna/plugins/buttons/contract)
(export buttons)

;; N, or the nearest node above it, if it is a button; else #f.
(def (button-at (n :? node)) => (Maybe node)
  (let up ((n n))
    (cond
     ((not n) #f)
     ((eq? (node-kind n) button-node-kind) n)
     (else (up (node-parent n))))))

(defplugin (buttons ctx)
  "Buttons in buffers: a click on one runs its action."
  requires: [commands-service input-service buffers-service layout-service]
  (add-stylesheet 'rules "rules.css")
  (context-define-node-kind! ctx button-node-kind
                             doc: "A button: a label, and an action run when it is clicked."
                             project: (lambda (n) (node-attribute n 'label)))
  (context-define-node-renderer! ctx button-node-kind
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

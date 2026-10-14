;;; Buttons (Emacs button.el): a button is a `button` node with a label and
;;; an action, a procedure called with the button node when the button is
;;; pushed. Every button carries `button-keymap` (Emacs's `button-map`),
;;; into which the plugin that draws buttons binds a click to its command
;;; (the default: tuna/plugins/buttons.ss binds `<mouse-1>` to
;;; `push-button`). Those bindings belong to that plugin, so while none
;;; runs a button does nothing, and is not marked clickable.
;;;
;;;   (new-button "Open" (lambda (b) (switch-to-buffer (node-attribute b 'buffer)))
;;;               attributes: [['buffer . b]])
prelude: :gerbil/core

(import (only-in :tuna/services/keys new-keymap)
        :tuna/services/buffers)
(export button-node-kind
        button-keymap
        new-button
        button-action)

(def button-node-kind 'button)

;; The keymap of every button.
(def button-keymap (new-keymap))

;; A button labelled LABEL that runs (ACTION button) when pushed, with
;; ATTRIBUTES of its own besides `label` and `action`.
(def (new-button (label : :string) (action : :procedure) attributes: (attributes : :list := []))
  => node
  (new-node button-node-kind
            attributes: (cons* ['label . label] ['action . action] attributes)
            keymap: button-keymap))

;; The action of the button B.
(def (button-action (b : node)) => :procedure
  (:- (node-attribute b 'action) :procedure))

;;; The echo area: the messages service, extended so tests and commands can
;;; read the current message. Messages show in a buffer in an ordinary
;;; view (ADR 13): the echo area view nearest the selected view. A view is
;;; an echo area view when its buffer's root is an `echo-area` node, whose
;;; `content` attribute is the message.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel
        :tuna/plugins/buffers/contract)
(export (service-interface-out EchoArea)
        echo-area-node-kind
        echo-area-view?
        current-message)

(service-interface (EchoArea Messages)
  ;; The message shown last, or "".
  (current-message) => :string)

;; The kind of the root node of the buffers echo area views show.
(def echo-area-node-kind 'echo-area)

(def (echo-area-view? (v : view)) => :boolean
  (eq? (node-kind (buffer-root (view-showing v))) echo-area-node-kind))

(def (current-message) => :string
  (:- (let (provider (service-provider messages-service))
          (if (and provider (is-EchoArea? provider))
            (EchoArea-current-message (EchoArea provider))
            "")) :string))

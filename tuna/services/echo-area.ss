;;; The echo area: the messages service, extended so renderers can read
;;; the current message.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel)
(export (interface-out EchoArea)
        current-message)

(interface (EchoArea Messages)
  ;; The message shown now, or "".
  (current-message) => :string)

(def (current-message) => :string
  (let (provider (service-provider messages-service))
    (if (and provider (is-EchoArea? provider))
      (EchoArea-current-message (EchoArea provider))
      "")))

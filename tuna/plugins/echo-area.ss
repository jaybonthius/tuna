;;; The echo area (live tier): holds the latest message for renderers.
prelude: :gerbil/core

(import :tuna/kernel
        :tuna/services/echo-area)
(export echo-area-plugin)

(defclass echo-area ((text : :string))
  final: #t)

;; Generic methods, so the instance also satisfies the parent interface,
;; Messages, that the kernel checks.
(defmethod {message! echo-area}
  (lambda (self text)
    (using (self : echo-area)
      (set! self.text text))))

(defmethod {current-message echo-area}
  (lambda (self)
    (using (self : echo-area)
      self.text)))

(defplugin (echo-area-plugin ctx)
  "Shows messages in the echo area."
  (context-provide! ctx messages-service (EchoArea (echo-area text: ""))))

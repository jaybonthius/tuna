;;; The echo area (live tier): messages in a buffer, " *Echo Area*", which
;;; the plugin puts in a locked view in the bar at the bottom of the
;;; layout. A message goes to the echo area view nearest the selected view,
;;; or to this plugin's buffer when no echo area view is visible.
prelude: :gerbil/core

(import :tuna/kernel
        :tuna/plugins/buffers/contract
        :tuna/plugins/renderer/contract
        :tuna/plugins/layout/contract
        :tuna/plugins/echo-area/contract)
(export echo-area)

(defclass echo-area-state ((text : :string)            ; the message shown last
                     (home : buffer))            ; this plugin's echo area buffer
  final: #t)

;; The buffer a message goes to now.
(def (message-buffer (self : echo-area-state)) => buffer
  (let (v (and (service-provider layout-service)
               (nearest-view (selected-view) echo-area-view?)))
    (if v (view-showing v) (echo-area-state-home self))))

;; Generic methods, so the instance also satisfies the parent interface,
;; Messages, that the kernel checks.
(defmethod {message! echo-area-state}
  (lambda (self text)
    (using (self : echo-area-state)
      (set! self.text text)
      (let (b (message-buffer self))
        ;; Not a buffer of a buffers provider that just took over.
        (when (memq b (buffer-list))
          (let (root (buffer-root b))
            (unless (equal? (node-attribute root 'content) text)
              (set-node-attribute! root 'content text))))))))

(defmethod {current-message echo-area-state}
  (lambda (self)
    (using (self : echo-area-state)
      self.text)))

(defplugin (echo-area ctx)
  "Shows messages in the echo area, a view in the bar."
  provides: [messages-service]
  requires: [buffers-service layout-service]
  optional: [renderer-service]
  (context-define-node-kind! ctx echo-area-node-kind doc: "A message."
                             project: (lambda (n) (node-attribute n 'content)))
  (context-define-node-renderer! ctx echo-area-node-kind 'html
                                 (lambda (n children)
                                   `(p (@ (class "echo-area") (role "status")) ,(node-attribute n 'content))))
  (let (home (new-buffer " *Echo Area*" (new-node echo-area-node-kind attributes: [['content . ""]])))
    (set-buffer-setting! home show-status-line #f)
    (set-buffer-setting! home no-other-view #t)
    (context-add-buffer! ctx home)
    (add-locked-view home side: 'bottom size: 'content)
    (context-provide! ctx messages-service (EchoArea (echo-area-state text: "" home: home)))))

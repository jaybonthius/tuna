;;; The default buffers provider (live tier): the buffer list, the one
;;; window's view, and the node-kind registries. Starts with *scratch*, a
;;; buffer holding one empty text node.
;;;
;;; It adapts to a new text store instead of restarting, which would discard
;;; every buffer: it moves each buffer's texts into the new store.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel
        :tuna/services/text-store
        :tuna/services/buffers)
(export buffers-plugin)

(defclass buffer-registry ((buffers   : :list)          ; oldest first
                           (window    : view)            ; the one window's view
                           (kinds     : entry-table)
                           (renderers : entry-table))
  final: #t)

(implement Buffers buffer-registry
  (buffer-list (lambda (self) self.buffers))
  (add-buffer! (lambda (self b) (set! self.buffers (append self.buffers [b]))))
  (remove-buffer! (lambda (self b) (set! self.buffers (remq b self.buffers))))
  (current-view (lambda (self) self.window))
  (node-kinds (lambda (self) self.kinds))
  (node-renderers (lambda (self) self.renderers)))

(def (move-texts! (registry : buffer-registry) (store : TextStore)) => :void
  (for-each (lambda ((b : buffer))
              (for-each (cut text-move-to-store! <> store) (buffer-texts b)))
            registry.buffers))

(defplugin (buffers-plugin ctx)
  "Keeps buffers, the view, and node kinds; starts with *scratch*."
  requires: [text-store-service]
  (let* ((scratch (new-buffer "*scratch*" (new-text-node (new-text))))
         (registry (buffer-registry buffers: [scratch]
                                    window: (new-view scratch)
                                    kinds: (new-entry-table)
                                    renderers: (new-entry-table))))
    (context-provide! ctx buffers-service (Buffers registry))
    (context-adapt! ctx text-store-service
                    (lambda (old new) (move-texts! registry (TextStore new))))
    (context-define-node-kind! ctx 'text
                               doc: "Text that users edit."
                               project: (lambda (n) (text-string (text-node-content n))))))

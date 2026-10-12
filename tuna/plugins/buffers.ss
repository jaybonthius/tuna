;;; The default buffers provider (live tier): the buffer list, the one
;;; window's view, and the node-kind registries. Starts with *scratch*, a
;;; buffer holding one empty text node.
;;;
;;; It uses the text store without requiring it: requiring would deactivate
;;; it, discarding every buffer, whenever the store is swapped. Texts move
;;; into a new store on their next use instead.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel
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

(defplugin (buffers-plugin ctx)
  "Keeps buffers, the view, and node kinds; starts with *scratch*."
  (let (scratch (new-buffer "*scratch*" (new-text-node (new-text))))
    (context-provide! ctx buffers-service
                      (Buffers (buffer-registry buffers: [scratch]
                                                window: (new-view scratch)
                                                kinds: (new-entry-table)
                                                renderers: (new-entry-table))))
    (context-define-node-kind! ctx 'text
                               doc: "Text that users edit."
                               project: (lambda (n) (text-string (text-node-content n))))))

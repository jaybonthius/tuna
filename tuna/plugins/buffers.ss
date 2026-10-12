;;; The default buffers provider (live tier): the buffer list, the selected
;;; view and the focus views pushed over it, and the node-kind registries.
;;; Starts with *scratch*, a buffer holding one empty text node, selected in
;;; a view that the window manager's first window takes over.
;;;
;;; It adapts to a new text store instead of restarting, which would discard
;;; every buffer: it moves each buffer's texts into the new store. It adds
;;; the buffer scope to settings: buffer-local values of the current buffer.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel
        :tuna/services/text-store
        :tuna/services/settings
        :tuna/services/buffers)
(export buffers-plugin)

(defclass buffer-registry ((buffers   : :list)          ; oldest first
                           (selected  : view)            ; the selected window's view
                           (focus     : :list)           ; focus views, innermost first
                           (kinds     : entry-table)
                           (renderers : entry-table))
  final: #t)

(implement Buffers buffer-registry
  (buffer-list (lambda (self) self.buffers))
  (add-buffer! (lambda (self b) (set! self.buffers (append self.buffers [b]))))
  (remove-buffer! (lambda (self b) (set! self.buffers (remq b self.buffers))))
  (current-view (lambda (self) (match self.focus ([v . _] v) ([] self.selected))))
  (selected-view (lambda (self) self.selected))
  (select-view! (lambda (self v) (set! self.selected v)))
  (push-focus-view! (lambda (self v) (set! self.focus (cons v self.focus))))
  (remove-focus-view! (lambda (self v) (set! self.focus (remq v self.focus))))
  (node-kinds (lambda (self) self.kinds))
  (node-renderers (lambda (self) self.renderers)))

(def (move-texts! (registry : buffer-registry) (store : TextStore)) => :void
  (for-each (lambda ((b : buffer))
              (for-each (cut text-move-to-store! <> store) (buffer-texts b)))
            registry.buffers))

(defplugin (buffers-plugin ctx)
  "Keeps buffers, their views, and node kinds; starts with *scratch*."
  requires: [text-store-service settings-service]
  (let* ((scratch (new-buffer "*scratch*" (new-text-node (new-text))))
         (registry (buffer-registry buffers: [scratch]
                                    selected: (new-view scratch)
                                    focus: []
                                    kinds: (new-entry-table)
                                    renderers: (new-entry-table))))
    (context-provide! ctx buffers-service (Buffers registry))
    (context-adapt! ctx text-store-service
                    (lambda (old new) (move-texts! registry (TextStore new))))
    (context-add-setting-scope! ctx 'buffer
                                (lambda (s) (buffer-setting (current-buffer) s)))
    (context-define-node-kind! ctx 'text
                               doc: "Text that users edit."
                               project: (lambda (n) (text-string (text-node-content n))))))

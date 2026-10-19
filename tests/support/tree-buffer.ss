;;; A *welcome* buffer built as a tree, (column (heading "Welcome to
;;; Tuna") (text "…")), with HTML renderers for its kinds,
;;; and C-c b to switch to it and back: for tests of node kinds, tree
;;; buffers, and buffers shown in several views. Turning the plugin off
;;; kills the buffer.
prelude: :gerbil/core

(import :tuna/plugins/commands/contract
        :tuna/kernel
        :tuna/plugins/keys/contract
        :tuna/plugins/buffers/contract)
(export tree-buffer
        welcome-buffer)

;; (column (heading "Welcome to Tuna") (text "…"))
(def (welcome-buffer) => buffer
  (new-buffer "*welcome*"
              (new-node 'column
                        children: [(new-node 'heading attributes: [['content . "Welcome to Tuna"]])
                                   (new-text-node
                                    (new-text "This buffer is a tree: a column holding a heading and this text.\nType here; the heading stays.\n"))])))

(def (render-column (n : node) (children : :list)) => :list
  `(div (@ (class "column")) ,@children))

(def (render-heading (n : node) (children : :list)) => :list
  `(h1 (@ (class "heading")) ,(node-attribute n 'content)))

(defplugin (tree-buffer ctx)
  "Defines the column and heading kinds, adds *welcome*, and binds C-c b to switch to it."
  requires: [commands-service input-service buffers-service]
  (def previous-buffer #f)              ; where C-c b returns from *welcome*
  (context-define-node-kind! ctx 'column doc: "Children stacked vertically.")
  (context-define-node-kind! ctx 'heading doc: "A heading."
                             project: (lambda (n) (node-attribute n 'content)))
  (context-define-node-renderer! ctx 'column render-column)
  (context-define-node-renderer! ctx 'heading render-heading)
  (context-add-buffer! ctx (welcome-buffer))
  (define-command ctx (switch-to-welcome-buffer) "Switch to *welcome*, and from it back to the buffer before."
    (let (welcome (or (get-buffer "*welcome*") (error "No buffer named" "*welcome*")))
      (if (eq? (current-buffer) welcome)
        (let (back (if (memq previous-buffer (buffer-list)) previous-buffer (other-buffer welcome)))
          (when back (switch-to-buffer back)))
        (begin
          (set! previous-buffer (current-buffer))
          (switch-to-buffer welcome)))))
  (keymap-set ctx "C-c b" 'switch-to-welcome-buffer))

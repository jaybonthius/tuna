;;; The Markdown demo plugin, for development only (`tuna --config
;;; demo/init.ss`): C-c m shows *markdown*, a preview of Markdown drawn by
;;; the markdown plugin above an editable text holding that Markdown,
;;; styled as it is typed. Each change to the text redraws the preview,
;;; rebuilding only the blocks that changed (markdown-update-blocks), as a
;;; streaming chat reply does. The text starts as markdown-sample.md.
prelude: :gerbil/core

(import :std/source
        :tuna/kernel
        :tuna/plugins/commands/contract
        :tuna/plugins/keys/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/layout/contract
        :tuna/plugins/stylesheets/contract
        :tuna/plugins/markdown/contract)
(export markdown-demo)

(def markdown-buffer-name "*markdown*")

(def sample-file (path-expand "markdown-sample.md" (path-expand (this-source-directory))))

;; The *markdown* buffer: the preview of the source text, a label, then
;; the source text, styled; and the source text and the preview.
(def (make-markdown-buffer) => :list
  (let* ((source (new-text (call-with-input-file sample-file (lambda (port) (read-line port #f)))))
         (preview (new-node 'markdown-demo-preview children: (markdown-blocks (text-string source))))
         (editor (new-text-node source))
         (b (new-buffer markdown-buffer-name
                        (new-node 'markdown-demo
                                  children: [preview
                                             (new-node 'markdown-demo-label
                                                       attributes: [(cons 'label "The Markdown above, as typed")])
                                             (new-node 'markdown-demo-source children: [editor])]))))
    (markdown-style-text! source)
    [b source preview]))

(defplugin (markdown-demo ctx)
  "C-c m: *markdown*, Markdown drawn above the same Markdown being typed."
  requires: [commands-service input-service buffers-service layout-service markdown-service]
  (add-stylesheet 'rules "markdown-demo.css")
  (context-define-node-kind! ctx 'markdown-demo doc: "A preview, then its source." items: 'children)
  (context-define-node-kind! ctx 'markdown-demo-preview doc: "Markdown, drawn." items: 'children)
  (context-define-node-kind! ctx 'markdown-demo-label doc: "What the source below is." items: 'whole
                             project: (lambda (n) (node-attribute n 'label)))
  (context-define-node-kind! ctx 'markdown-demo-source doc: "Markdown, as typed." items: 'children)
  (context-define-node-renderer! ctx 'markdown-demo (lambda (n children) `(div (@ (class "markdown-demo")) ,@children)))
  (context-define-node-renderer! ctx 'markdown-demo-preview
                                 (lambda (n children) `(div (@ (class "markdown-demo-preview")) ,@children)))
  (context-define-node-renderer! ctx 'markdown-demo-label
                                 (lambda (n children) `(h2 (@ (class "markdown-demo-label")) ,(node-attribute n 'label))))
  (context-define-node-renderer! ctx 'markdown-demo-source
                                 (lambda (n children) `(div (@ (class "markdown-demo-source")) ,@children)))
  ;; The source text and the preview of the newest *markdown*.
  (let ((source #f) (preview #f))
    (context-add-hook! ctx after-change-hook 'markdown-demo
                       (lambda ((t : text) (c : change))
                         (when (eq? t source)
                           (set-node-children! preview (markdown-update-blocks (node-children preview)
                                                                              (text-string t))))))
    (define-command ctx (markdown-buffer) "Show *markdown*, Markdown drawn above the same Markdown being typed."
      (let* ((b (or (get-buffer markdown-buffer-name)
                    (match (make-markdown-buffer)
                      ([b text node]
                       (set! source text)
                       (set! preview node)
                       (context-add-buffer! ctx b)
                       b))))
             (v (selected-view))
             (editor (first-text-node (car (reverse (node-children (buffer-root b)))))))
        (set-view-buffer v b)
        (when editor
          (set-view-focus! v editor 1)))))
  (keymap-set ctx "C-c m" 'markdown-buffer))

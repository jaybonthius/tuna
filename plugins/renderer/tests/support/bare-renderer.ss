;;; The toy renderer (live tier): a second HTML renderer, small enough to
;;; read at a glance. It proves the renderer slot can be swapped while Tuna
;;; runs (ADR 7, ADR 12). It draws the same screen from the frame, every
;;; node afresh through its kind's renderer, with no HTML reuse, no node
;;; ids and no clickable marks; a text node is one <pre> with the rendered
;;; view's point marked.
prelude: :gerbil/core

(import :std/text/markup/sxml/print
        :tuna/kernel
        :tuna/plugins/settings/contract
        :tuna/plugins/renderer/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/layout/contract
        :tuna/plugins/stylesheets/contract)
(export bare-renderer)

(defstruct bare-rendering ()
  final: #t)

;; The view whose buffer is being rendered: where its text nodes show point.
(def rendering-view (make-parameter #f))

(def (render-node (n : node)) => :t
  (let ((children (map render-node (node-children n)))
        (render (node-renderer (node-kind n))))
    (cond
     (render (render n children))
     ((pair? children) `(div (@ (class "node")) ,@children))
     (else (node-text-projection n)))))

;; A text node: its text, with the rendered view's point marked. At the end
;; of a line the cursor stands on a space.
(def (render-text-node (n : node) (children : :list)) => :list
  (let* ((content (text-string (text-node-content n)))
         (v (rendering-view))
         (position (and v (eq? n (view-node v)) (view-point v))))
    (if position
      (let* ((size (string-length content))
             (i (fx1- position))
             (under (if (and (fx< i size) (not (char=? (string-ref content i) #\newline)))
                      (fx1+ i)
                      i)))
        `(pre (@ (class "text"))
              ,(substring content 0 i)
              (span (@ (class ,(if (eq? v (selected-view)) "cursor" "inactive-cursor")))
                    ,(if (fx= under i) " " (substring content i under)))
              ,(substring content under size)))
      `(pre (@ (class "text")) ,content))))

(def (render-view (v : view) (selected? : :boolean) (start : node)) => :list
  (let (b (view-showing v))
    (parameterize ((rendering-view v))
      `(section (@ (class "view")
                   (data-view ,(number->string (view-id v)))
                   ,@(if selected? '((data-selected "true")) '()))
         (article (@ (class "buffer") (aria-label ,(buffer-name b)))
                  ,(render-node start))
         ,@(if (buffer-local-value show-status-line b)
             [`(p (@ (class "status-line")) ,(status-line-text v (and selected? (current-task-name))))]
             [])))))

(defmethod {render-screen bare-rendering}
  (lambda (self c)
    (call-with-output-string ""
      (lambda (port)
        (write-sxml `(main (@ (id "screen") (class "screen") (data-renderer "bare"))
                       ,(render-layout 'html render-view))
                    port: port xml?: #f)))))

(defplugin (bare-renderer ctx)
  "Renders the screen as HTML without reuse (a toy)."
  provides: [renderer-service]
  requires: [buffers-service layout-service settings-service]
  (add-stylesheet 'rules "bare-renderer.css")
  (context-define-node-renderer! ctx 'text render-text-node)
  (context-provide! ctx renderer-service (Renderer (make-bare-rendering))))

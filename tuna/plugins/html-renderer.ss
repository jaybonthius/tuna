;;; HTML renderer (live tier): editor state -> SXML -> HTML (ADR 7).
;;; It walks the current view's buffer tree and renders each node through
;;; the procedure registered for its kind and the `html` target. A kind
;;; without one is shown as its text projection.
prelude: :gerbil/core

(import :std/text/markup/sxml/print
        :tuna/kernel
        :tuna/services/renderer
        :tuna/services/buffers
        :tuna/services/echo-area
        :tuna/services/help)
(export html-renderer-plugin
        screen-sxml)

(defstruct html-renderer ()
  final: #t)

;; ELEMENT with a data-node attribute identifying N (ADR 7).
(def (with-node-id (n : node) (element : :t)) => :t
  (let (id ['data-node (number->string (node-id n))])
    (match element
      ([tag ['@ . attributes] . body] (cons* tag (cons* '@ id attributes) body))
      ([tag . body] (cons* tag ['@ id] body))
      (else element))))

(def (render-node (n : node)) => :t
  (let ((children (map render-node (node-children n)))
        (render (node-renderer (node-kind n) 'html)))
    (with-node-id n
      (if render
        (render n children)
        `(div (@ (class "node") (data-kind ,(symbol->string (node-kind n))))
              ,@(if (null? children) [(node-text-projection n)] children))))))

;; A text node: one element per line, with the cursor when the node has
;; the view's focus.
(def (render-text-node (n : text-node) (children : :list)) => :list
  (let* ((t (text-node-content n))
         (position (and (eq? n (current-text-node)) (point)))
         (cursor-line (and position (text-line-at t position)))
         (cursor-column (and position (text-column t position))))
    `(div (@ (class "text"))
          ,@(let lp ((line (text-line-count t)) (out []))
              (if (fx< line 1)
                out
                (let (content (text-substring t (text-line-start t line) (text-line-end t line)))
                  (lp (fx1- line)
                      (cons (if (eqv? line cursor-line)
                              (line-with-cursor content cursor-column)
                              `(div (@ (class "line")) ,content))
                            out))))))))

(def (line-with-cursor (line : :string) (column : :fixnum)) => :list
  (let (end (string-length line))
    `(div (@ (class "line"))
          ,(substring line 0 column)
          (span (@ (class "cursor"))
                ,(if (fx< column end) (substring line column (fx1+ column)) " "))
          ,(if (fx< column end) (substring line (fx1+ column) end) ""))))

(def (status-line) => :string
  (let ((command (current-command-name))
        (b (current-buffer))
        (n (current-text-node)))
    (string-append
     "Tuna · " (buffer-name b)
     (if n
       (let* ((t (text-node-content n))
              (p (point)))
         (string-append " · line " (number->string (text-line-at t p))
                        ", column " (number->string (text-column t p))))
       "")
     (if command
       (string-append " · running " (symbol->string command))
       ""))))

;; The screen: help output when there is some, the buffer, the status
;; line, and the echo area.
(def (screen-sxml) => :list
  (let ((help (current-help))
        (b (current-buffer)))
    `(main (@ (id "screen") (class "screen"))
       ,@(if help
           (using (help : help-output)
             `((section (@ (class "help") (aria-label "Help"))
                 (h1 ,help.title)
                 (pre ,(string-join help.lines "\n")))))
           [])
       (article (@ (class "buffer") (aria-label ,(buffer-name b)))
                ,(render-node (buffer-root b)))
       (footer
        (p (@ (class "status-line")) ,(status-line))
        (p (@ (class "echo-area") (role "status")) ,(current-message))))))

(def (html-string (markup : :list)) => :string
  (call-with-output-string ""
    (lambda (port) (write-sxml markup port: port xml?: #f))))

(defmethod {render-screen html-renderer}
  (lambda (self) (html-string (screen-sxml))))

(defplugin (html-renderer-plugin ctx)
  "Renders the screen as HTML."
  requires: [buffers-service]
  (context-define-node-renderer! ctx 'text 'html render-text-node)
  (context-provide! ctx renderer-service (Renderer (make-html-renderer))))

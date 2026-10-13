;;; The toy renderer (live tier): the same screen as preformatted plain
;;; text. It proves the renderer slot can be swapped while Tuna runs (ADR 7,
;;; ADR 12). The browser still receives HTML, but only <pre> blocks of text,
;;; with the cursors marked.
;;;
;;; Each node renders through its kind's procedure for the `plain-text`
;;; target, called with the node and its children's renderings; a kind
;;; without one shows its children one per line, or else its text
;;; projection. A rendering is a list of runs: strings, and
;;; (cursor STRING) or (inactive-cursor STRING) for the character under a
;;; cursor.
prelude: :gerbil/core

(import :std/text/markup/sxml/print
        :tuna/kernel
        :tuna/services/renderer
        :tuna/services/buffers
        :tuna/services/echo-area
        :tuna/services/help
        :tuna/services/minibuffer
        :tuna/services/layout)
(export plain-text-renderer-plugin
        join-runs)

(defstruct plain-text-renderer ()
  final: #t)

;; The view whose buffer is being rendered: where its text nodes show point.
(def rendering-view (make-parameter #f))

;; RENDERINGS, each a list of runs, one per line.
(def (join-runs (renderings : :list)) => :list
  (match renderings
    ([] [])
    ;; Not append-map: in Gerbil v0.19-dev-63 it reverses each sublist.
    ([first . rest] (apply append first (map (cut cons "\n" <>) rest)))))

(def (node-runs (n : node)) => :list
  (let ((children (map node-runs (node-children n)))
        (render (node-renderer (node-kind n) 'plain-text)))
    (cond
     (render (render n children))
     ((pair? children) (join-runs children))
     (else [(node-text-projection n)]))))

;; A text node: its text, with the rendered view's point marked. At the end
;; of a line the cursor stands on a space.
(def (text-node-runs (n : text-node) (children : :list)) => :list
  (let* ((content (text-string (text-node-content n)))
         (v (rendering-view))
         (position (and v (eq? n (view-node v)) (view-point v))))
    (if position
      (let* ((size (string-length content))
             (i (fx1- position))
             (under (if (and (fx< i size) (not (char=? (string-ref content i) #\newline)))
                      (fx1+ i)
                      i)))
        [(substring content 0 i)
         [(if (eq? v (current-view)) 'cursor 'inactive-cursor)
          (if (fx= under i) " " (substring content i under))]
         (substring content under size)])
      [content])))

(def (runs->sxml (runs : :list)) => :list
  (filter-map (lambda (run)
                (match run
                  ((? string?) (and (not (string-empty? run)) run))
                  ([(? symbol? role) (? string? text)]
                   `(span (@ (class ,(symbol->string role))) ,text))
                  (else (error "Not a plain-text run" run))))
              runs))

(def (render-view (v : view) (selected? : :boolean)) => :list
  (let (b (view-showing v))
    (parameterize ((rendering-view v))
      `(section (@ (class "view")
                   (id ,(string-append "view-" (number->string (view-id v))))
                   (data-view ,(number->string (view-id v)))
                   ,@(if selected? '((data-selected "true")) '()))
         (pre (@ (class "plain-text") (aria-label ,(buffer-name b)))
              ,@(runs->sxml (node-runs (buffer-root b)))
              "\n── " ,(status-line-text v selected?))))))

;; The innermost waiting prompt's question and answer, on a line of its own.
(def (minibuffer-runs) => :list
  (let (prompt (active-prompt))
    (if prompt
      (using (prompt : prompt-display)
        (cons prompt.question
              (append (parameterize ((rendering-view (current-view)))
                        (node-runs prompt.node))
                      ["\n"])))
      [])))

(def (screen-sxml) => :list
  (let (help (current-help))
    `(main (@ (id "screen") (class "screen") (data-renderer "plain-text"))
       ,@(if help
           (using (help : help-output)
             `((section (@ (class "help") (aria-label "Help"))
                 (pre (@ (class "plain-text")) ,help.title "\n\n" ,(string-join help.lines "\n")))))
           [])
       ,(render-layout 'html render-view)
       (footer
        (pre (@ (class "plain-text") (role "status"))
             ,@(runs->sxml (minibuffer-runs))
             ,(current-message))))))

(defmethod {render-screen plain-text-renderer}
  (lambda (self)
    (call-with-output-string ""
      (lambda (port) (write-sxml (screen-sxml) port: port xml?: #f)))))

(defplugin (plain-text-renderer-plugin ctx)
  "Renders the screen as plain text (a toy). Outranks the HTML renderer while active."
  requires: [buffers-service layout-service]
  (context-define-node-renderer! ctx 'text 'plain-text text-node-runs)
  (context-provide! ctx renderer-service (Renderer (make-plain-text-renderer)) priority: 10))

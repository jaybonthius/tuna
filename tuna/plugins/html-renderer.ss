;;; HTML renderer (live tier): editor state -> SXML -> HTML (ADR 7).
;;; The layout arranges the views; for each, the renderer walks its
;;; buffer's tree and renders each node through the procedure registered
;;; for its kind and the `html` target. A kind without one is shown as its
;;; text projection. Text nodes show their highlights as face classes and
;;; each view's point as a cursor: solid where typing goes, hollow in other
;;; views. The innermost waiting prompt shows above the echo area.
;;;
;;; Every view and node element has a stable id, so the browser's morph
;;; keeps its scroll position: a view's is view-V, a node's view-V-node-N,
;;; since one buffer may show in several views.
prelude: :gerbil/core

(import :std/text/markup/sxml/print
        :tuna/kernel
        :tuna/services/renderer
        :tuna/services/buffers
        :tuna/services/echo-area
        :tuna/services/help
        :tuna/services/minibuffer
        :tuna/services/layout)
(export html-renderer-plugin
        screen-sxml)

(defstruct html-renderer ()
  final: #t)

;; The view whose buffer is being rendered: where its text nodes show point.
(def rendering-view (make-parameter #f))

;; The element id of view V.
(def (view-element-id (v : view)) => :string
  (string-append "view-" (number->string (view-id v))))

;; ELEMENT with a data-node attribute identifying N (ADR 7), and an element
;; id unique to N in the rendered view.
(def (with-node-id (n : node) (element : :t)) => :t
  (let* ((number (number->string (node-id n)))
         (v (rendering-view))
         (ids (if v
                [['id (string-append (view-element-id v) "-node-" number)] ['data-node number]]
                [['data-node number]])))
    (match element
      ([tag ['@ . attributes] . body] (cons* tag (cons '@ (append ids attributes)) body))
      ([tag . body] (cons* tag (cons '@ ids) body))
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
;; the rendered view's focus.
(def (render-text-node (n : node) (children : :list)) => :list
  (let* ((t (text-node-content n))
         (v (rendering-view))
         (position (and v (eq? n (view-node v)) (view-point v)))
         (cursor-class (if (eq? v (current-view)) "cursor" "inactive-cursor"))
         (cursor-line (and position (text-line-at t position)))
         (cursor-column (and position (text-column t position)))
         (spans (text-all-highlights t)))
    `(div (@ (class "text"))
          ,@(let lp ((line (text-line-count t)) (out []))
              (if (fx< line 1)
                out
                (let* ((start (text-line-start t line))
                       (end (text-line-end t line)))
                  (lp (fx1- line)
                      (cons (render-line (text-substring t start end) start
                                         (filter (lambda ((s : span))
                                                   (and (fx< (span-start s) end)
                                                        (fx> (span-end s) start)))
                                                 spans)
                                         (and (eqv? line cursor-line) cursor-column)
                                         cursor-class)
                            out))))))))

;; One line starting at text position START: runs of characters with the
;; same face, and the cursor character alone at column CURSOR, with the
;; class CURSOR-CLASS.
(def (render-line (content : :string) (start : :fixnum) (spans : :list) (cursor :? :fixnum)
                  (cursor-class : :string))
  => :list
  (let* ((size (string-length content))
         (faces (make-vector size #f)))
    (for-each (lambda ((s : span))
                (let lp ((i (fxmax 0 (fx- (span-start s) start))))
                  (when (fx< i (fxmin size (fx- (span-end s) start)))
                    (vector-set! faces i (span-value s))
                    (lp (fx1+ i)))))
              spans)
    `(div (@ (class "line"))
          ,@(let lp ((i 0) (out []))
              (cond
               ((fx>= i size)
                (reverse (if (eqv? cursor size) (cons (cursor-span cursor-class " " #f) out) out)))
               ((eqv? i cursor)
                (lp (fx1+ i) (cons (cursor-span cursor-class (substring content i (fx1+ i))
                                                (vector-ref faces i))
                                   out)))
               (else
                (let* ((face (vector-ref faces i))
                       (end (let run ((j (fx1+ i)))
                              (if (and (fx< j size) (not (eqv? j cursor))
                                       (eq? (vector-ref faces j) face))
                                (run (fx1+ j))
                                j)))
                       (characters (substring content i end)))
                  (lp end (cons (if face
                                  `(span (@ (class ,(face-class face))) ,characters)
                                  characters)
                                out)))))))))

(def (face-class (face : :symbol)) => :string
  (string-append "face-" (symbol->string face)))

(def (cursor-span (cursor-class : :string) (character : :string) (face :? :symbol)) => :list
  `(span (@ (class ,(if face (string-append cursor-class " " (face-class face)) cursor-class)))
         ,character))

;; V: its buffer, then its status line.
(def (render-view (v : view) (selected? : :boolean)) => :list
  (let (b (view-showing v))
    (parameterize ((rendering-view v))
      `(section (@ (class "view")
                   (id ,(view-element-id v))
                   (data-view ,(number->string (view-id v)))
                   ,@(if selected? '((data-selected "true")) '()))
         (article (@ (class "buffer") (aria-label ,(buffer-name b)))
                  ,(render-node (buffer-root b)))
         (p (@ (class "status-line")) ,(status-line-text v selected?))))))

;; The innermost waiting prompt: its question, then the answer being typed.
(def (minibuffer-sxml) => :list
  (let (prompt (active-prompt))
    (if prompt
      (using (prompt : prompt-display)
        `((div (@ (class "minibuffer"))
               (span (@ (class "prompt")) ,prompt.question)
               ,(parameterize ((rendering-view (current-view)))
                  (render-node prompt.answer)))))
      [])))

;; The screen: help output when there is some, the layout, the
;; minibuffer while a prompt waits, and the echo area.
(def (screen-sxml) => :list
  (let (help (current-help))
    `(main (@ (id "screen") (class "screen"))
       ,@(if help
           (using (help : help-output)
             `((section (@ (class "help") (aria-label "Help"))
                 (h1 ,help.title)
                 (pre ,(string-join help.lines "\n")))))
           [])
       ,(render-layout 'html render-view)
       (footer
        ,@(minibuffer-sxml)
        (p (@ (class "echo-area") (role "status")) ,(current-message))))))

(def (html-string (markup : :list)) => :string
  (call-with-output-string ""
    (lambda (port) (write-sxml markup port: port xml?: #f))))

(defmethod {render-screen html-renderer}
  (lambda (self) (html-string (screen-sxml))))

(defplugin (html-renderer-plugin ctx)
  "Renders the screen as HTML."
  requires: [buffers-service layout-service]
  (context-define-node-renderer! ctx 'text 'html render-text-node)
  (context-provide! ctx renderer-service (Renderer (make-html-renderer))))

;;; HTML renderer (live tier): editor state -> SXML -> HTML (ADR 7).
;;; It walks the window's buffer tree and renders each node through the
;;; procedure registered for its kind and the `html` target. A kind without
;;; one is shown as its text projection. Text nodes show their highlights
;;; as face classes, and the cursor where the selected view's point is. The
;;; innermost waiting prompt shows above the echo area.
prelude: :gerbil/core

(import :std/text/markup/sxml/print
        :tuna/kernel
        :tuna/services/renderer
        :tuna/services/buffers
        :tuna/services/echo-area
        :tuna/services/help
        :tuna/services/minibuffer)
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
;; the selected view's focus.
(def (render-text-node (n : text-node) (children : :list)) => :list
  (let* ((t (text-node-content n))
         (position (and (eq? n (current-text-node)) (point)))
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
                                         (and (eqv? line cursor-line) cursor-column))
                            out))))))))

;; One line starting at text position START: runs of characters with the
;; same face, and the cursor character alone at column CURSOR.
(def (render-line (content : :string) (start : :fixnum) (spans : :list) (cursor :? :fixnum)) => :list
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
                (reverse (if (eqv? cursor size) (cons (cursor-span " " #f) out) out)))
               ((eqv? i cursor)
                (lp (fx1+ i) (cons (cursor-span (substring content i (fx1+ i)) (vector-ref faces i))
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

(def (cursor-span (character : :string) (face :? :symbol)) => :list
  `(span (@ (class ,(if face (string-append "cursor " (face-class face)) "cursor")))
         ,character))

(def (status-line) => :string
  (let* ((command (current-command-name))
         (window (window-view))
         (b (view-showing window))
         (n (and (eq? window (current-view)) (current-text-node))))
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

;; The innermost waiting prompt: its question, then the answer being typed.
(def (minibuffer-sxml) => :list
  (let (prompt (active-prompt))
    (if prompt
      (using (prompt : prompt-display)
        `((div (@ (class "minibuffer"))
               (span (@ (class "prompt")) ,prompt.question)
               ,(render-node prompt.node))))
      [])))

;; The screen: help output when there is some, the window's buffer, the
;; status line, the minibuffer while a prompt waits, and the echo area.
(def (screen-sxml) => :list
  (let ((help (current-help))
        (b (view-showing (window-view))))
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
        ,@(minibuffer-sxml)
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

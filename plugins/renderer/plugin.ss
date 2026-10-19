#lang :tuna/prelude
;;; HTML renderer (live tier): editor state -> SXML -> HTML (ADR 7). The
;;; screen is the layout drawn from the frame, nothing else: the minibuffer,
;;; the echo area and help are buffers in views like any other (ADR 13).
;;; For each view the renderer walks its buffer's tree, from where the
;;; frame points, and renders each node through the procedure registered
;;; for its kind. A kind without one is shown as its text projection. Text nodes show their highlights as face classes,
;;; through the buffer's face-remapping, and each view's point as a cursor:
;;; solid in the selected view, hollow in others. A view's status line
;;; shows unless its buffer's show-status-line is off.
;;;
;;; Every view and node element has a stable id, so the browser's morph
;;; keeps its scroll position: a view's is view-V, a node's view-V-node-N,
;;; since one buffer may show in several views. Views and status lines are
;;; parts a click can name (data-part "view:V", "status-line:V"); a status
;;; line is marked clickable while a click on one has a binding, and so is
;;; a node whose own keymap binds a plain click (data-clickable).
;;; Unprefixed global click bindings, which every part falls back to, mark
;;; nothing.
;;;
;;; HTML reuse: the HTML of each node, as drawn in each view, is kept and
;;; reused while the node's revision (which a change to it or below it
;;; replaces), the view state it depends on (point and whether the view is
;;; selected, for the nodes holding the view's focused text node), how its
;;; kind renders, and the display-wide inputs (the buffer's face-remapping,
;;; and the keymap generation, so a rebind marks clickable nodes again) are
;;; unchanged. So a node renderer must draw only from its node, its
;;; children's renderings (opaque HTML fragments to place), and those
;;; inputs. Every redraw still sends the whole visible screen as one fat
;;; morph. Kept HTML belongs to the views drawn: a view not drawn, or drawn
;;; from another node, drops its own.

(import (only-in :gerbil/runtime/hash HashTable)
        :std/text/markup/sxml/print
        :tuna/kernel
        (only-in :tuna/plugins/keys/contract part-clickable? keymap-clickable? keymap-generation)
        :tuna/plugins/settings/contract
        :tuna/plugins/renderer/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/layout/contract)
(export html-renderer)

;; A node's HTML in one view, and what it was drawn from.
(defstruct kept-html ((revision   : :fixnum)
                      (view-state : :t)          ; (point . selected?), or #f
                      (how        : :t)          ; the kind's renderer or kind info
                      (inputs     : :t)          ; the display-wide inputs
                      (html       : :string))
  final: #t)

;; What one view keeps: the node it was drawn from, and node id ->
;; kept-html.
(defclass view-html ((start : node)
                     (nodes : HashTable))
  final: #t)

(defclass html-rendering ((views : HashTable))    ; view id -> view-html
  final: #t)

;; Drawing one view: its kept HTML, the nodes from its buffer's root down
;; to its focused text node, its view state, and the display-wide inputs.
(defstruct drawing ((nodes      : HashTable)
                    (focus-path : :list)
                    (view-state : :t)
                    (inputs     : :t))
  final: #t)

;; The view whose buffer is being rendered: where its text nodes show point.
(def rendering-view (make-parameter #f))

;; The element id of view V.
(def (view-element-id (v : view)) => :string
  (string-append "view-" (number->string (view-id v))))

;; ELEMENT with a data-node attribute identifying N (ADR 7), an element id
;; unique to N in the rendered view, and data-clickable when N's own
;; keymap binds a plain click.
(def (with-node-id (n : node) (element : :t)) => :t
  (let* ((number (number->string (node-id n)))
         (v (rendering-view))
         (keymap (node-keymap n))
         (clickable (if (and keymap (keymap-clickable? keymap 'view)) [['data-clickable ""]] []))
         (ids (if v
                (cons* ['id (string-append (view-element-id v) "-node-" number)] ['data-node number]
                       clickable)
                (cons ['data-node number] clickable))))
    (match element
      ([tag ['@ . attributes] . body] (cons* tag (cons '@ (append ids attributes)) body))
      ([tag . body] (cons* tag (cons '@ ids) body))
      (else element))))

(def (html-string (markup : :t)) => :string
  (call-with-output-string ""
    (lambda (port) (write-sxml markup port: port xml?: #f))))

;; N's HTML as a fragment, kept or drawn again.
(def (render-node (d : drawing) (n : node)) => :list
  (let* ((kind (node-kind n))
         (render (node-renderer kind))
         (how (or render (node-kind-ref kind)))
         (view-state (and (memq n (drawing-focus-path d)) (drawing-view-state d)))
         (revision (node-revision n))
         (kept (hash-get (drawing-nodes d) (node-id n))))
    (if (and kept
             (using (kept : kept-html)
               (and (fx= kept.revision revision)
                    (equal? kept.view-state view-state)
                    (eq? kept.how how)
                    (equal? kept.inputs (drawing-inputs d)))))
      ['*unencoded* (kept-html-html kept)]
      (let* ((children (map (cut render-node d <>) (node-children n)))
             (html (html-string
                    (with-node-id n
                      (if render
                        (render n children)
                        `(div (@ (class "node") (data-kind ,(symbol->string kind)))
                              ,@(if (null? children) [(node-text-projection n)] children)))))))
        (hash-put! (drawing-nodes d) (node-id n)
                   (make-kept-html revision view-state how (drawing-inputs d) html))
        ['*unencoded* html]))))

;; A text node: one element per line, with the cursor when the node has
;; the rendered view's focus.
(def (render-text-node (n : node) (children : :list)) => :list
  (let* ((t (text-node-content n))
         (v (rendering-view))
         (b (and v (view-showing v)))
         (position (and v (eq? n (view-node v)) (view-point v)))
         (cursor-class (if (eq? v (selected-view)) "cursor" "inactive-cursor"))
         (cursor-line (and position (text-line-at t position)))
         (cursor-column (and position (text-column t position)))
         (spans (map (lambda ((s : span))
                       (if b (make-span (span-start s) (span-end s) (remapped-face (span-value s) b)) s))
                     (text-all-highlights t))))
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

;; The nodes from N up to its buffer's root.
(def (node-ancestors (n :? node)) => :list
  (let up ((n n) (out []))
    (if n (up (node-parent n) (cons n out)) out)))

;; What SELF keeps for V drawn from START, emptied when V was drawn from
;; another node before.
(def (view-html-for (self : html-rendering) (v : view) (start : node)) => view-html
  (let (kept (hash-get (html-rendering-views self) (view-id v)))
    (if (and kept (eq? (view-html-start kept) start))
      kept
      (let (fresh (view-html start: start nodes: (make-hash-table-eqv)))
        (hash-put! (html-rendering-views self) (view-id v) fresh)
        fresh))))

;; V: its buffer from node START (the root, or where the frame points),
;; then its status line unless its buffer turns it off.
(def (render-view (self : html-rendering) (v : view) (selected? : :boolean) (start : node)) => :list
  (let* ((b (view-showing v))
         (id (number->string (view-id v)))
         (focus (view-node v))
         (kept (view-html-for self v start))
         (d (make-drawing (view-html-nodes kept)
                          (node-ancestors focus)
                          (and focus (cons (view-point v) selected?))
                          (cons (buffer-local-value face-remapping b) (keymap-generation)))))
    (begin0
      (parameterize ((rendering-view v))
        `(section (@ (class "view")
                     (id ,(view-element-id v))
                     (data-view ,id)
                     (data-part ,(string-append "view:" id))
                     ,@(if selected? '((data-selected "true")) '()))
           (article (@ (class "buffer") (aria-label ,(buffer-name b)))
                    ,(render-node d start))
           ,@(if (buffer-local-value show-status-line b)
               [`(p (@ (class "status-line")
                       (data-part ,(string-append "status-line:" id))
                       ,@(if (part-clickable? 'status-line) '((data-clickable "")) '()))
                    ,(status-line-text v selected?))]
               [])))
      ;; Include descendants even when their ancestor reused its HTML.
      (let (nodes (make-hash-table-eqv))
        (let keep ((n start))
          (hash-put! nodes (node-id n) (hash-ref (drawing-nodes d) (node-id n)))
          (for-each keep (node-children n)))
        (set! (view-html-nodes kept) nodes)))))

;; The screen: the layout drawn from the frame. Views not drawn drop what
;; they kept.
(def (render-screen! (self : html-rendering)) => :string
  (let* ((drawn [])
         (layout (render-layout 'html
                                (lambda (v selected? start)
                                  (set! drawn (cons (view-id v) drawn))
                                  (render-view self v selected? start))))
         (views (html-rendering-views self)))
    (for-each (lambda (id) (unless (memv id drawn) (hash-remove! views id)))
              (hash-keys views))
    (html-string `(main (@ (id "screen") (class "screen")) ,layout))))

(defmethod {render-screen html-rendering}
  (lambda (self) (render-screen! self)))

(defplugin (html-renderer ctx)
  "Renders the screen as HTML: the layout drawn from the frame."
  provides: [renderer-service]
  requires: [buffers-service layout-service settings-service]
  optional: [input-service]
  (context-define-node-renderer! ctx 'text render-text-node)
  (context-provide! ctx renderer-service (Renderer (html-rendering views: (make-hash-table-eqv)))))

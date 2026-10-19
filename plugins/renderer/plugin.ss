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
;;; since one buffer may show in several views.
;;;
;;; Windowing: a view draws only part of the text node holding its anchor
;;; (the buffers contract's `view-anchor`): the lines from about 3,000 px
;;; above the anchor line to a view's height plus 4,000 px below it,
;;; counted with the average line height the browser last reported. Spacers
;;; stand in for the lines above and below, so the scrollbar covers the
;;; whole text; the top one leaves the anchor line where the browser last
;;; had it, unless the lines above need more room. Each drawn line carries
;;; its number (data-line) and an id, so a morph moves lines rather than
;;; rewriting them and the browser's scroll anchoring holds what you read
;;; still. The view's scroller asks the page (the web transport's
;;; tunaScroll action) to report when the line at its top leaves the range
;;; the window allows, when its top is in a spacer, or when its height is
;;; not the one drawn for, and whenever scrolling ends; the scrolling
;;; plugin turns reports into the anchor. Nodes other than text, and text
;;; nodes without the anchor, are drawn whole. Views and status lines are
;;; parts a click can name (data-part "view:V", "status-line:V"); a status
;;; line is marked clickable while a click on one has a binding, and so is
;;; a node whose own keymap binds a plain click (data-clickable).
;;; Unprefixed global click bindings, which every part falls back to, mark
;;; nothing.
;;;
;;; HTML reuse: the HTML of each node, as drawn in each view, is kept and
;;; reused while the node's revision (which a change to it or below it
;;; replaces), the view state it depends on (point and whether the view is
;;; selected, for the nodes holding the view's focused text node, and the
;;; drawn window, for the nodes holding its anchor), how its
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
        :tuna/plugins/stylesheets/contract
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

;; The lines of a view's anchor node that it draws, FIRST to LAST, with
;; spacers of TOP-SPACER and BOTTOM-SPACER px for the rest; and when the
;; page reports (tunaScroll): when the line at the view's top is outside
;; LOW..HIGH, or the view's height is not HEIGHT (-1 before any report).
(defstruct text-window ((first         : :fixnum)
                        (last          : :fixnum)
                        (top-spacer    : :fixnum)
                        (bottom-spacer : :fixnum)
                        (low           : :fixnum)
                        (high          : :fixnum)
                        (height        : :fixnum))
  final: #t)

;; Drawing one view: its kept HTML, the nodes from its buffer's root down
;; to its focused text node, its view state, the nodes down to its anchor
;; node and the window drawn there, and the display-wide inputs.
(defstruct drawing ((nodes       : HashTable)
                    (focus-path  : :list)
                    (view-state  : :t)
                    (window-path : :list)
                    (window      :? text-window)
                    (inputs      : :t))
  final: #t)

;; The view whose buffer is being rendered: where its text nodes show point.
(def rendering-view (make-parameter #f))

;; The anchor node of the view being rendered and its window, as
;; (node . text-window), or #f when the view draws every node whole.
(def rendering-window (make-parameter #f))

;; Pixels drawn above the anchor line, and below it besides the view's
;; height (hyperlith's virtual scroll draws 4,000 px around the view).
(def drawn-above 3000.)
(def drawn-below 4000.)

;; Estimates until the browser has reported on the view.
(def default-line-height 24.)
(def default-viewport-height 1000)

;; The number of lines of LINE-HEIGHT px it takes to fill PIXELS.
(def (lines-filling (pixels : :flonum) (line-height : :flonum)) => :fixnum
  (inexact->exact (flceiling (fl/ pixels line-height))))

(def (whole-pixels (pixels : :flonum)) => :fixnum
  (inexact->exact (flround pixels)))

;; The window of a text of LINE-COUNT lines anchored at line ANCHOR, OFFSET
;; px of which are above the view's top, given what the browser last
;; reported (FACTS). Only the browser knows where lines are, so the top
;; spacer puts the anchor line where the browser had it, by estimates of
;; the lines drawn above it, and never makes less room than the estimate
;; of everything above the window.
(def (text-window-around (line-count : :fixnum) (anchor : :fixnum) (offset : :flonum)
                         (facts :? scroll-facts))
  => text-window
  (let* ((line-height (if facts (scroll-facts-line-height facts) default-line-height))
         (viewport (if facts (scroll-facts-viewport-height facts) default-viewport-height))
         (viewport-px (exact->inexact viewport))
         (anchor-y (if facts (fl- (scroll-facts-viewport-top facts) offset) 0.))
         (first (fxmax 1 (fx- anchor (lines-filling drawn-above line-height))))
         (last (fxmin line-count
                      (fx+ anchor (fx1- (lines-filling (fl+ viewport-px drawn-below) line-height)))))
         (above-px (lambda ((lines : :fixnum)) (fl* (exact->inexact lines) line-height))))
    (make-text-window
     first last
     (if (fx= first 1)
       0
       (whole-pixels (flmax (fl- anchor-y (above-px (fx- anchor first))) (above-px (fx1- first)))))
     (whole-pixels (above-px (fx- line-count last)))
     (if (fx= first 1)
       1
       (fxmax first (fx- anchor (lines-filling (fl/ drawn-above 2.) line-height))))
     (if (fx= last line-count)
       line-count
       (fxmax anchor (fx- (fx1+ last) (lines-filling (fl+ viewport-px (fl/ drawn-below 2.)) line-height))))
     (if facts viewport -1))))

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
         (view-state (cons (and (memq n (drawing-focus-path d)) (drawing-view-state d))
                           (and (memq n (drawing-window-path d)) (drawing-window d))))
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
;; the rendered view's focus; only the lines of the window when it holds
;; the view's anchor, between spacers.
(def (render-text-node (n : node) (children : :list)) => :list
  (let* ((t (text-node-content n))
         (v (rendering-view))
         (b (and v (view-showing v)))
         (position (and v (eq? n (view-node v)) (view-point v)))
         (cursor-class (if (eq? v (selected-view)) "cursor" "inactive-cursor"))
         (cursor-line (and position (text-line-at t position)))
         (cursor-column (and position (text-column t position)))
         (windowed (rendering-window))
         (window (and windowed (eq? n (car windowed)) (:- (cdr windowed) text-window)))
         (line-count (text-line-count t))
         (first (if window (text-window-first window) 1))
         (last (if window (text-window-last window) line-count))
         (drawn-start (text-line-start t first))
         (drawn-end (text-line-end t last))
         (spans (filter-map (lambda ((s : span))
                              (and (fx< (span-start s) drawn-end)
                                   (fx> (span-end s) drawn-start)
                                   (if b
                                     (make-span (span-start s) (span-end s) (remapped-face (span-value s) b))
                                     s)))
                            (text-all-highlights t)))
         (line-id-prefix (and window v
                              (string-append (view-element-id v) "-node-" (number->string (node-id n)))))
         (spacer (lambda ((where : :string) (pixels : :fixnum))
                   `(div (@ (class "spacer") (id ,(string-append line-id-prefix "-" where))
                            (style ,(string-append "block-size: " (number->string pixels) "px")))))))
    `(div (@ (class "text") ,@(if window '((data-window "")) '()))
          ,@(if (and window (fx> first 1)) [(spacer "above" (text-window-top-spacer window))] [])
          ,@(let lp ((line last) (out (if (and window (fx< last line-count))
                                         [(spacer "below" (text-window-bottom-spacer window))]
                                         [])))
              (if (fx< line first)
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
                                         cursor-class
                                         (if window
                                           (let (number (number->string line))
                                             [['id (string-append line-id-prefix "-line-" number)]
                                              ['data-line number]])
                                           []))
                            out))))))))

;; One line starting at text position START, with ATTRIBUTES besides its
;; class: runs of characters with the same face, and the cursor character
;; alone at column CURSOR, with the class CURSOR-CLASS.
(def (render-line (content : :string) (start : :fixnum) (spans : :list) (cursor :? :fixnum)
                  (cursor-class : :string) (attributes : :list))
  => :list
  (let* ((size (string-length content))
         (faces (make-vector size #f)))
    (for-each (lambda ((s : span))
                (let lp ((i (fxmax 0 (fx- (span-start s) start))))
                  (when (fx< i (fxmin size (fx- (span-end s) start)))
                    (vector-set! faces i (span-value s))
                    (lp (fx1+ i)))))
              spans)
    `(div (@ (class "line") ,@attributes)
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

;; V's anchor node and its window, as (node . text-window), when V draws
;; it from START; otherwise #f.
(def (view-window (v : view) (start : node)) => (Maybe :pair)
  (let* ((anchor (view-anchor v))
         (n (view-anchor-node v)))
    (and anchor n (memq start (node-ancestors n))
         (let (t (text-node-content n))
           (cons n (text-window-around (text-line-count t) (text-line-at t anchor)
                                       (view-anchor-offset v) (view-facts v)))))))

;; The attributes of a view's scroller that ask the page for scroll
;; reports for WINDOW (see the header). The scroll handler only counts
;; scrolls, so that the effect, which reads the count, runs on each; the
;; effect must not write signals, or Datastar would run it a second time
;; after it reports.
(def (scroll-report-attributes (v : view) (window : text-window)) => :list
  (let (arguments (string-append (number->string (text-window-low window)) ", "
                                 (number->string (text-window-high window)) ", "
                                 (number->string (text-window-height window)) ", "
                                 (number->string (view-scroll-request v)) ")"))
    [['data-signals__ifmissing "{_tunaScrolls: 0}"]
     ['data-on:scroll "$_tunaScrolls = $_tunaScrolls + 1"]
     ['data-effect (string-append "$_tunaScrolls; @tunaScroll('moved', " arguments)]
     ['data-on:scrollend (string-append "@tunaScroll('rest', " arguments)]]))

;; V: its buffer from node START (the root, or where the frame points),
;; then its status line unless its buffer turns it off.
(def (render-view (self : html-rendering) (v : view) (selected? : :boolean) (start : node)) => :list
  (let* ((b (view-showing v))
         (id (number->string (view-id v)))
         (focus (view-node v))
         (kept (view-html-for self v start))
         (windowed (view-window v start))
         (d (make-drawing (view-html-nodes kept)
                          (node-ancestors focus)
                          (and focus (cons (view-point v) selected?))
                          (if windowed (node-ancestors (car windowed)) [])
                          (and windowed (cdr windowed))
                          (cons (buffer-local-value face-remapping b) (keymap-generation)))))
    (begin0
      (parameterize ((rendering-view v)
                     (rendering-window windowed))
        `(section (@ (class "view")
                     (id ,(view-element-id v))
                     (data-view ,id)
                     (data-part ,(string-append "view:" id))
                     ,@(if selected? '((data-selected "true")) '()))
           (article (@ (class "buffer") (aria-label ,(buffer-name b))
                       ,@(if windowed (scroll-report-attributes v (cdr windowed)) []))
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
  (add-stylesheet 'tokens "tokens.css")
  (add-stylesheet 'rules "rules.css")
  (context-define-node-renderer! ctx 'text render-text-node)
  (context-provide! ctx renderer-service (Renderer (html-rendering views: (make-hash-table-eqv)))))

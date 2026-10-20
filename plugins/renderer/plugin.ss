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
;;; Scrolling (the buffers contract's items and scroll state): a view's
;;; buffer, from the node it draws from, is a scroller of items, and the
;;; view draws only the run of them from its drawn-before items before its
;;; scroll item to its drawn-after items after it, inside as much of the
;;; tree as holds them: a node opening into children is drawn with only
;;; the children holding drawn items, and a text node with only its drawn
;;; lines. Nothing stands in for what is not drawn, so the browser's scroll
;;; range is exactly what is drawn, and nothing here knows a size in
;;; pixels. Each drawn item's element carries its token (data-item); a
;;; line's id stays with its text, through scrolling and through edits
;;; above it, so a morph moves lines rather than rewriting them and the
;;; browser's scroll anchoring holds what you read still. The scroller
;;; carries what its report trigger needs (the web transport's tunaScroll
;;; action): the drawn-above and drawn-below settings, whether the run
;;; starts at the first item and ends at the last, the view size last
;;; measured and the node drawn from. It also holds the view's placement
;;; marker, whose element id carries the placement's number, so only a new
;;; placement, or a freshly loaded page, makes the browser place the view
;;; (tunaPlace); the marker's other attributes name the current scroll
;;; state between placements. Beside the scroller is the view's scroll
;;; bar, drawn once the browser has measured that not every item is in
;;; view: its handle runs from the scroll item to the last item in view,
;;; over the item count. Views and status lines are parts a click can name
;;; (data-part "view:V", "status-line:V"); a status line is marked
;;; clickable while a click on one has a binding, and so is a node whose
;;; own keymap binds a plain click (data-clickable). Unprefixed global
;;; click bindings, which every part falls back to, mark nothing.
;;;
;;; HTML reuse: the HTML of each node, as drawn in each view, is kept and
;;; reused while the node's revision (which a change to it or below it
;;; replaces), the view state it depends on (point and whether the view is
;;; selected, for the nodes holding the view's focused text node; which of
;;; its items are drawn, and its line ids, for the nodes holding drawn
;;; items), how its kind renders, and the display-wide inputs (the
;;; buffer's face-remapping, and the keymap generation, so a rebind marks
;;; clickable nodes again) are unchanged. So a node renderer must draw only
;;; from its node, its children's renderings (opaque HTML fragments to
;;; place), and those inputs. Every redraw still sends the whole visible
;;; screen as one fat morph. Kept HTML belongs to the views drawn: a view
;;; not drawn, or drawn from another node, drops its own.

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
;; A node's HTML in one view, and what it was drawn from.
(defstruct kept-html ((revision   : :fixnum)
                      (view-state : :t)          ; see render-node
                      (how        : :t)          ; the kind's renderer or kind info
                      (inputs     : :t)          ; the display-wide inputs
                      (html       : :string))
  final: #t)

;; Where a view's line ids are pinned in one text node: the line starting
;; at POSITION, at character revision REVISION, had id ID.
(defstruct line-ids ((position : :fixnum)
                     (revision : :fixnum)
                     (id       : :fixnum))
  final: #t)

;; What one view keeps: the node it was drawn from, node id -> kept-html,
;; and text node id -> line-ids for the text nodes it drew lines of.
(defclass view-html ((start      : node)
                     (nodes      : HashTable)
                     (pinned-ids : HashTable))
  final: #t)

(defclass html-rendering ((views : HashTable))    ; view id -> view-html
  final: #t)

;; Drawing one view: its kept HTML, the nodes from its buffer's root down
;; to its focused text node, its view state, the display-wide inputs, and
;; the line ids pinned when it was drawn last and now.
(defstruct drawing ((nodes       : HashTable)
                    (focus-path  : :list)
                    (view-state  : :t)
                    (inputs      : :t)
                    (pinned-ids  : HashTable)
                    (pinning     : HashTable))
  final: #t)

;; The lines FIRST to LAST (from 1) of text node TEXT-NODE drawn as items,
;; with ID-OFFSET added to their numbers for their element ids.
(defstruct line-run ((text-node : node)
                     (first     : :fixnum)
                     (last      : :fixnum)
                     (id-offset : :fixnum))
  final: #t)

;; The view whose buffer is being rendered: where its text nodes show point.
(def rendering-view (make-parameter #f))

;; The line-run of the text node being rendered, or #f when it is drawn
;; whole inside an item.
(def rendering-lines (make-parameter #f))

;; The element id of view V.
(def (view-element-id (v : view)) => :string
  (string-append "view-" (number->string (view-id v))))

;; ELEMENT with a data-node attribute identifying N (ADR 7), an element id
;; unique to N in the rendered view, data-clickable when N's own keymap
;; binds a plain click, and N's token as data-item when N is drawn as
;; one item (ITEM?).
(def (with-node-id (n : node) (element : :t) (item? : :boolean)) => :t
  (let* ((number (number->string (node-id n)))
         (v (rendering-view))
         (keymap (node-keymap n))
         (clickable (if (and keymap (keymap-clickable? keymap 'view)) [['data-clickable ""]] []))
         (token (if item? [['data-item (item-token (node-item n))]] []))
         (ids (if v
                (cons* ['id (string-append (view-element-id v) "-node-" number)] ['data-node number]
                       (append clickable token))
                (cons* ['data-node number] (append clickable token)))))
    (match element
      ([tag ['@ . attributes] . body] (cons* tag (cons '@ (append ids attributes)) body))
      ([tag . body] (cons* tag (cons '@ ids) body))
      (else element))))

(def (html-string (markup : :t)) => :string
  (call-with-output-string ""
    (lambda (port) (write-sxml markup port: port xml?: #f))))

;; How N is drawn when its items FIRST to LAST are: N's whole node drawn
;; as one item ('item), or the run (FIRST . LAST) of its items.
(def (item-run (n : node) (first : :fixnum) (last : :fixnum)) => :t
  (if (eq? (node-opening n) 'whole) 'item (cons first last)))

;; The children of N to draw for RUN (see render-node), each with its own
;; run: for a run of N's items, the children holding them; otherwise all
;; of them, whole.
(def (drawn-children (n : node) (run : :t)) => :list
  (if (and (pair? run) (eq? (node-opening n) 'children))
    (let ((first (car run))
          (last (cdr run)))
      (map (lambda ((child-start : :pair))
             (let ((child (car child-start))
                   (start (cdr child-start)))
               (cons child (item-run child (fxmax 0 (fx- first start))
                                     (fxmin (fx1- (node-item-count child)) (fx- last start))))))
           (node-child-items n first last)))
    (map (cut cons <> #f) (node-children n))))

;; N's HTML as a fragment, kept or drawn again. RUN is how N is drawn: #f
;; whole, inside an item; 'item, whole, as one item; or (FIRST . LAST),
;; only its items FIRST to LAST (from 0), as a node that opens into items.
(def (render-node (d : drawing) (n : node) (run : :t)) => :list
  (let* ((kind (node-kind n))
         (render (node-renderer kind))
         (how (or render (node-kind-ref kind)))
         (lines (and (pair? run) (eq? (node-opening n) 'lines) (pin-line-run! d n run)))
         (view-state (list (and (memq n (drawing-focus-path d)) (drawing-view-state d))
                           run
                           (and lines (line-run-id-offset lines))))
         (revision (node-revision n))
         (kept (hash-get (drawing-nodes d) (node-id n))))
    (if (and kept
             (using (kept : kept-html)
               (and (fx= kept.revision revision)
                    (equal? kept.view-state view-state)
                    (eq? kept.how how)
                    (equal? kept.inputs (drawing-inputs d)))))
      ['*unencoded* (kept-html-html kept)]
      (let* ((children (map (lambda ((child-run : :pair)) (render-node d (car child-run) (cdr child-run)))
                            (drawn-children n run)))
             (html (html-string
                    (with-node-id n
                      (parameterize ((rendering-lines lines))
                        (if render
                          (render n children)
                          `(div (@ (class "node") (data-kind ,(symbol->string kind)))
                                ,@(if (null? children) [(node-text-projection n)] children))))
                      (eq? run 'item)))))
        (hash-put! (drawing-nodes d) (node-id n)
                   (make-kept-html revision view-state how (drawing-inputs d) html))
        ['*unencoded* html]))))

;; The line-run drawing text node N's items RUN (from 0), with line ids
;; following the text from where D's view pinned them last; pinned again
;; at the first line drawn.
(def (pin-line-run! (d : drawing) (n : node) (run : :pair)) => line-run
  (let* ((t (text-node-content n))
         (first (fx1+ (: (car run) :fixnum)))
         (last (fx1+ (: (cdr run) :fixnum)))
         (pinned (hash-get (drawing-pinned-ids d) (node-id n)))
         (offset (if pinned
                   (using (pinned : line-ids)
                     (fx- pinned.id
                          (text-line-at t (relocate-position t pinned.position pinned.revision))))
                   0)))
    (hash-put! (drawing-pinning d) (node-id n)
               (make-line-ids (text-line-start t first) (text-chars-revision t) (fx+ first offset)))
    (make-line-run n first last offset)))

;; A text node: one element per line, with the cursor when the node has
;; the rendered view's focus; only the lines drawn as items, each with its
;; token and an id that stays with its text, when it is drawn as items.
(def (render-text-node (n : node) (children : :list)) => :list
  (let* ((t (text-node-content n))
         (v (rendering-view))
         (b (and v (view-showing v)))
         (position (and v (eq? n (view-node v)) (view-point v)))
         (cursor-class (if (eq? v (selected-view)) "cursor" "inactive-cursor"))
         (cursor-line (and position (text-line-at t position)))
         (cursor-column (and position (text-column t position)))
         (lines (let (run (rendering-lines))
                  (and run (eq? (line-run-text-node run) n) (:- run line-run))))
         (first (if lines (line-run-first lines) 1))
         (last (if lines (line-run-last lines) (text-line-count t)))
         (drawn-start (text-line-start t first))
         (drawn-end (text-line-end t last))
         (spans (filter-map (lambda ((s : span))
                              (and (fx< (span-start s) drawn-end)
                                   (fx> (span-end s) drawn-start)
                                   (if b
                                     (make-span (span-start s) (span-end s) (remapped-face (span-value s) b))
                                     s)))
                            (text-all-highlights t)))
         (line-id-prefix (and lines v
                              (string-append (view-element-id v) "-node-" (number->string (node-id n)) "-line-"))))
    `(div (@ (class "text"))
          ,@(let lp ((line last) (out []))
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
                                         (if lines
                                           (cons ['data-item (item-token (node-item-at n (fx1- line)))]
                                                 (if line-id-prefix
                                                   [['id (string-append line-id-prefix
                                                                        (number->string
                                                                         (fx+ line (line-run-id-offset lines))))]]
                                                   []))
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
      (let (fresh (view-html start: start nodes: (make-hash-table-eqv) pinned-ids: (make-hash-table-eqv)))
        (hash-put! (html-rendering-views self) (view-id v) fresh)
        fresh))))

;; Px, from a drawn-above or drawn-below setting.
(def (setting-pixels (s : setting)) => :fixnum
  (let (px (setting-value s))
    (inexact->exact (round (if (and (real? px) (>= px 0)) px (setting-default s))))))

;; Where IT is among START's items, or #f.
(def (index-in (start : node) (it :? item)) => (Maybe :fixnum)
  (and it (node-item-index start it)))

;; The attributes of V's scroller, which draws START's items FIRST to LAST
;; of COUNT, that its report trigger reads (the web transport's tunaScroll
;; action). The scroll handler only counts scrolls, so that the effect,
;; which reads the count, runs on each; the effect must not write signals,
;; or Datastar would run it a second time after it reports.
(def (scroller-attributes (v : view) (start : node) (first : :fixnum) (last : :fixnum) (count : :fixnum))
  => :list
  (let (facts (view-facts v))
    (append
     [['data-signals__ifmissing "{_tunaScrolls: 0}"]
      ['data-on:scroll "$_tunaScrolls = $_tunaScrolls + 1"]
      ['data-effect "$_tunaScrolls; @tunaScroll('moved')"]
      ['data-on:scrollend "@tunaScroll('rest')"]
      ['data-scroll-root (number->string (node-id start))]
      ['data-drawn-above (number->string (setting-pixels drawn-above))]
      ['data-drawn-below (number->string (setting-pixels drawn-below))]]
     (if (fx<= first 0) [['data-run-at-start ""]] [])
     (if (fx>= last (fx1- count)) [['data-run-at-end ""]] [])
     (if facts
       [['data-measured-width (number->string (scroll-facts-width facts))]
        ['data-measured-height (number->string (scroll-facts-height facts))]]
       []))))

;; V's placement marker, in its scroller drawing START's items: its id
;; carries the placement's number, so the browser runs its constant
;; data-init (tunaPlace) once per placement and on a freshly loaded page.
;; Without a target among START's items, the view goes to its start.
(def (placement-marker (v : view) (start : node)) => :list
  (let* ((p (view-placement v))
         (number (number->string (placement-number p)))
         (target (let (it (placement-target p))
                   (and it (node-item-index start it) it))))
    `(div (@ (class "placement") (hidden "")
             (id ,(string-append (view-element-id v) "-placement-" number))
             (data-init "@tunaPlace()")
             (data-placement ,number)
             ,@(if target [['data-target (item-token target)]] [])
             (data-align ,(symbol->string (placement-align p)))
             (data-offset ,(number->string (placement-offset p)))))))

;; ITEMS as a percentage of COUNT, to four decimals: "12.5000%".
(def (percent-of (items : :fixnum) (count : :fixnum)) => :string
  (let* ((scaled (quotient (* items 1000000) count))
         (fraction (number->string (remainder scaled 10000))))
    (string-append (number->string (quotient scaled 10000)) "."
                   (make-string (fx- 4 (string-length fraction)) #\0) fraction "%")))

;; V's scroll bar, once the browser has measured that not all COUNT items
;; of START are in view; TOP is the index of the scroll item. The handle
;; runs from TOP over the items in view, as fractions of the track; the
;; browser keeps its own class and style through morphs, for showing the
;; bar while scrolling on a touch screen and the handle's drag preview.
(def (scroll-bar (v : view) (count : :fixnum) (top : :fixnum)) => :list
  (let (facts (view-facts v))
    (if (and facts (fx> count 0)
             (or (fx> top 0) (fx< (scroll-facts-visible-count facts) count)))
      (let ((percent (cut percent-of <> count))
            (id (string-append (view-element-id v) "-scroll-bar")))
        [`(div (@ (class "scroll-bar") (id ,id) (aria-hidden "true")
                  (data-preserve-attr "class style")
                  (data-on:click "@tunaScrollBar()"))
               (div (@ (class "scroll-bar-handle") (id ,(string-append id "-handle"))
                       (style ,(string-append "--scroll-bar-handle-start: " (percent top)
                                              "; --scroll-bar-handle-size: "
                                              (percent (fxmax 1 (scroll-facts-visible-count facts)))))
                       (data-on:pointerdown "@tunaScrollBar()"))))])
      [])))

;; V: its buffer from node START (the root, or where the frame points),
;; with its scroll bar, then its status line unless its buffer turns it
;; off.
(def (render-view (self : html-rendering) (v : view) (selected? : :boolean) (start : node)) => :list
  (let* ((b (view-showing v))
         (id (number->string (view-id v)))
         (focus (view-node v))
         (kept (view-html-for self v start))
         (count (node-item-count start))
         (top (fxmax 0 (fxmin (fx1- count) (or (index-in start (view-scroll-item v)) 0))))
         (first (fxmax 0 (fx- top (view-drawn-before v))))
         (last (fxmin (fx1- count) (fx+ top (view-drawn-after v))))
         (d (make-drawing (view-html-nodes kept)
                          (node-ancestors focus)
                          (and focus (cons (view-point v) selected?))
                          (cons (buffer-local-value face-remapping b) (keymap-generation))
                          (view-html-pinned-ids kept)
                          (make-hash-table-eqv)))
         (run (item-run start first last)))
    (begin0
      (parameterize ((rendering-view v))
        `(section (@ (class "view")
                     (id ,(view-element-id v))
                     (data-view ,id)
                     (data-part ,(string-append "view:" id))
                     ,@(if selected? '((data-selected "true")) '()))
           (article (@ (class "buffer") (aria-label ,(buffer-name b))
                       ,@(scroller-attributes v start first last count))
                    ,(placement-marker v start)
                    ,(render-node d start run))
           ,@(scroll-bar v count top)
           ,@(if (buffer-local-value show-status-line b)
               [`(p (@ (class "status-line")
                       (data-part ,(string-append "status-line:" id))
                       ,@(if (part-clickable? 'status-line) '((data-clickable "")) '()))
                    ,(status-line-text v selected?))]
               [])))
      ;; Keep only what this drawing drew, descendants of reused HTML
      ;; included.
      (let (nodes (make-hash-table-eqv))
        (let keep ((n start) (run run))
          (hash-put! nodes (node-id n) (hash-ref (drawing-nodes d) (node-id n)))
          (for-each (lambda ((child-run : :pair)) (keep (car child-run) (cdr child-run)))
                    (drawn-children n run)))
        (set! (view-html-nodes kept) nodes)
        (set! (view-html-pinned-ids kept) (drawing-pinning d))))))

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

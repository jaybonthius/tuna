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
;;; Each screen is drawn for one client (ADR 16): every client shows the
;;; same views, each scrolled as that client's browser measured it (the
;;; buffers contract's client-view), so the HTML kept for reuse is kept
;;; per client, and dropped when the client goes (client-gone-hook).
;;;
;;; Scrolling (the buffers contract's items and scroll state): a view's
;;; buffer, from the node it draws from, is a scroller of items, and the
;;; view draws only the run of them from its drawn-before items before its
;;; scroll item to its drawn-after items after it, as the client measured, inside as much of the
;;; tree as holds them: a node opening into children is drawn with only
;;; the children holding drawn items, and a text node with only its drawn
;;; lines. A spacer stands in for the items before the run and another for
;;; those after it, beside a scroll sizer as high as all the items would
;;; be at the view's average item height, which the browser measured: the
;;; spacer above as high as its items, the spacer below filling the rest;
;;; so the browser's own scroll bar covers the whole buffer, and its total
;;; height does not change as the view scrolls. That height is the only
;;; size here, and only spacers and the sizer use it: every position comes
;;; from what the browser measures. Until it has measured the view there
;;; are no spacers. A spacer in view asks the page to report
;;; (data-on-intersect), whatever brought it there. Each drawn item's
;;; element carries its token (data-item); a line's id stays with its
;;; text, through scrolling and
;;; through edits above it, so a morph moves lines rather than rewriting
;;; them and the browser's scroll anchoring holds what you read still. The
;;; scroller carries what its report trigger needs (the web transport's
;;; tunaScroll action): the drawn-screens setting, whether the run starts
;;; at the first item and ends at the last, the view size last measured
;;; and the node drawn from. It also holds the view's placement marker,
;;; whose element id carries the placement's number, so only a new
;;; placement, or a freshly loaded page, makes the browser place the view
;;; (tunaPlace); the marker's other attributes name the current scroll
;;; state between placements. Views and status lines are parts a click can
;;; name (data-part "view:V", "status-line:V"); a status line is marked
;;; clickable while a click on one has a binding, and so is a node whose
;;; own keymap binds a plain click (data-clickable). Unprefixed global
;;; click bindings, which every part falls back to, mark nothing.
;;;
;;; Drawing only what changed (ADR 17): the screen, each view and each
;;; node are drawn through `memo` (tuna/lib/memo), which keeps each one's
;;; HTML and draws it again only when its inputs differ or something it
;;; read through a contract's accessors changed: the screen's input is
;;; the running task's name, which the selected view's status line shows;
;;; a view's, the node it is drawn from and, when it is selected, that
;;; name; a node's, which of its items are drawn. A view's section element
;;; is not a piece: the layout adds its own attributes to it. Pieces hold what they drew from
;;; them, so an unchanged subtree is reused by one check, and the screen
;;; asked for when nothing changed is the very same string. Every redraw
;;; still sends the whole visible screen as one fat morph. A view reads
;;; what its client's browser measured, so screens and views are each
;;; client's; a node's HTML is shared by every client drawing the same
;;; items of it. So a node renderer must draw only from its node, its
;;; children's renderings (opaque HTML fragments to place), and what it
;;; reads through contracts' accessors. Drawing writes nothing: before it,
;;; each client's views of the views shown are made; after it, line ids
;;; are pinned again (below).
;;;
;;; Line ids: each view keeps, for each text node it draws as lines, where
;;; the line ids are pinned (line-ids), shared by every client. Drawing
;;; reads them; after a screen is drawn they are pinned again at the first
;;; line each text node draws, which gives every line the id it already
;;; has, so it changes no HTML, and keeps the ids of lines below an edit
;;; above them. Pins of views no client's last screen drew are dropped.

(import (only-in :gerbil/runtime/hash HashTable)
        :std/text/markup/sxml/print
        :tuna/kernel
        :tuna/lib/memo
        (only-in :tuna/plugins/clients/contract client client-gone-hook)
        :tuna/plugins/stylesheets/contract
        (only-in :tuna/plugins/keys/contract part-clickable? keymap-clickable?)
        :tuna/plugins/settings/contract
        :tuna/plugins/renderer/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/layout/contract)
(export html-renderer)

;; Where a view's line ids are pinned in one text node: the line ending
;; at POSITION, at character revision REVISION, which was line LINE then,
;; had id ID. A line's end moves with its text when a line is inserted
;; where it starts, so its id does too.
(defstruct line-ids ((position : :fixnum)
                     (revision : :fixnum)
                     (line     : :fixnum)
                     (id       : :fixnum))
  final: #t)

;; What a client's last screen was, and the ids of the views it drew.
(defclass client-screen ((screen : :string)
                         (views  : :list))
  final: #t)

;; PIECES: the screens, views and nodes drawn. PINS: view id -> text node
;; id -> line-ids. SCREENS: client (#f: none) -> client-screen.
(defclass html-rendering ((pieces  : memo-cache)
                          (pins    : HashTable)
                          (screens : HashTable))
  final: #t)

;; The lines FIRST to LAST (from 1) of text node TEXT-NODE drawn as items,
;; with ID-OFFSET added to their numbers for their element ids.
(defstruct line-run ((text-node : node)
                     (first     : :fixnum)
                     (last      : :fixnum)
                     (id-offset : :fixnum))
  final: #t)

;; The view whose buffer is being rendered: where its text nodes show point.
;; Each node's piece binds it from its key.
(def rendering-view (make-parameter #f))

;; The line-run of the text node being rendered, or #f when it is drawn
;; whole inside an item. Each node's piece binds it from its inputs.
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

;; N's HTML in view V as a fragment, kept or drawn again. RUN is how N is
;; drawn: #f whole, inside an item; 'item, whole, as one item; or (FIRST
;; . LAST), only its items FIRST to LAST (from 0), as a node that opens
;; into items.
(def (render-node (self : html-rendering) (v : view) (n : node) (run : :t)) => :list
  ['*unencoded* (memo ['node (view-id v) (node-id n)] run (lambda (run) (draw-node self v n run)))])

(def (draw-node (self : html-rendering) (v : view) (n : node) (run : :t)) => :string
  (let* ((kind (node-kind n))
         (render (node-renderer kind))
         (lines (and (pair? run) (eq? (node-opening n) 'lines) (line-run-of self v n run)))
         (children (map (lambda ((child-run : :pair)) (render-node self v (car child-run) (cdr child-run)))
                        (drawn-children n run))))
    (parameterize ((rendering-view v)
                   (rendering-lines lines))
      (html-string
       (with-node-id n
         (if render
           (render n children)
           `(div (@ (class "node") (data-kind ,(symbol->string kind)))
                 ,@(if (null? children) [(node-text-projection n)] children)))
         (eq? run 'item))))))

;; The pin of view V's line ids in text node N, or #f.
(def (pin-of (self : html-rendering) (v : view) (n : node)) => (Maybe line-ids)
  (let (pins (hash-get self.pins (view-id v)))
    (and pins (hash-get pins (node-id n)))))

;; The offset of view V's line ids in text node N from the line numbers,
;; by its pin (0 without one).
(def (line-id-offset (self : html-rendering) (v : view) (n : node)) => :fixnum
  (let (pinned (pin-of self v n))
    (if pinned
      (using (pinned : line-ids)
        (let (t (text-node-content n))
          (fx- pinned.id (text-line-at t (relocate-position t pinned.position pinned.revision)))))
      0)))

;; The line-run drawing text node N's items RUN (from 0) in view V, with
;; line ids following the text from where V's ids are pinned.
(def (line-run-of (self : html-rendering) (v : view) (n : node) (run : :pair)) => line-run
  (make-line-run n (fx1+ (: (car run) :fixnum)) (fx1+ (: (cdr run) :fixnum)) (line-id-offset self v n)))

;; After drawing: pin V's line ids in text node N, drawn from line FIRST,
;; at that line, which keeps every line's id; unless they are pinned there
;; already. In test mode, check that the ids stay.
(def (pin-line-ids! (self : html-rendering) (v : view) (n : node) (first : :fixnum)) => :void
  (let ((t (text-node-content n))
        (pinned (pin-of self v n)))
    (unless (and pinned
                 (using (pinned : line-ids)
                   (and (fx= pinned.line first) (fx= pinned.revision (text-chars-revision t)))))
      (let ((offset (line-id-offset self v n))
            (pins (or (hash-get self.pins (view-id v))
                      (let (new (make-hash-table-eqv))
                        (hash-put! self.pins (view-id v) new)
                        new))))
        (hash-put! pins (node-id n)
                   (make-line-ids (text-line-end t first) (text-chars-revision t) first (fx+ first offset)))
        (when (and (memo-checking?) (not (fx= offset (line-id-offset self v n))))
          (error "Pinning line ids again changed them" (view-id v) (node-id n)))))))

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

;; The drawn-screens setting for B: a positive number of view heights.
(def (drawn-screens-value (b : buffer)) => :number
  (let (screens (buffer-local-value drawn-screens b))
    (exact->inexact (if (and (real? screens) (> screens 0)) screens (setting-default drawn-screens)))))

;; Where IT is among START's items, or #f.
(def (index-in (start : node) (it :? item)) => (Maybe :fixnum)
  (and it (node-item-index start it)))

;; The attributes of V's scroller, which draws START's items FIRST to LAST
;; of COUNT, that its report trigger reads (the web transport's tunaScroll
;; action). Each trigger is the scroller's own: its scroll events, its
;; tunarest event (scrolling came to rest, from the transport's page), and an
;; effect reading no signal, which runs when a screen puts it back after
;; a report removed it. An effect reading a page-wide signal would run for
;; every scroller whenever any one scrolled, including one a morph is
;; removing, which measures nothing.
(def (scroller-attributes (v : view) (cv : client-view) (start : node) (first : :fixnum) (last : :fixnum)
                          (count : :fixnum))
  => :list
  (let (facts (client-view-facts cv))
    (append
     [['data-on:scroll "@tunaScroll('moved')"]
      ['data-effect "@tunaScroll('moved')"]
      ['data-on:tunarest "@tunaScroll('rest')"]
      ['data-scroll-root (number->string (node-id start))]
      ['data-drawn-screens (number->string (drawn-screens-value (view-showing v)))]]
     (if (fx<= first 0) [['data-run-at-start ""]] [])
     (if (fx>= last (fx1- count)) [['data-run-at-end ""]] [])
     (if facts
       [['data-measured-width (number->string (scroll-facts-width facts))]
        ['data-measured-height (number->string (scroll-facts-height facts))]]
       []))))

;; V's placement marker, in its scroller drawing START's items, for the
;; client whose view of it is CV: its id carries the newest placement sent
;; to the client, so the browser runs its constant data-init (tunaPlace)
;; once per placement and on a freshly loaded page. Without a target among
;; START's items, the view goes to its start.
(def (placement-marker (v : view) (cv : client-view) (start : node)) => :list
  (let* ((p (client-view-placement cv))
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

;; The px ITEMS items take at AVERAGE px each, rounded to a whole px.
(def (items-pixels (average : :flonum) (items : :fixnum)) => :string
  (number->string (inexact->exact (flround (fl* average (exact->inexact items))))))

;; V's spacer standing in for ITEMS undrawn items on SIDE ("above" or
;; "below" the drawn run of items FIRST to LAST), at V's average item
;; height; none before the browser has measured it, or without items.
;; The spacer below takes no size of its own: it fills what the drawn
;; items leave of the scroll sizer's height (see scroll-sizer), as the
;; spacer above does near the end of the buffer, where it is the last.
;; Whenever it is in view, the page reports (data-on-intersect, an
;; IntersectionObserver), however the view got there: a fling, a drag of
;; the scroll bar, or a report that was already on its way when scrolling
;; stopped. Its arguments change with the run, so a new run observes
;; afresh and asks again while the spacer is in view. It is not the
;; browser's scroll anchor (the renderer's stylesheet), so the browser
;; holds drawn items still, never a spacer.
(def (spacer (v : view) (cv : client-view) (side : :string) (items : :fixnum) (first : :fixnum)
             (last : :fixnum))
  => :list
  (let (average (client-view-average-item-height cv))
    (if (and average (fx> items 0))
      [`(div (@ (class "spacer") (aria-hidden "true")
                (id ,(string-append (view-element-id v) "-spacer-" side))
                (data-spacer ,side)
                ,@(if (equal? side "above")
                    [['style (string-append "--spacer-block-size: " (items-pixels average items) "px")]]
                    [])
                (data-on-intersect ,(string-append "@tunaScroll('spacer', " (number->string first) ", "
                                                   (number->string last) ")"))))]
      [])))

;; V's scroll sizer, in a scroller drawing COUNT items with SPACERS (the
;; spacers it draws): when there are spacers, an empty block as high as
;; all COUNT items at V's average item height, beside them (the
;; renderer's stylesheet lays the scroller out as a grid, the sizer in a
;; column of no width spanning every row). The last spacer fills what
;; the drawn items and any spacer before it leave of that height,
;; whatever the drawn items' real heights, so the scroller's total height
;; stays the same while the view scrolls, as long as the average and the
;; item count do: Chrome on macOS drags the scroll bar's thumb on its
;; compositor thread and drops a move whenever the total height changed
;; since the last one (ADR 15). The sizer is not a box around the items:
;; the browser would take a box around the spacers as its scroll anchor
;; whenever only spacers are in view, and keep it while the items drawn
;; next move under the view.
(def (scroll-sizer (cv : client-view) (count : :fixnum) (spacers : :list)) => :list
  (let (average (client-view-average-item-height cv))
    (if (and average (pair? spacers))
      [`(div (@ (class "scroll-sizer") (aria-hidden "true")
                (style ,(string-append "--scroll-sizer-block-size: " (items-pixels average count) "px"))))]
      [])))

;; The items a view draws from a node: of COUNT items, FIRST to LAST.
(defstruct drawn-items ((count : :fixnum)
                        (first : :fixnum)
                        (last  : :fixnum))
  final: #t)

;; The items a view draws from node START for the client whose view of it
;; is CV: around CV's scroll item.
(def (items-drawn (cv : client-view) (start : node)) => drawn-items
  (let* ((count (node-item-count start))
         (top (fxmax 0 (fxmin (fx1- count) (or (index-in start (client-view-scroll-item cv)) 0)))))
    (make-drawn-items count
                      (fxmax 0 (fx- top (client-view-drawn-before cv)))
                      (fxmin (fx1- count) (fx+ top (client-view-drawn-after cv))))))

;; V, as client C shows it, drawn from node START (the root, or where the
;; frame points), selected or not; COMMAND is the running task's name
;; when V is selected. The section is drawn each time, since the layout
;; adds its own attributes to it; what it holds is a piece.
(def (render-view (self : html-rendering) (c :? client) (v : view) (selected? : :boolean) (start : node)
                  (command :? :symbol))
  => :list
  (let (id (number->string (view-id v)))
    `(section (@ (class "view")
                 (id ,(view-element-id v))
                 (data-view ,id)
                 (data-part ,(string-append "view:" id))
                 ,@(if selected? '((data-selected "true")) '()))
       (*unencoded* ,(memo ['view (view-id v)] [(node-id start) (and selected? command)]
                           (lambda (inputs) (draw-view self c v start (cadr inputs))))))))

;; V's buffer from node START, then its status line unless its buffer
;; turns it off.
(def (draw-view (self : html-rendering) (c :? client) (v : view) (start : node) (command :? :symbol))
  => :string
  (let* ((b (view-showing v))
         (cv (view-client v c))
         (id (number->string (view-id v))))
    (using (drawn (items-drawn cv start) : drawn-items)
      (let* ((count drawn.count)
             (first drawn.first)
             (last drawn.last)
             (above (spacer v cv "above" first first last))
             (below (spacer v cv "below" (fx- count (fx1+ last)) first last)))
        (html-string
         (cons `(article (@ (class "buffer") (aria-label ,(buffer-name b))
                            ,@(scroller-attributes v cv start first last count))
                         ,(placement-marker v cv start)
                         ,@above
                         ,(render-node self v start (item-run start first last))
                         ,@below
                         ,@(scroll-sizer cv count (append above below)))
               (if (buffer-local-value show-status-line b)
                 [`(p (@ (class "status-line")
                         (data-part ,(string-append "status-line:" id))
                         ,@(if (part-clickable? 'status-line) '((data-clickable "")) '()))
                      ,(status-line-text v command))]
                 [])))))))

(def (draw-screen (self : html-rendering) (c :? client) (command :? :symbol)) => :string
  (html-string
   `(main (@ (id "screen") (class "screen"))
          ,(render-layout 'html (lambda (v selected? start) (render-view self c v selected? start command))))))

;; After drawing SCREEN for client C, when it is a new one: pin the line
;; ids of the text nodes each view drew as lines at the first line drawn,
;; and drop the pins of views no client's last screen drew.
(def (after-drawing! (self : html-rendering) (c :? client) (screen : :string)) => :void
  (let (kept (hash-get self.screens c))
    (unless (and kept (eq? (client-screen-screen kept) screen))
      (let (views (render-layout 'views
                                 (lambda (v selected? start)
                                   (using (drawn (items-drawn (view-client v c) start) : drawn-items)
                                     (let pin ((n start) (run (item-run start drawn.first drawn.last)))
                                       (when (and (pair? run) (eq? (node-opening n) 'lines))
                                         (pin-line-ids! self v n (fx1+ (: (car run) :fixnum))))
                                       (for-each (lambda ((child-run : :pair)) (pin (car child-run) (cdr child-run)))
                                                 (drawn-children n run))))
                                   (view-id v))))
        (hash-put! self.screens c (client-screen screen: screen views: views))
        (drop-unused-pins! self)))))

;; Drop the pins of views no client's last screen drew.
(def (drop-unused-pins! (self : html-rendering)) => :void
  (let (drawn (hash-fold (lambda (c (kept : client-screen) (ids : :list)) (append kept.views ids))
                         [] self.screens))
    (for-each (lambda (id) (unless (memv id drawn) (hash-remove! self.pins id)))
              (hash-keys self.pins))))

;; Client C's screen: its last one when nothing it was drawn from changed,
;; otherwise drawn again, through the pieces kept. Before drawing, each
;; view shown gets C's view of it, so drawing makes none.
(def (render-screen! (self : html-rendering) (c :? client)) => :string
  (render-layout 'views (lambda (v selected? start) (view-client v c)))
  (let* ((command (current-task-name))
         (screen (call-with-memo-pass self.pieces c
                   (lambda ()
                     (memo '(screen) [command] (lambda (inputs) (draw-screen self c (car inputs))))))))
    (after-drawing! self c screen)
    screen))

(defmethod {render-screen html-rendering}
  (lambda (self c) (render-screen! self c)))

(defplugin (html-renderer ctx)
  "Renders the screen as HTML: the layout drawn from the frame."
  provides: [renderer-service]
  requires: [buffers-service layout-service settings-service]
  optional: [input-service]
  (add-stylesheet 'tokens "tokens.css")
  (add-stylesheet 'rules "rules.css")
  (context-define-node-renderer! ctx 'text render-text-node)
  (using (self (html-rendering pieces: (new-memo-cache) pins: (make-hash-table-eqv) screens: (make-hash-table-eq))
               : html-rendering)
    (context-add-hook! ctx client-gone-hook 'html-renderer
                       (lambda ((c : client))
                         (memo-forget-client! self.pieces c)
                         (hash-remove! self.screens c)
                         (drop-unused-pins! self)))
    (context-provide! ctx renderer-service (Renderer self))))

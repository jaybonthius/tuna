#lang :tuna/prelude
;;; HTML renderer (live tier): editor state -> SXML -> HTML (ADR 7). The
;;; screen is the layout drawn from the frame, nothing else: the minibuffer,
;;; the echo area and help are buffers in views like any other (ADR 13).
;;; For each view the renderer walks its buffer's tree, from where the
;;; frame points, and renders each node through the procedure registered
;;; for its kind. A kind without one is shown as its text projection. Text nodes show their highlights as face classes,
;;; through the buffer's face-remapping, each view's point as a cursor:
;;; solid in the selected view, hollow in others, and each view's active
;;; region (between its point and its mark) in the region class, in every
;;; view that has one (Emacs shows it only in the selected window). A view's status line
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
;;; element carries its token (data-item); a line's token and id stay with
;;; its text, through scrolling and through edits around it (Line
;;; identity, below), so a morph moves lines rather than rewriting them
;;; and the browser's scroll anchoring holds what you read still. The
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
;;; is not a piece: the layout adds its own attributes to it. A text
;;; node's piece draws each of its lines as a piece of its own, whose
;;; inputs are values: the line's characters, its runs of faces, the
;;; cursor's column in it, the columns of the active region in it and its
;;; birth; never its position or the text's revision. So a key draws one line again, moving point one or two, and
;;; a line inserted above the others none of them; what those values come
;;; from (one piece per text node and view, which reads the text and its
;;; highlights) is worked out again, but no other line is drawn. Pieces
;;; hold what they drew from them, so an unchanged subtree is reused by
;;; one check, and the screen asked for when nothing changed is the very
;;; same object. A piece's HTML is UTF-8 bytes (the renderer contract's
;;; HTML), and a parent refers to its children's HTML rather than copying
;;; it, so a piece drawn again writes only its own tags. CR and NUL in
;;; text are written as character references. Every redraw still sends
;;; the whole visible screen as one fat morph. A view reads
;;; what its client's browser measured, so screens and views are each
;;; client's; a node's HTML is shared by every client drawing the same
;;; items of it. So a node renderer must draw only from its node, its
;;; children's renderings (HTML drawn already, to place as they are), and what it
;;; reads through contracts' accessors. Drawing writes nothing: before it,
;;; each client's views of the views shown are made; after it, the births
;;; of the lines drawn are kept (below).
;;;
;;; Line identity: a line a view draws is named by its birth, (END .
;;; REVISION), a position in it and the text's character revision when
;;; the view first drew it (its end then). Its token is a line item's,
;;; "N.END.REVISION", which the buffers contract resolves through the
;;; text's journal, and its element id is view-V-node-N-line-END-REVISION.
;;; Each view keeps, for each text node, the births of the lines it drew
;;; (line-births), shared by every client; drawing reads them, moved
;;; through the text's changes since (births-now): a line keeps its birth
;;; while a position of it moves with edits as point does, so typing in a
;;; line keeps it, and so does a line inserted where it starts, which is
;;; born anew; a line that has none is born when it is drawn. After a
;;; screen is drawn, the births of the lines it drew are kept at the
;;; text's revision, which gives every line the birth it was drawn with,
;;; so it changes no HTML; births of lines no client's last screen drew
;;; are dropped. A birth from a revision the text's journal no longer
;;; reaches is born again, since its token would name nothing.

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

;; The births of the lines of one text node as a view drew them (see
;; Line identity in the header): at character revision REVISION, entry I
;; is a line holding position (vector-ref ENDS I), which was line
;; (vector-ref LINES I), born (vector-ref BIRTHS I); ENDS ascending.
;; CURRENT caches what they are at a later revision: (REVISION .
;; line-births), which changes how they are kept, never what they are.
(defclass line-births ((revision : :fixnum)
                       (ends     : :vector)
                       (lines    : :vector)
                       (births   : :vector)
                       (current  :? :pair))
  final: #t)

;; What a client's last screen was, and the births of the lines it drew:
;; ((VIEW-ID NODE-ID . BIRTHS) ...), BIRTHS a vector.
(defclass client-screen ((screen : :t)
                         (drawn  : :list))
  final: #t)

;; PIECES: the screens, views, nodes and lines drawn. BIRTHS: view id ->
;; text node id -> line-births. SCREENS: client (#f: none) ->
;; client-screen.
(defclass html-rendering ((pieces  : memo-cache)
                          (births  : HashTable)
                          (screens : HashTable))
  final: #t)

;; The lines FIRST to LAST (from 1) of text node TEXT-NODE, drawn by
;; RENDERING, as items when ITEMS? (each with its token and an element
;; id), or whole inside an item.
(defstruct line-run ((text-node : node)
                     (first     : :fixnum)
                     (last      : :fixnum)
                     (items?    : :boolean)
                     (rendering : html-rendering))
  final: #t)

;; The view whose buffer is being rendered: where its text nodes show point.
;; Each node's piece binds it from its key.
(def rendering-view (make-parameter #f))

;; The line-run of the text node being rendered. Each text node's piece
;; binds it from its inputs.
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

;; MARKUP, SXML that may hold HTML drawn already (the renderer contract's
;; HTML: a u8vector or a vector) anywhere an element may be, as HTML. What
;; was drawn already is referred to, never copied: an element holding some
;; is its tags around its body's parts, and only the markup between is
;; written (sxml-bytes).
(def (markup->html (markup : :t)) => :t
  (let (parts (markup-parts markup []))
    (if (and (pair? parts) (null? (cdr parts)))
      (car parts)
      (list->vector parts))))

(def (html? (x : :t)) => :boolean
  (or (u8vector? x) (vector? x)))

;; Whether MARKUP holds HTML drawn already.
(def (holds-html? (markup : :t)) => :boolean
  (or (html? markup)
      (and (pair? markup)
           (ormap holds-html? (if (symbol? (car markup)) (cdr markup) markup)))))

;; MARKUP's HTML as parts, before REST.
(def (markup-parts (markup : :t) (rest : :list)) => :list
  (cond
   ((html? markup) (cons markup rest))
   ((not (holds-html? markup)) (cons (sxml-bytes markup) rest))
   ((symbol? (car markup))
    (let* ((tag (car markup))
           (attributes (and (pair? (cdr markup)) (pair? (cadr markup)) (eq? (car (cadr markup)) '@)
                            (cadr markup)))
           (body (if attributes (cddr markup) (cdr markup)))
           (close (string->utf8 (string-append "</" (symbol->string tag) ">")))
           (shell (sxml-bytes (if attributes [tag attributes] [tag]))))
      (cons (subu8vector shell 0 (fx- (u8vector-length shell) (u8vector-length close)))
            (body-parts body (cons close rest)))))
   (else (body-parts markup rest))))

;; The parts of the nodes BODY, before REST: each run of nodes holding no
;; HTML drawn already written at once.
(def (body-parts (body : :list) (rest : :list)) => :list
  (let lp ((body body) (plain []))
    (def (flush (rest : :list)) => :list
      (if (null? plain) rest (cons (sxml-bytes (reverse plain)) rest)))
    (cond
     ((null? body) (flush rest))
     ((holds-html? (car body)) (flush (markup-parts (car body) (lp (cdr body) []))))
     (else (lp (cdr body) (cons (car body) plain))))))

;; MARKUP, holding no HTML drawn already, as UTF-8, with CR and NUL in its
;; text and attribute values written as character references (CR as
;; itself, NUL as U+FFFD, as HTML parsers read it), so no screen holds
;; them raw: the screen stream cannot carry them (Datastar's elements
;; lines).
(def (sxml-bytes (markup : :t)) => :u8vector
  (let (port (open-output-u8vector (list char-encoding: 'UTF-8)))
    (write-sxml markup port: port xml?: #f)
    (escape-cr-nul (get-output-u8vector port))))

(def cr-reference (string->utf8 "&#13;"))
(def nul-reference (string->utf8 "&#xFFFD;"))

;; BYTES with each CR and NUL byte replaced by its character reference;
;; BYTES itself when it has none.
(def (escape-cr-nul (bytes : :u8vector)) => :u8vector
  (let ((size (u8vector-length bytes)))
    (def (special? (b : :fixnum)) => :boolean
      (or (fx= b 13) (fx= b 0)))
    (if (let lp ((i 0))
          (and (fx< i size) (or (special? (u8vector-ref bytes i)) (lp (fx1+ i)))))
      (let lp ((i 0) (run 0) (out []))
        (cond
         ((fx= i size)
          (apply u8vector-append (reverse (cons (subu8vector bytes run size) out))))
         ((special? (u8vector-ref bytes i))
          (lp (fx1+ i) (fx1+ i)
              (cons* (if (fx= (u8vector-ref bytes i) 13) cr-reference nul-reference)
                     (subu8vector bytes run i) out)))
         (else (lp (fx1+ i) run out))))
      bytes)))

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
(def (render-node (self : html-rendering) (v : view) (n : node) (run : :t)) => :t
  (memo ['node (view-id v) (node-id n)] run (lambda (run) (draw-node self v n run))))

(def (draw-node (self : html-rendering) (v : view) (n : node) (run : :t)) => :t
  (let* ((kind (node-kind n))
         (render (node-renderer kind))
         (lines (and (eq? (node-opening n) 'lines)
                     (if (pair? run)
                       (make-line-run n (fx1+ (: (car run) :fixnum)) (fx1+ (: (cdr run) :fixnum)) #t self)
                       (make-line-run n 1 (text-line-count (text-node-content n)) #f self))))
         (children (map (lambda ((child-run : :pair)) (render-node self v (car child-run) (cdr child-run)))
                        (drawn-children n run))))
    (parameterize ((rendering-view v)
                   (rendering-lines lines))
      (markup->html
       (with-node-id n
         (if render
           (render n children)
           `(div (@ (class "node") (data-kind ,(symbol->string kind)))
                 ,@(if (null? children) [(node-text-projection n)] children)))
         (eq? run 'item))))))

;;; Line identity

;; The line-births of the lines of T that V drew in N, as kept: at T's
;; revision R, from KEPT (#f: none), moved through T's changes since.
;; Each change keeps the lines of positions before it, gives positions in
;; what it removed the line of its start, and moves the lines of
;; positions after it by its change in newlines; so no line is looked up.
;; Of entries that land on one line, the first keeps it. Without changes
;; since KEPT's revision in the journal, nothing is kept. Births whose
;; revision the journal no longer reaches are born again at R.
(def (births-now (t : text) (kept :? line-births)) => line-births
  (let ((r (text-chars-revision t))
        (none (lambda ((r : :fixnum)) (line-births revision: r ends: (vector) lines: (vector) births: (vector) current: #f))))
    (cond
     ((not kept) (none r))
     ((fx= (line-births-revision kept) r) kept)
     ((let (current (line-births-current kept)) (and current (fx= (car current) r) (cdr current)))
      => values)
     (else
      (using (kept : line-births)
        (let* ((changes (text-changes-since t kept.revision))
               (now (if changes (moved-births t kept changes r) (none r))))
          (set! kept.current (cons r now))
          now))))))

(def (newlines (s : :string) (end : :fixnum)) => :fixnum
  (let lp ((i 0) (count 0))
    (if (fx< i end)
      (lp (fx1+ i) (if (char=? (string-ref s i) #\newline) (fx1+ count) count))
      count)))

;; KEPT's entries moved through CHANGES to T's revision R (births-now).
(def (moved-births (t : text) (kept : line-births) (changes : :list) (r : :fixnum)) => line-births
  (let* ((size (vector-length kept.ends))
         (ends (vector-copy kept.ends))
         (lines (vector-copy kept.lines)))
    (for-each
     (lambda ((c : change))
       (let* ((removed (string-length (change-removed c)))
              (edit-end (fx+ (change-start c) removed))
              (shift (fx- (string-length (change-inserted c)) removed))
              (line-shift (fx- (newlines (change-inserted c) (string-length (change-inserted c)))
                               (newlines (change-removed c) removed))))
         (let lp ((i 0))
           (when (fx< i size)
             (let (position (vector-ref ends i))
               (cond
                ((fx<= position (change-start c)) (void))
                ((fx>= position edit-end)
                 (vector-set! ends i (fx+ position shift))
                 (vector-set! lines i (fx+ (vector-ref lines i) line-shift)))
                (else
                 (vector-set! ends i (change-start c))
                 (vector-set! lines i (fx- (vector-ref lines i)
                                           (newlines (change-removed c) (fx- position (change-start c))))))))
             (lp (fx1+ i))))))
     changes)
    ;; One entry per line, the first; births the journal reaches.
    (let ((reached (make-hash-table-eqv)))
      (def (reached? (revision : :fixnum))
        (let (known (hash-ref reached revision 'unknown))
          (if (eq? known 'unknown)
            (let (yes (and (text-changes-since t revision) #t))
              (hash-put! reached revision yes)
              yes)
            known)))
      (let lp ((i 0) (last-line 0) (out-ends []) (out-lines []) (out-births []))
        (if (fx< i size)
          (let ((line (vector-ref lines i))
                (birth (vector-ref kept.births i)))
            (if (fx= line last-line)
              (lp (fx1+ i) last-line out-ends out-lines out-births)
              (lp (fx1+ i) line (cons (vector-ref ends i) out-ends) (cons line out-lines)
                  (cons (if (reached? (cdr birth)) birth (cons (text-line-end t line) r)) out-births))))
          (line-births revision: r ends: (list->vector (reverse out-ends)) lines: (list->vector (reverse out-lines))
                       births: (list->vector (reverse out-births)) current: #f))))))

;; Where LINE is among NOW's entries, or #f.
(def (entry-of (now : line-births) (line : :fixnum)) => (Maybe :fixnum)
  (let ((lines (line-births-lines now)))
    (let search ((low 0) (high (vector-length lines)))
      (and (fx< low high)
           (let* ((middle (fxquotient (fx+ low high) 2))
                  (at (vector-ref lines middle)))
             (cond
              ((fx= at line) middle)
              ((fx< at line) (search (fx1+ middle) high))
              (else (search low middle))))))))

;; The birth of LINE by NOW (births-now), if it has one.
(def (entry-birth (now : line-births) (line : :fixnum)) => (Maybe :pair)
  (let (i (entry-of now line))
    (and i (vector-ref (line-births-births now) i))))

;; The birth of LINE of T, by NOW (births-now): its entry's, or, without
;; one, now: (its end . T's revision).
(def (line-birth (t : text) (now : line-births) (line : :fixnum)) => :pair
  (or (entry-birth now line)
      (cons (text-line-end t line) (line-births-revision now))))

;; What V's births of N's lines are now (births-now).
(def (view-births-now (self : html-rendering) (v : view) (n : node)) => line-births
  (births-now (text-node-content n)
              (let (kept (hash-get self.births (view-id v)))
                (and kept (hash-get kept (node-id n))))))

;; The token of N's line born BIRTH: a line item's, "N.P.R", by the
;; position and revision it was born at.
(def (birth-token (n : node) (birth : :pair)) => :string
  (string-append (number->string (node-id n)) "." (number->string (car birth)) "." (number->string (cdr birth))))

;;; Lines

;; What each of N's lines FIRST to LAST in V draws from, but for the
;; cursor: [END REVISION ITEMS? TEXT FACES], END and REVISION its birth,
;; TEXT its characters, FACES its runs of faced characters, (START-COLUMN
;; END-COLUMN . FACE), through the face-remapping of V's buffer. Spans
;; overlapping a line apply in the order text-highlights-in gives them,
;; later over earlier.
(def (line-descriptors (self : html-rendering) (v : view) (n : node) (first : :fixnum) (last : :fixnum)
                       (items? : :boolean))
  => :vector
  (let* ((t (text-node-content n))
         (b (view-showing v))
         (now (view-births-now self v n))
         (s (text-snapshot t))
         (size (snapshot-size s))
         (count (snapshot-line-count s))
         ;; Where LINE ends, before its newline.
         (line-end (lambda ((line : :fixnum) (next-start : :fixnum))
                     (if (fx= line count) (fx1+ size) (fx1- next-start))))
         (drawn-start (snapshot-line-start s first))
         (drawn-end (if (fx= last count) (fx1+ size) (fx1- (snapshot-line-start s (fx1+ last)))))
         (spans (list->vector (text-highlights-in t drawn-start drawn-end)))
         ;; Span indexes ordered by start, and those that may overlap the
         ;; line being worked out, in order.
         (by-start (list->vector (list-sort (lambda ((i : :fixnum) (j : :fixnum))
                                              (fx< (span-start (vector-ref spans i)) (span-start (vector-ref spans j))))
                                            (iota (vector-length spans)))))
         (faces-of (make-hash-table-eq))
         (out (make-vector (fx1+ (fx- last first)) #f)))
    (def (face (s : span)) => :symbol
      (let (value (span-value s))
        (or (hash-get faces-of value)
            (let (remapped (remapped-face value b))
              (hash-put! faces-of value remapped)
              remapped))))
    (let lp ((line first) (start drawn-start) (next 0) (active []))
      (when (fx<= line last)
        (let* ((next-start (if (fx= line count) (fx+ size 2) (snapshot-line-start s (fx1+ line))))
               (end (line-end line next-start))
               (content (snapshot-slice s start end)))
          ;; Spans starting before the line's end join; those ending at or
          ;; before its start leave.
          (let add ((next next) (active active))
            (if (and (fx< next (vector-length by-start))
                     (fx< (span-start (vector-ref spans (vector-ref by-start next))) end))
              (add (fx1+ next) (cons (vector-ref by-start next) active))
              (let* ((active (filter (lambda ((i : :fixnum)) (fx> (span-end (vector-ref spans i)) start)) active))
                     (birth (or (entry-birth now line) (cons end (line-births-revision now)))))
                (vector-set! out (fx- line first)
                             [(car birth) (cdr birth) items? content
                              (face-runs (string-length content) start
                                         (map (lambda ((i : :fixnum)) (vector-ref spans i)) (list-sort fx< active))
                                         face)])
                (lp (fx1+ line) next-start next active)))))))
    out))

;; The runs of faced characters of a line of SIZE characters starting at
;; text position START, under SPANS (later over earlier):
;; ((START-COLUMN END-COLUMN . FACE) ...).
(def (face-runs (size : :fixnum) (start : :fixnum) (spans : :list) (face : :procedure)) => :list
  (if (null? spans)
    []
    (let (faces (make-vector size #f))
      (for-each (lambda ((s : span))
                  (let (f (face s))
                    (let lp ((i (fxmax 0 (fx- (span-start s) start))))
                      (when (fx< i (fxmin size (fx- (span-end s) start)))
                        (vector-set! faces i f)
                        (lp (fx1+ i))))))
                spans)
      (let lp ((i 0) (out []))
        (cond
         ((fx>= i size) (reverse out))
         ((vector-ref faces i)
          => (lambda (f)
               (let run ((j (fx1+ i)))
                 (if (and (fx< j size) (eq? (vector-ref faces j) f))
                   (run (fx1+ j))
                   (lp j (cons (cons* i j f) out))))))
         (else (lp (fx1+ i) out)))))))

;; A text node: one element per line, each drawn as its own piece, with
;; the cursor when the node has the rendered view's focus; only the lines
;; drawn as items, each with its token and an id that stays with its
;; text, when it is drawn as items (see Line identity).
(def (render-text-node (n : node) (children : :list)) => :list
  (using (lines (rendering-lines) : line-run)
    (let* ((v (rendering-view))
           (self lines.rendering)
           (first lines.first)
           (last lines.last)
           (items? lines.items?)
           (descriptors (memo ['lines (view-id v) (node-id n)] [first last items?]
                              (lambda (inputs) (line-descriptors self v n first last items?))))
           (t (text-node-content n))
           (position (and (eq? n (view-node v)) (view-point v)))
           (cursor-line (and position (text-line-at t position)))
           (cursor (and position
                        (cons (text-column t position) (if (eq? v (selected-view)) "cursor" "inactive-cursor"))))
           (region (and position (view-mark-active? v) (active-region t position (view-mark v)))))
      `(div (@ (class "text"))
            ,@(let lp ((line last) (out []))
                (if (fx< line first)
                  out
                  (let (d (vector-ref descriptors (fx- line first)))
                    (lp (fx1- line)
                        (cons (memo ['line (view-id v) (node-id n) (car d) (cadr d)]
                                    (append d [(and (eqv? line cursor-line) cursor)
                                               (and region (line-region region line (string-length (list-ref d 3))))])
                                    (lambda (inputs) (draw-line v n inputs)))
                              out)))))))))

;; The region of T from POSITION to MARK, when it is not empty: its first
;; and last lines, and its columns in them, [FIRST-LINE START-COLUMN
;; LAST-LINE END-COLUMN]; or #f.
(def (active-region (t : text) (position : :fixnum) (mark :? :fixnum)) => (Maybe :list)
  (and mark (not (fx= mark position))
       (let ((start (fxmin mark position))
             (end (fxmax mark position)))
         [(text-line-at t start) (text-column t start) (text-line-at t end) (text-column t end)])))

;; What of LINE, of SIZE characters, REGION (active-region) covers, as a
;; line's input: [START-COLUMN END-COLUMN NEWLINE?], NEWLINE? when it also
;; covers the newline after the line; or #f.
(def (line-region (region : :list) (line : :fixnum) (size : :fixnum)) => (Maybe :list)
  (match region
    ([first-line start-column last-line end-column]
     (and (fx<= first-line line last-line)
          (let ((start (if (fx= line first-line) start-column 0))
                (end (if (fx= line last-line) end-column size))
                (newline? (fx< line last-line)))
            (and (or newline? (fx< start end))
                 [start end newline?]))))))

;; A line of N in V from its inputs, [END REVISION ITEMS? TEXT FACES
;; CURSOR REGION] (line-descriptors, line-region): runs of characters with
;; the same face, in the region or not, and the cursor character alone at
;; CURSOR's column, with its class; as an item, with its token and its
;; element id.
(def (draw-line (v : view) (n : node) (inputs : :list)) => :u8vector
  (match inputs
    ([end revision items? content faces cursor region]
     (sxml-bytes
      (render-line content faces (and cursor (car cursor)) (if cursor (cdr cursor) "") region
                   (if items?
                     (let (birth (cons end revision))
                       [['data-item (birth-token n birth)]
                        ['id (string-append (view-element-id v) "-node-" (number->string (node-id n))
                                            "-line-" (number->string end) "-" (number->string revision))]])
                     []))))))

;; One line, with ATTRIBUTES besides its class: runs of characters with
;; the same face (FACES, as face-runs gives them), in the region or not
;; (REGION, as line-region gives it, or #f), and the cursor character
;; alone at column CURSOR, with the class CURSOR-CLASS. A region covering
;; the newline marks the line (data-region-newline), unless the cursor is
;; drawn there.
(def (render-line (content : :string) (faces : :list) (cursor :? :fixnum) (cursor-class : :string)
                  (region :? :list) (attributes : :list))
  => :list
  (let* ((size (string-length content))
         (face-at (make-vector size #f))
         (region-start (if region (car region) size))
         (region-end (if region (cadr region) size))
         (in-region? (lambda ((i : :fixnum)) (and (fx<= region-start i) (fx< i region-end))))
         (newline? (and region (caddr region) (not (eqv? cursor size)))))
    (for-each (lambda ((run : :pair))
                (let lp ((i (car run)))
                  (when (fx< i (cadr run))
                    (vector-set! face-at i (cddr run))
                    (lp (fx1+ i)))))
              faces)
    `(div (@ (class "line") ,@(if newline? [['data-region-newline ""]] []) ,@attributes)
          ,@(let lp ((i 0) (out []))
              (cond
               ((fx>= i size)
                (reverse (if (eqv? cursor size) (cons (cursor-span cursor-class " " #f) out) out)))
               ((eqv? i cursor)
                (lp (fx1+ i) (cons (cursor-span cursor-class (substring content i (fx1+ i))
                                                (vector-ref face-at i))
                                   out)))
               (else
                (let* ((face (vector-ref face-at i))
                       (selected? (in-region? i))
                       (end (let run ((j (fx1+ i)))
                              (if (and (fx< j size) (not (eqv? j cursor))
                                       (eq? (vector-ref face-at j) face)
                                       (eq? (in-region? j) selected?))
                                (run (fx1+ j))
                                j)))
                       (characters (substring content i end))
                       (class (cond
                               ((and face selected?) (string-append (face-class face) " region"))
                               (face (face-class face))
                               (selected? "region")
                               (else #f))))
                  (lp end (cons (if class
                                  `(span (@ (class ,class)) ,characters)
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
;; START's items, the view goes to its start. The target is named by the
;; token its element carries (drawn-token).
(def (placement-marker (self : html-rendering) (v : view) (cv : client-view) (start : node)) => :list
  (let* ((p (client-view-placement cv))
         (number (number->string (placement-number p)))
         (target (let (it (placement-target p))
                   (and it (node-item-index start it) it))))
    `(div (@ (class "placement") (hidden "")
             (id ,(string-append (view-element-id v) "-placement-" number))
             (data-init "@tunaPlace()")
             (data-placement ,number)
             ,@(if target [['data-target (drawn-token self v target)]] [])
             (data-align ,(symbol->string (placement-align p)))
             (data-offset ,(number->string (placement-offset p)))))))

;; The token IT's element carries in V: a line's by its birth.
(def (drawn-token (self : html-rendering) (v : view) (it : item)) => :string
  (let ((n (item-node it))
        (line (item-line it)))
    (if line
      (birth-token n (line-birth (text-node-content n) (view-births-now self v n) line))
      (item-token it))))

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
       ,(memo ['view (view-id v)] [(node-id start) (and selected? command)]
              (lambda (inputs) (draw-view self c v start (cadr inputs)))))))

;; V's buffer from node START, then its status line unless its buffer
;; turns it off.
(def (draw-view (self : html-rendering) (c :? client) (v : view) (start : node) (command :? :symbol))
  => :t
  (let* ((b (view-showing v))
         (cv (view-client v c))
         (id (number->string (view-id v))))
    (using (drawn (items-drawn cv start) : drawn-items)
      (let* ((count drawn.count)
             (first drawn.first)
             (last drawn.last)
             (above (spacer v cv "above" first first last))
             (below (spacer v cv "below" (fx- count (fx1+ last)) first last)))
        (markup->html
         (cons `(article (@ (class "buffer") (aria-label ,(buffer-name b))
                            ,@(scroller-attributes v cv start first last count))
                         ,(placement-marker self v cv start)
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

(def (draw-screen (self : html-rendering) (c :? client) (command :? :symbol)) => :t
  (markup->html
   `(main (@ (id "screen") (class "screen"))
          ,(render-layout 'html (lambda (v selected? start) (render-view self c v selected? start command))))))

;; After drawing SCREEN for client C, when it is a new one: keep the
;; births of the lines of each text node each view drew (keep-births!),
;; and drop those of lines no client's last screen drew once they may
;; have piled up (births-outgrown?).
(def (after-drawing! (self : html-rendering) (c :? client) (screen : :t)) => :void
  (let (kept (hash-get self.screens c))
    (unless (and kept (eq? (client-screen-screen kept) screen))
      (let (drawn [])
        (render-layout 'views
                       (lambda (v selected? start)
                         (using (items (items-drawn (view-client v c) start) : drawn-items)
                           (let walk ((n start) (run (item-run start items.first items.last)))
                             (if (eq? (node-opening n) 'lines)
                               (let (t (text-node-content n))
                                 (set! drawn (cons (keep-births! self v n
                                                                 (if (pair? run) (fx1+ (: (car run) :fixnum)) 1)
                                                                 (if (pair? run) (fx1+ (: (cdr run) :fixnum)) (text-line-count t)))
                                                   drawn)))
                               (for-each (lambda ((child-run : :pair)) (walk (car child-run) (cdr child-run)))
                                         (drawn-children n run)))))))
        (hash-put! self.screens c (client-screen screen: screen drawn: drawn))
        (when (births-outgrown? self)
          (drop-undrawn-births! self))))))

;; Whether births of lines no client's last screen drew may have piled up:
;; kept for a text node no client drew, or more of them than twice the
;; lines the clients drew of it, and a few more. Dropping them only when
;; they do keeps a screen's cost from growing with every client's lines.
(def (births-outgrown? (self : html-rendering)) => :boolean
  (let (drawn (make-hash-table))        ; (view-id . node-id) -> lines drawn, over all clients
    (hash-for-each (lambda (c (screen : client-screen))
                     (for-each (lambda ((entry : :pair))
                                 (hash-update! drawn (cons (car entry) (cadr entry))
                                               (lambda ((count : :fixnum)) (fx+ count (vector-length (cddr entry))))
                                               0))
                               screen.drawn))
                   self.screens)
    (hash-fold (lambda (view-id (table : HashTable) (outgrown? : :boolean))
                 (or outgrown?
                     (hash-fold (lambda (node-id (kept : line-births) (outgrown? : :boolean))
                                  (or outgrown?
                                      (let (count (hash-get drawn (cons view-id node-id)))
                                        (or (not count)
                                            (fx> (vector-length (line-births-births kept)) (fx+ 64 (fx* 2 count)))))))
                                #f table)))
               #f self.births)))

;; After drawing N's lines FIRST to LAST in V: keep their births, with
;; the entries kept before, at the text's revision, which gives every line
;; the birth it was drawn with. Returns (VIEW-ID NODE-ID . BIRTHS), BIRTHS
;; the drawn lines' births. In test mode, check that the births stay.
(def (keep-births! (self : html-rendering) (v : view) (n : node) (first : :fixnum) (last : :fixnum)) => :pair
  (let* ((t (text-node-content n))
         (now (view-births-now self v n))
         (births (make-vector (fx1+ (fx- last first)) #f)))
    (let lp ((line first))
      (when (fx<= line last)
        (vector-set! births (fx- line first) (line-birth t now line))
        (lp (fx1+ line))))
    (let ((kept (hash-get self.births (view-id v)))
          (covered? (let lp ((line first))
                      (or (fx> line last) (and (entry-of now line) (lp (fx1+ line)))))))
      (unless (and covered? kept (eq? (hash-get kept (node-id n)) now))
        ;; The entries now, with the drawn lines that have none, in line order.
        (let lp ((i 0) (line first) (ends []) (lines []) (out []))
          (let ((entry-line (and (fx< i (vector-length (line-births-lines now)))
                                 (vector-ref (line-births-lines now) i)))
                (next-line (and (fx<= line last) line)))
            (cond
             ((and entry-line (or (not next-line) (fx<= entry-line next-line)))
              (lp (fx1+ i) (if (eqv? entry-line next-line) (fx1+ line) line)
                  (cons (vector-ref (line-births-ends now) i) ends) (cons entry-line lines)
                  (cons (vector-ref (line-births-births now) i) out)))
             (next-line
              (lp i (fx1+ line) (cons (text-line-end t line) ends) (cons line lines)
                  (cons (vector-ref births (fx- line first)) out)))
             (else
              (let (table (or kept (let (new (make-hash-table-eqv)) (hash-put! self.births (view-id v) new) new)))
                (hash-put! table (node-id n)
                           (line-births revision: (line-births-revision now)
                                        ends: (list->vector (reverse ends)) lines: (list->vector (reverse lines))
                                        births: (list->vector (reverse out)) current: #f))))))))
      (when (and (memo-checking?)
                 (not (let (again (view-births-now self v n))
                        (let lp ((line first))
                          (or (fx> line last)
                              (and (equal? (line-birth t again line) (vector-ref births (fx- line first)))
                                   (lp (fx1+ line))))))))
        (error "Keeping line births changed them" (view-id v) (node-id n))))
    (cons* (view-id v) (node-id n) births)))

;; Drop the births of lines no client's last screen drew.
(def (drop-undrawn-births! (self : html-rendering)) => :void
  (let (drawn (make-hash-table))        ; (view-id . node-id) -> birth -> #t
    (hash-for-each (lambda (c (screen : client-screen))
                     (for-each (lambda ((entry : :pair))
                                 (let* ((key (cons (car entry) (cadr entry)))
                                        (births (or (hash-get drawn key)
                                                    (let (new (make-hash-table)) (hash-put! drawn key new) new))))
                                   (vector-for-each (lambda (birth) (hash-put! births birth #t)) (cddr entry))))
                               screen.drawn))
                   self.screens)
    (for-each
     (lambda (view-id)
       (let (table (hash-ref self.births view-id))
         (for-each
          (lambda (node-id)
            (let ((births (hash-get drawn (cons view-id node-id)))
                  (kept (hash-ref table node-id)))
              (if (not births)
                (hash-remove! table node-id)
                (using (kept : line-births)
                  (let (keep (filter (lambda ((i : :fixnum)) (hash-key? births (vector-ref kept.births i)))
                                     (iota (vector-length kept.births))))
                    (unless (fx= (length keep) (vector-length kept.births))
                      (hash-put! table node-id
                                 (line-births revision: kept.revision
                                              ends: (list->vector (map (cut vector-ref kept.ends <>) keep))
                                              lines: (list->vector (map (cut vector-ref kept.lines <>) keep))
                                              births: (list->vector (map (cut vector-ref kept.births <>) keep))
                                              current: #f))))))))
          (hash-keys table))
         (when (fxzero? (hash-length table))
           (hash-remove! self.births view-id))))
     (hash-keys self.births))))

;; Client C's screen: its last one when nothing it was drawn from changed,
;; otherwise drawn again, through the pieces kept. Before drawing, each
;; view shown gets C's view of it, so drawing makes none.
(def (render-screen! (self : html-rendering) (c :? client)) => :t
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
  (using (self (html-rendering pieces: (new-memo-cache) births: (make-hash-table-eqv) screens: (make-hash-table-eq))
               : html-rendering)
    (context-add-hook! ctx client-gone-hook 'html-renderer
                       (lambda ((c : client))
                         (memo-forget-client! self.pieces c)
                         (hash-remove! self.screens c)
                         (drop-undrawn-births! self)))
    (context-provide! ctx renderer-service (Renderer self))))

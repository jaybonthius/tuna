;;; A terminal's rows as buffer nodes (ADR 15, ADR 17): every row the
;;; mirror holds, scrollback and active screen, is a node that is one item,
;;; so a view scrolls through them like any other items and the renderer
;;; draws only those near what each browser tab shows. A row node's
;;; attributes are plain data, its runs and the cursor on it, so setting a
;;; row to what it already shows changes nothing and draws nothing.
;;;
;;; A row node's attributes are its NUMBER (fixed), its RUNS, WRAP (whether
;;; the program's line goes on in the next row), PROMPT (how a shell's
;;; integration marked it, row-prompt-mark) and the CURSOR on it.
;;;
;;; Rows are grouped under block nodes of `block-size` rows, so adding a
;;; row, or trimming the oldest, changes one block's children and not a
;;; list of every row. A row's number comes from the mirror
;;; (terminal-row-numbering): numbers survive trimming; a new generation
;;; (a reflow, a reset, a cleared scrollback) numbers every row anew, and
;;; its rows are new nodes.
;;;
;;; A run is a vector #(COLUMN WIDTH TEXT CLASSES STYLE LINK): the cells it
;;; starts at and covers, its text, its class names, the custom
;;; properties of its exact colours (#f for none), and the URI it links
;;; to, from OSC 8 or found in the text (links.ss), or #f. Palette colours are
;;; classes, which the plugin's stylesheet maps to CSS variables, so a
;;; theme decides them; a colour the program gave exactly passes through.
prelude: :gerbil/core

(import (only-in :gerbil/runtime/hash HashTable)
        :tuna/plugins/buffers/contract
        (only-in :gerbil-libghostty/ghostty
                 styled-row-number styled-row-runs styled-row-semantic-prompt
                 styled-run-column styled-run-width styled-run-text styled-run-style styled-run-hyperlink
                 styled-run-semantic-content
                 render-style-foreground render-style-background render-style-underline-color
                 render-style-bold? render-style-italic? render-style-faint? render-style-blink?
                 render-style-inverse? render-style-invisible? render-style-strikethrough?
                 render-style-overline? render-style-underline
                 render-style-color-type render-style-color-value
                 color-rgb-r color-rgb-g color-rgb-b
                 unicode-codepoint-width))
(export row-runs
        row-prompt-mark
        char-cells
        row-sxml
        block-size
        (struct-out row-store)
        new-row-store
        row-store-reset!
        row-store-trim!
        row-store-extend!
        row-store-row
        row-store-end
        row-store-blocks
        row-store-last-row
        row-store-set-extra!)

;;; Rows as values

(def (hex2 (n : :fixnum)) => :string
  (string-append (if (fx< n 16) "0" "") (number->string n 16)))

(def (rgb-text (color : :t)) => :string
  (string-append "#" (hex2 (color-rgb-r color)) (hex2 (color-rgb-g color)) (hex2 (color-rgb-b color))))

;; The class and custom property of color C, the foreground, background or
;; underline (PART "fg", "bg", "underline"): (CLASSES . PROPERTIES).
(def (color-parts (c : :t) (part : :string) (property : :string)) => :pair
  (case (render-style-color-type c)
    ((palette) (cons [(string-append "terminal-" part "-" (number->string (render-style-color-value c)))] []))
    ((rgb) (cons [(string-append "terminal-" part "-rgb")]
                 [(string-append property ":" (rgb-text (render-style-color-value c)))]))
    (else (cons [] []))))

;; STYLE as (CLASSES . STYLE-ATTRIBUTE), the attribute #f without exact
;; colours.
(def (style-parts (style : :t)) => :pair
  (let* ((fg (color-parts (render-style-foreground style) "fg" "--terminal-run-foreground"))
         (bg (color-parts (render-style-background style) "bg" "--terminal-run-background"))
         (ul (color-parts (render-style-underline-color style) "underline" "--terminal-run-underline"))
         (underline (render-style-underline style))
         (flags (filter values
                        [(and (render-style-bold? style) "terminal-bold")
                         (and (render-style-italic? style) "terminal-italic")
                         (and (render-style-faint? style) "terminal-faint")
                         (and (render-style-blink? style) "terminal-blink")
                         (and (render-style-inverse? style) "terminal-inverse")
                         (and (render-style-invisible? style) "terminal-invisible")
                         (and (render-style-strikethrough? style) "terminal-strikethrough")
                         (and (render-style-overline? style) "terminal-overline")
                         (and (not (memq underline '(none #f)))
                              (string-append "terminal-underline-" (symbol->string underline)))]))
         (classes (append (car fg) (car bg) (car ul) flags))
         (properties (append (cdr fg) (cdr bg) (cdr ul))))
    (cons (string-join classes " ")
          (and (pair? properties) (string-join properties ";")))))

;; ROW, a styled row from the mirror, as a vector of runs (see the header).
(def (row-runs (row : :t)) => :vector
  (vector-map (lambda (run)
                (let (parts (style-parts (styled-run-style run)))
                  (vector (styled-run-column run) (styled-run-width run) (styled-run-text run)
                          (car parts) (cdr parts) (hyperlink-text (styled-run-hyperlink run)))))
              (styled-row-runs row)))

;; Whether TEXT is only white space.
(def (blank? (text : :string)) => :boolean
  (let lp ((i 0))
    (or (fx= i (string-length text))
        (and (char-whitespace? (string-ref text i)) (lp (fx1+ i))))))

;; What a shell's integration marked ROW, a styled row, as (OSC 133 and
;; libghostty's row marks): #f for no prompt, else #(KIND END INPUT?),
;; KIND 'prompt where a prompt starts or 'prompt-continuation for its
;; later rows, END the cell after its last prompt cell (#f with none) and
;; INPUT? whether it holds typed input.
(def (row-prompt-mark (row : :t)) => (Maybe :vector)
  (let (kind (styled-row-semantic-prompt row))
    (and (memq kind '(prompt prompt-continuation))
         (let lp ((runs (vector->list (styled-row-runs row))) (end #f) (input? #f))
           (match runs
             ([] (vector kind end input?))
             ([run . more]
              (case (styled-run-semantic-content run)
                ((prompt) (lp more (fx+ (styled-run-column run) (styled-run-width run)) input?))
                ((input) (lp more end (or input? (not (blank? (styled-run-text run))))))
                (else (lp more end input?)))))))))

;; An OSC 8 link's URI, or #f.
(def (hyperlink-text (bytes :? :u8vector)) => (Maybe :string)
  (and bytes (fx> (u8vector-length bytes) 0)
       (with-catch (lambda (e) #f) (lambda () (utf8->string bytes)))))

;; The cells character C takes.
(def (char-cells (c : :char)) => :fixnum
  (let (n (char->integer c))
    (if (fx< n #x300) 1 (unicode-codepoint-width n))))

;; TEXT split where it reaches COLUMNS cells: (BEFORE . AFTER).
(def (split-at-cells (text : :string) (columns : :fixnum)) => :pair
  (let lp ((i 0) (cells 0))
    (if (or (fx= i (string-length text)) (fx>= cells columns))
      (cons (substring text 0 i) (substring text i (string-length text)))
      (lp (fx1+ i) (fx+ cells (char-cells (string-ref text i)))))))

;; The first character of TEXT with the zero-width characters after it.
(def (first-cell (text : :string)) => :string
  (let lp ((i 1))
    (if (and (fx< i (string-length text)) (fx= 0 (char-cells (string-ref text i))))
      (lp (fx1+ i))
      (substring text 0 (fxmin i (string-length text))))))

;; The class sizing a cell that holds GRAPHEME to its cells on the grid:
;; terminal-cell-1 or terminal-cell-2.
(def (cell-class (grapheme : :string)) => :string
  (if (and (fx> (string-length grapheme) 0) (fx= 2 (char-cells (string-ref grapheme 0))))
    "terminal-cell terminal-cell-2"
    "terminal-cell terminal-cell-1"))

;; TEXT, part of a row, as SXML that keeps the cell grid whichever font
;; draws a glyph: runs of ASCII stay text, which the terminal's monospace
;; font draws one cell each; every other grapheme is a span exactly as
;; wide as the cells libghostty gives it, since a glyph missing from that
;; font (braille, box drawing, icons) comes from another font with other
;; widths.
(def (grid-pieces (text : :string)) => :list
  (let ((size (string-length text))
        (ascii? (lambda (i) (fx< (char->integer (string-ref text i)) #x80))))
    (def (cell (i : :fixnum) (out : :list)) => :list
      (let (grapheme (first-cell (substring text i size)))
        (lp (fx+ i (string-length grapheme)) (cons `(span (@ (class ,(cell-class grapheme))) ,grapheme) out))))
    (def (lp (i : :fixnum) (out : :list)) => :list
      (cond
       ((fx= i size) (reverse out))
       ((ascii? i)
        (let ascii ((j (fx1+ i)))
          (cond
           ((and (fx< j size) (ascii? j)) (ascii (fx1+ j)))
           ;; A combining mark after it: the last ASCII character and
           ;; its marks are one grapheme.
           ((and (fx< j size) (fx= 0 (char-cells (string-ref text j))))
            (cell (fx1- j) (if (fx> (fx1- j) i) (cons (substring text i (fx1- j)) out) out)))
           (else (lp j (cons (substring text i j) out))))))
       (else (cell i out))))
    (lp 0 [])))

;; BODY, strings and elements, with each string kept on the grid.
(def (grid-body (body : :list)) => :list
  (let lp ((body body) (out []))
    (match body
      ([] (reverse out))
      ([(? string? piece) . more] (lp more (append (reverse (grid-pieces piece)) out)))
      ([piece . more] (lp more (cons piece out))))))

(def (run-element (classes : :string) (style :? :string) (body : :list)) => :t
  (let (body (grid-body body))
    (if (and (string-empty? classes) (not style))
      (if (and (pair? body) (null? (cdr body)) (string? (car body))) (car body) `(span ,@body))
      `(span (@ (class ,(string-append "terminal-run " classes)) ,@(if style [['style style]] [])) ,@body))))

;; The cursor over TEXT, one grapheme, sized to its cells like any cell.
(def (cursor-element (cursor : :vector) (text : :string)) => :t
  (let (text (if (string-empty? text) " " text))
    `(span (@ (class ,(string-append (cell-class text) " terminal-cursor terminal-cursor-"
                                     (symbol->string (vector-ref cursor 1))
                                     (if (vector-ref cursor 2) " terminal-cursor-blink" ""))))
           ,text)))

;; The row of RUNS, with CURSOR (#(COLUMN STYLE BLINKING?) or #f) drawn
;; in it, as SXML: each run a span, blank columns between runs spaces.
(def (row-sxml (runs : :vector) (cursor :? :vector)) => :list
  (let ((at (and cursor (vector-ref cursor 0))))
    (let lp ((i 0) (column 0) (out []) (drawn? #f))
      (if (fx= i (vector-length runs))
        (reverse
         (if (and at (not drawn?))
           (cons (cursor-element cursor " ")
                 (if (fx> at column) (cons (make-string (fx- at column) #\space) out) out))
           out))
        (let* ((run (vector-ref runs i))
               (start (vector-ref run 0))
               (width (vector-ref run 1))
               (text (vector-ref run 2))
               (classes (vector-ref run 3))
               (style (vector-ref run 4))
               (link (and (fx> (vector-length run) 5) (vector-ref run 5)))
               (gap (if (fx> start column) [(make-string (fx- start column) #\space)] []))
               (out (append (reverse gap) out)))
          (if (and at (not drawn?) (fx<= start at) (fx< at (fx+ start width)))
            (let* ((split (split-at-cells text (fx- at start)))
                   (under (first-cell (cdr split)))
                   (after (substring (cdr split) (string-length under) (string-length (cdr split))))
                   (body (filter (lambda (part) (not (equal? part "")))
                                 [(car split) (cursor-element cursor under) after])))
              (lp (fx1+ i) (fx+ start width) (cons (linked (run-element classes style body) link) out) #t))
            (lp (fx1+ i) (fx+ start width) (cons (linked (run-element classes style [text]) link) out) drawn?)))))))

;; ELEMENT, a run, as a link to URI when there is one: a web address is an
;; <a> the browser opens in a new tab; any other the page script hands to
;; the plugin (data-terminal-link).
(def (linked (element : :t) (uri :? :string)) => :t
  (cond
   ((not uri) element)
   ((or (string-prefix? "http://" uri) (string-prefix? "https://" uri))
    `(a (@ (class "terminal-link") (href ,uri) (target "_blank") (rel "noopener noreferrer")
           (data-terminal-link ,uri))
        ,element))
   (else `(span (@ (class "terminal-link") (data-terminal-link ,uri) (title ,uri)) ,element))))

;;; The rows of one screen as nodes

(def block-size 64)

;; The row nodes of one screen of a terminal: ROWS, a vector from index
;; START holding COUNT nodes, numbered from BASE; BLOCK-NODES, block number
;; (row number divided by block-size) -> its node, holding its rows of
;; ROWS. GENERATION is the mirror's numbering they were made in, #f
;; before any.
;; EXTRA is a node shown after one row, (NODE . ROW-NUMBER), or #f: line
;; mode's input, after the cursor's row.
(defclass row-store ((generation :? :fixnum)
                     (base       : :integer)
                     (rows       : :vector)
                     (start      : :fixnum)
                     (count      : :fixnum)
                     (block-nodes : HashTable)
                     (extra      :? :pair))
  final: #t)

(def (new-row-store) => row-store
  (row-store generation: #f base: 0 rows: (make-vector 256 #f) start: 0 count: 0 block-nodes: (make-hash-table-eqv)
             extra: #f))

;; Show EXTRA-NODE after row NUMBER, or nothing extra with #f.
(def (row-store-set-extra! (s : row-store) (extra-node :? node) (number :? :integer)) => :void
  (let ((old s.extra)
        (new (and extra-node number (cons extra-node number))))
    (unless (and old new (eq? (car old) (car new)) (= (cdr old) (cdr new)))
      (set! s.extra new)
      (when old (refresh-block! s (block-of (cdr old))))
      (when new
        ;; A block a new generation replaced may still hold it.
        (let (parent (node-parent (car new)))
          (when parent (set-node-children! parent (remq (car new) (node-children parent)))))
        (refresh-block! s (block-of (cdr new)))))))

;; Forget every row; rows from now on are numbered in GENERATION, the
;; first BASE.
(def (row-store-reset! (s : row-store) (generation : :fixnum) (base : :integer)) => :void
  (set! s.generation generation)
  (set! s.base base)
  (set! s.rows (make-vector 256 #f))
  (set! s.start 0)
  (set! s.count 0)
  (set! s.extra #f)
  (hash-clear! s.block-nodes))

;; The number after S's last row.
(def (row-store-end (s : row-store)) => :integer
  (+ s.base s.count))

;; The node of row NUMBER, or #f.
(def (row-store-row (s : row-store) (number : :integer)) => (Maybe node)
  (let (i (- number s.base))
    (and (<= 0 i) (< i s.count) (vector-ref s.rows (fx+ s.start i)))))

;; S's last row node, or #f.
(def (row-store-last-row (s : row-store)) => (Maybe node)
  (and (fx> s.count 0) (vector-ref s.rows (fx+ s.start (fx1- s.count)))))

(def (block-of (number : :integer)) => :integer
  (quotient number block-size))

;; Give block B the rows of S it holds, making its node if it has none.
(def (refresh-block! (s : row-store) (b : :integer)) => :void
  (let* ((from (max s.base (* b block-size)))
         (to (min (row-store-end s) (* (+ b 1) block-size)))
         (extra s.extra)
         (rows (let lp ((n (- to 1)) (out []))
                 (if (< n from)
                   out
                   (lp (- n 1) (let (out (cons (row-store-row s n) out))
                                 (if (and extra (= (cdr extra) n)) (cons (car out) (cons (car extra) (cdr out))) out))))))
         (existing (hash-get s.block-nodes b)))
    (cond
     ((null? rows) (hash-remove! s.block-nodes b))
     (existing (set-node-children! existing rows))
     (else (hash-put! s.block-nodes b (new-node 'terminal-rows children: rows))))))

;; Drop the rows numbered below FIRST.
(def (row-store-trim! (s : row-store) (first : :integer)) => :void
  (when (> first s.base)
    (let* ((drop (min s.count (- first s.base)))
           (old-base s.base))
      (let lp ((i 0))
        (when (fx< i drop)
          (vector-set! s.rows (fx+ s.start i) #f)
          (lp (fx1+ i))))
      (set! s.start (fx+ s.start drop))
      (set! s.count (fx- s.count drop))
      (set! s.base first)
      (let lp ((b (block-of old-base)))
        (when (< b (block-of first))
          (hash-remove! s.block-nodes b)
          (lp (+ b 1))))
      (refresh-block! s (block-of first)))))

;; Add empty row nodes up to number END (exclusive).
(def (row-store-extend! (s : row-store) (end : :integer)) => :void
  (let ((old-end (row-store-end s)))
    (when (> end old-end)
      (let* ((count (fx+ s.count (- end old-end)))
             (rows (if (fx<= (fx+ s.start count) (vector-length s.rows))
                     s.rows
                     (let (new (make-vector (fxmax 256 (fx* 2 count)) #f))
                       (subvector-move! s.rows s.start (fx+ s.start s.count) new 0)
                       (set! s.start 0)
                       new))))
        (set! s.rows rows)
        (let lp ((n old-end))
          (when (< n end)
            (vector-set! rows (fx+ s.start (- n s.base))
                         (new-node 'terminal-row attributes: [(cons 'number n) (cons 'runs #()) (cons 'wrap #f)
                                                              (cons 'cursor #f)]))
            (lp (+ n 1))))
        (set! s.count count)
        (let lp ((b (block-of old-end)))
          (when (<= b (block-of (- end 1)))
            (refresh-block! s b)
            (lp (+ b 1))))))))

;; S's block nodes, in order.
(def (row-store-blocks (s : row-store)) => :list
  (if (fx= s.count 0)
    []
    (let lp ((b (block-of (- (row-store-end s) 1))) (out []))
      (if (< b (block-of s.base))
        out
        (lp (- b 1) (let (node (hash-get s.block-nodes b)) (if node (cons node out) out)))))))

#!tuna
(import (buffers) (document) (views) (keys) (commands) (modes) (editing) (kill-ring) (clipboard)
        (undo) (files) (layout) (web) (haml) (ask) (processes) (browse-url)
        (prefix (ghostty) ghostty:) (prefix (terminal screens) screens:))

(define-option shell #f (lambda (v) (or (not v) (and (pair? v) (list? v) (for-all string? v))))
  "The program and arguments a terminal runs without a command, or #f for the program $SHELL names.")

(define-option environment '()
  (lambda (v)
    (and (list? v)
         (for-all (lambda (e) (and (pair? e) (string? (car e)) (or (not (cdr e)) (string? (cdr e))))) v)))
  "Variables for new programs, an association list of names and values; #f removes a variable.")

(define-option scrollback-lines 10000 (lambda (v) (and (fixnum? v) (fx>= v 0)))
  "How many lines of scrollback a terminal keeps, in its buffer and in libghostty's history."
  (lambda (v) (%limit-scrollback!)))

(define-option kill-buffer-on-exit? #t boolean?
  "Whether a terminal's buffer is killed when its program ends.")

(define-option program-copy? #t boolean?
  "Whether a program's copy (OSC 52) pushes its text onto the kill ring and the clipboard.")

(define-hook title-changed "Called with a terminal whose program set its title.")
(define-hook bell "Called with a terminal whose program rang the bell.")
(define-hook notification "Called with a terminal, a title and a body when its program asks for a desktop notification.")
(define-hook progress "Called with a terminal, a state and a percentage or #f when its program reports progress.")
(define-hook program-status "Called with a terminal and an association list of the status its program reported.")
(define-hook semantic-prompt "Called with a terminal, a mark, an exit code or #f and a command line or #f.")
(define-hook screen-changed "Called once per batch with each terminal whose screen changed.")
(define-hook exited "Called with a terminal and its program's exit status, after the last of its output.")

(define-hook mode-hook "Called in each buffer that turns on terminal mode.")
(define-table keymap "Keys in terminals in every input mode.")
(define-table semi-char-keymap "Keys in a terminal in semi-char mode.")
(define-table char-keymap "Keys in a terminal in char mode.")
(define-table copy-keymap "Keys in a terminal in copy mode.")
(define-table %next-keymap "Every key the keymaps bind, for the one key sent whatever its bindings.")
(define-table mouse-keymap "Mouse keys on the screen of a program that takes the mouse.")
(define-table %link-keymap "Mouse keys on a link.")

(define-saved %folder #f (lambda (v) (or (not v) (string? v))))

(define-saved %terminals '()
  (lambda (v)
    (and (list? v)
         (for-all (lambda (e)
                    (and (vector? e) (fx= (vector-length e) 5)
                         (string? (vector-ref e 0)) (string? (vector-ref e 1))
                         (or (not (vector-ref e 2)) (and (list? (vector-ref e 2)) (for-all string? (vector-ref e 2))))
                         (string? (vector-ref e 3))
                         (memq (vector-ref e 4) '(semi-char char copy))))
                  v))))

(define (%entry-name e) (vector-ref e 0))
(define (%entry-id e) (vector-ref e 1))
(define (%entry-command e) (vector-ref e 2))
(define (%entry-directory e) (vector-ref e 3))
(define (%entry-input-mode e) (vector-ref e 4))

(define (%refuse-edits node edit) #f)

(define-record-type (%terminal %make-terminal %terminal?)
  (sealed #t)
  (fields buffer (mutable process) (mutable emulator) (mutable render) (mutable key-encoder)
          (mutable mouse-encoder) command
          (mutable applied) (mutable tracked) (mutable joining?)
          (mutable scrollback-count) (mutable rows) (mutable cursor) (mutable cursor-style)
          (mutable input-mode) (mutable mode-before-copy) (mutable client) (mutable title)
          (mutable directory) (mutable status) (mutable held?) (mutable events) (mutable changed?)
          (mutable focused?) (mutable sizes) (mutable alternate?) (mutable pressed) (mutable seen-views)
          (mutable size))
  (protocol
    (lambda (new)
      (lambda (buffer process emulator command directory input-mode client)
        (new buffer process emulator (ghostty:make-render-state) (ghostty:make-key-encoder)
             (ghostty:make-mouse-encoder) command
             0 #f #f
             0 (vector) #f 'block
             input-mode 'semi-char client "" directory #f #f '() #f
             #f #f #f #f (make-weak-eq-hashtable)
             (cons (ghostty:terminal-columns emulator) (ghostty:terminal-rows emulator)))))))

;; Buffers are made again when buffers reloads, so a terminal is found
;; by its buffer, never kept by name.
(define %by-buffer (make-weak-eq-hashtable))

(define (%all) (filter (lambda (t) (buffers:live? (%terminal-buffer t))) (vector->list (hashtable-values %by-buffer))))

(define (%of buffer) (and (buffers:buffer? buffer) (buffers:live? buffer) (eq-hashtable-ref %by-buffer buffer #f)))

(define (%current who)
  (let* ([view (views:current)] [t (and view (%of (views:buffer view)))])
    (unless t
      (assertion-violation who "not a terminal" (and view (views:buffer view))))
    t))

(define (%current-terminal)
  (let ([view (views:current)])
    (and view (%of (views:buffer view)))))

;; The plugin's own files sit in its folder beside this module, where
;; Chez finds the module's source.
(define %plugin-folder
  (let-values ([(source object found?)
                ((library-search-handler) 'terminal '(terminal) (library-directories) (library-extensions))])
    (string-append (path-parent source) "/terminal")))

(define (%draw-root node view)
  (haml (:div.terminal (views:draw-children view node))))

(define (%draw-scrollback node view)
  (haml (:div.terminal-scrollback (views:draw-children view node))))

;; While a program takes the mouse, an event names a cell, never a
;; character that a redraw makes stale. Alternate scroll is on by default
;; on every alternate screen, so it takes only the wheel: a click there
;; still names the character, for links and selecting. Shift gives the
;; mouse back from the program, as in xterm.
(define (%draw-screen node view)
  (let* ([t (%of (views:buffer view))] [mouse? (and t (%takes-mouse? t))])
    (haml (:div.terminal-screen ([data-cursor (if t (symbol->string (%terminal-cursor-style t)) "block")]
                                 [data-keymap (and mouse? (views:keymap-mark mouse-keymap))]
                                 [data-wheel (and (or mouse? (and t (%alternate-scroll? t))) "shift")]
                                 [data-grid (and mouse? "shift")])
            (views:draw-children view node)))))

(buffers:define-kind %root (content nodes) (draw %draw-root))
(buffers:define-kind %scrollback (consent %refuse-edits) (draw %draw-scrollback))
(buffers:define-kind %screen (consent %refuse-edits) (draw %draw-screen))

(buffers:define-layer %styles (priority 0))
(buffers:define-layer %cells (priority 1))
(buffers:define-layer %inputs (priority -1))
(buffers:define-layer %links (priority 2) (keymap %link-keymap))

(define (%root-node doc) (document:token doc 0))

(define (%child-node doc kind)
  (let ([found #f])
    (document:for-each-child (%root-node doc) 1 (fx- (document:length doc) 1)
      (lambda (c at) (when (and (document:node? c) (eq? (document:node-kind c) kind)) (set! found c))))
    found))

(define (%scrollback-node b) (%child-node (buffers:document b) 'terminal:%scrollback))
(define (%screen-node b) (%child-node (buffers:document b) 'terminal:%screen))

(define (%screen-start t) (fx+ (document:node-start (%screen-node (%terminal-buffer t))) 1))

(define %palette-faces
  (list->vector (map (lambda (i) (string->symbol (format "terminal.color-~a" i))) (iota 16))))

(define (%hex rgb)
  (format "#~2,'0x~2,'0x~2,'0x" (ghostty:rgb-red rgb) (ghostty:rgb-green rgb) (ghostty:rgb-blue rgb)))

(define (%resolve-color c palette)
  (cond
    [(not c) #f]
    [(ghostty:rgb? c) (%hex c)]
    [(fx< c 16) c]
    [else (%hex (vector-ref palette c))]))

(define (%style-value style palette)
  (let* ([inverse? (ghostty:style-inverse? style)]
         [fg (%resolve-color (ghostty:style-foreground style) palette)]
         [bg (%resolve-color (ghostty:style-background style) palette)]
         [fg* (if inverse? (or bg 'background) fg)]
         [bg* (if inverse? (or fg 'foreground) bg)]
         [words '()] [properties '()] [face #f])
    (define (word! w) (set! words (cons w words)))
    (define (property! name value) (set! properties (cons (cons name value) properties)))
    (cond
      [(not fg*)]
      [(eq? fg* 'background) (word! "fg-background")]
      [(fixnum? fg*) (set! face (vector-ref %palette-faces fg*))]
      [else (word! "fg") (property! "--terminal-fg" fg*)])
    (cond
      [(not bg*)]
      [(eq? bg* 'foreground) (word! "bg-foreground")]
      [(fixnum? bg*) (word! (format "bg-~a" bg*))]
      [else (word! "bg") (property! "--terminal-bg" bg*)])
    (when (ghostty:style-bold? style) (word! "bold"))
    (when (ghostty:style-italic? style) (word! "italic"))
    (when (ghostty:style-faint? style) (word! "faint"))
    (when (ghostty:style-invisible? style) (word! "invisible"))
    (when (ghostty:style-strikethrough? style) (word! "strike"))
    (when (ghostty:style-overline? style) (word! "overline"))
    (let ([u (ghostty:style-underline style)])
      (unless (eq? u 'none) (word! (format "underline-~a" u))))
    (let ([uc (%resolve-color (ghostty:style-underline-color style) palette)])
      (cond
        [(not uc)]
        [(fixnum? uc) (word! (format "underline-color-~a" uc))]
        [else (word! "underline-color") (property! "--terminal-underline" uc)]))
    (and (or face (pair? words))
         (append (if face (list (cons 'face face)) '())
                 (if (pair? words) (list (cons 'terminal (cons (reverse words) (reverse properties)))) '())))))

(define (%style-attributes v)
  (let ([words (car v)] [properties (cdr v)])
    (append
      (list (cons "data-terminal" (apply string-append (cons (car words) (map (lambda (w) (string-append " " w)) (cdr words))))))
      (if (null? properties)
          '()
          (list (cons "style" (apply string-append (map (lambda (p) (string-append (car p) ":" (cdr p) ";")) properties))))))))

(define (%cells-attributes n) (list (cons "data-cells" (number->string n))))

(define (%link-attributes target) (list (cons "data-terminal-link" "")))

(define-record-type (%row %make-row %row?)
  (sealed #t)
  (fields text columns styles cells links inputs))

(define (%row-equal? a b)
  (and (string=? (%row-text a) (%row-text b))
       (equal? (%row-styles a) (%row-styles b))
       (equal? (%row-cells a) (%row-cells b))
       (equal? (%row-links a) (%row-links b))
       (equal? (%row-inputs a) (%row-inputs b))))

(define (%ascii? s)
  (let loop ([i 0])
    (or (fx= i (string-length s)) (and (char<? (string-ref s i) #\x80) (loop (fx+ i 1))))))

;; libghostty puts a grapheme in one cell by one of two rules, as
;; grapheme clustering (mode 2027) was off or on when it was printed, and
;; the program may since have switched it; the rule whose widths add up
;; to the run's cells is the one it used.
(define (%clusters text cells)
  (let ([joined (%sized (%joined-clusters text))])
    (if (fx= (fold-left (lambda (sum c) (fx+ sum (cdr c))) 0 joined) cells)
        joined
        (%sized (%graphemes text)))))

(define (%sized clusters) (map (lambda (s) (cons s (%cluster-cells s))) clusters))

;; Without grapheme clustering, a character of no width, or one after a
;; zero-width joiner, goes in the cell before it.
(define (%joined-clusters text)
  (let loop ([i 0] [current '()] [acc '()] [join? #f])
    (if (fx= i (string-length text))
        (reverse (if (null? current) acc (cons (list->string (reverse current)) acc)))
        (let* ([c (string-ref text i)] [n (char->integer c)])
          (if (and (pair? current) (or join? (fx= (ghostty:unicode-codepoint-width n) 0)))
              (loop (fx+ i 1) (cons c current) acc (fx= n #x200D))
              (loop (fx+ i 1) (list c) (if (null? current) acc (cons (list->string (reverse current)) acc))
                (fx= n #x200D)))))))

(define (%graphemes text)
  (let ([n (string-length text)])
    (let loop ([i 0] [acc '()])
      (if (fx= i n)
          (reverse acc)
          (let-values ([(count width) (ghostty:unicode-grapheme-width (substring text i n))])
            (let ([j (fx+ i (fxmax 1 (fxmin count (fx- n i))))])
              (loop j (cons (substring text i j) acc))))))))

(define (%cluster-cells s)
  (if (fx= (string-length s) 1)
      (fxmax 1 (fxmin 2 (ghostty:unicode-codepoint-width (char->integer (string-ref s 0)))))
      (let-values ([(count width) (ghostty:unicode-grapheme-width s)])
        (fxmax 1 (fxmin 2 width)))))

(define (%row-from render-row palette)
  (let ([text-parts '()] [columns '()] [styles '()] [cells '()] [links '()] [inputs '()] [at 0])
    (vector-for-each
      (lambda (run)
        (let* ([text (ghostty:render-run-text run)] [n (string-length text)]
               [column (ghostty:render-run-column run)] [start at])
          (if (%ascii? text)
              (do ([i 0 (fx+ i 1)]) ((fx= i n)) (set! columns (cons (fx+ column i) columns)))
              (let loop ([clusters (%clusters text (ghostty:render-run-width run))] [p start] [col column])
                (unless (null? clusters)
                  (let* ([s (caar clusters)] [k (string-length s)] [w (cdar clusters)])
                    (do ([i 0 (fx+ i 1)]) ((fx= i k)) (set! columns (cons col columns)))
                    (unless (char<? (string-ref s 0) #\x80)
                      (set! cells (cons (list p (fx+ p k) (list (cons 'terminal-cells w))) cells)))
                    (loop (cdr clusters) (fx+ p k) (fx+ col w))))))
          (set! text-parts (cons text text-parts))
          (set! at (fx+ at n))
          (let ([v (%style-value (ghostty:render-run-style run) palette)])
            (when v (set! styles (cons (list start at v) styles))))
          (let ([link (ghostty:render-run-hyperlink run)])
            (when link (set! links (cons (list start at (list (cons 'terminal-link link))) links))))
          (when (eq? (ghostty:render-run-semantic-content run) 'input)
            (set! inputs (cons (list start at '((terminal-input . #t))) inputs)))))
      (ghostty:render-row-runs render-row))
    (%make-row (apply string-append (reverse text-parts)) (list->vector (reverse columns))
      (reverse styles) (reverse cells) (reverse links) (reverse inputs))))

;; Point rests at the program's cursor, so the cursor's row reaches it.
(define (%pad-row row column)
  (let* ([text (%row-text row)] [columns (%row-columns row)] [n (string-length text)]
         [end (if (fx= n 0) 0
                  (fx+ (vector-ref columns (fx- n 1)) (%char-cells row (fx- n 1))))])
    (if (fx>= end column)
        row
        (let ([pad (fx- column end)])
          (%make-row (string-append text (make-string pad #\space))
            (%vector-append columns (list->vector (map (lambda (i) (fx+ end i)) (iota pad))))
            (%row-styles row) (%row-cells row) (%row-links row) (%row-inputs row))))))

(define (%vector-append a b)
  (let ([v (make-vector (fx+ (vector-length a) (vector-length b)))])
    (vector-copy! a 0 v 0 (vector-length a))
    (vector-copy! b 0 v (vector-length a) (vector-length b))
    v))

(define (%char-cells row i)
  (let ([columns (%row-columns row)])
    (if (fx< (fx+ i 1) (vector-length columns))
        (fxmax 1 (fx- (vector-ref columns (fx+ i 1)) (vector-ref columns i)))
        (let ([s (%row-cells row)])
          (let ([span (find (lambda (s) (and (fx<= (car s) i) (fx< i (cadr s)))) s)])
            (if span (cdr (assq 'terminal-cells (caddr span))) 1))))))

(define (%column->index row column)
  (let ([columns (%row-columns row)])
    (let loop ([i 0])
      (cond
        [(fx= i (vector-length columns)) i]
        [(fx>= (vector-ref columns i) column) i]
        [(fx> (fx+ (vector-ref columns i) (%char-cells row i)) column) i]
        [else (loop (fx+ i 1))]))))

(define (%index->column row i)
  (let ([columns (%row-columns row)])
    (if (fx< i (vector-length columns))
        (vector-ref columns i)
        (if (fx= (vector-length columns) 0)
            i
            (fx+ (vector-ref columns (fx- (vector-length columns) 1))
                 (%char-cells row (fx- (vector-length columns) 1))
                 (fx- i (vector-length columns)))))))

;; Each word of ls's output names a file that exists, so a reference
;; without OSC 8 is a link only with a / or a line number.
(define (%url-end text i)
  (let loop ([j i])
    (if (and (fx< j (string-length text))
             (let ([c (string-ref text j)]) (not (or (char-whitespace? c) (memv c '(#\" #\< #\> #\` #\'))))))
        (loop (fx+ j 1))
        (let trim ([j j])
          (if (and (fx> j i) (memv (string-ref text (fx- j 1)) '(#\. #\, #\; #\: #\) #\] #\} #\! #\?)))
              (trim (fx- j 1))
              j)))))

(define (%prefix-at? text i prefix)
  (let ([n (string-length prefix)])
    (and (fx<= (fx+ i n) (string-length text)) (string=? (substring text i (fx+ i n)) prefix))))

(define (%path-char? c)
  (or (char-alphabetic? c) (char-numeric? c) (memv c '(#\_ #\. #\/ #\~ #\- #\+ #\@ #\%))))

(define (%digits text i)
  (let loop ([j i]) (if (and (fx< j (string-length text)) (char-numeric? (string-ref text j))) (loop (fx+ j 1)) j)))

(define (%file-reference text i directory)
  (let ([path-end (let loop ([j i]) (if (and (fx< j (string-length text)) (%path-char? (string-ref text j))) (loop (fx+ j 1)) j))])
    (and (fx> path-end i)
         (let* ([path (substring text i path-end)]
                [line-end (and (fx< path-end (string-length text)) (char=? (string-ref text path-end) #\:)
                               (let ([e (%digits text (fx+ path-end 1))]) (and (fx> e (fx+ path-end 1)) e)))]
                [column-end (and line-end (fx< line-end (string-length text)) (char=? (string-ref text line-end) #\:)
                                 (let ([e (%digits text (fx+ line-end 1))]) (and (fx> e (fx+ line-end 1)) e)))]
                [full (cond
                        [(char=? (string-ref path 0) #\/) path]
                        [(and (fx> (string-length path) 1) (char=? (string-ref path 0) #\~) (char=? (string-ref path 1) #\/))
                         (string-append (or (getenv "HOME") "") (substring path 1 (string-length path)))]
                        [else (string-append directory (if (and (fx> (string-length directory) 0)
                                                                (char=? (string-ref directory (fx- (string-length directory) 1)) #\/))
                                                           "" "/")
                                             path)])])
           (and (or line-end (memv #\/ (string->list path)))
                (file-exists? full) (not (file-directory? full))
                (list (or column-end line-end path-end)
                      (vector full
                              (and line-end (string->number (substring text (fx+ path-end 1) line-end)))
                              (and column-end (string->number (substring text (fx+ line-end 1) column-end))))))))))

(define (%found-links text directory osc-links)
  (let loop ([i 0] [acc '()])
    (cond
      [(fx>= i (string-length text)) (append osc-links (reverse acc))]
      [(exists (lambda (s) (and (fx< (car s) (fx+ i 1)) (fx> (cadr s) i))) osc-links) (loop (fx+ i 1) acc)]
      [(or (%prefix-at? text i "https://") (%prefix-at? text i "http://"))
       (let ([e (%url-end text i)])
         (loop e (cons (list i e (list (cons 'terminal-link (substring text i e)))) acc)))]
      [(and (%path-char? (string-ref text i))
            (or (fx= i 0) (not (%path-char? (string-ref text (fx- i 1))))))
       (let ([found (%file-reference text i directory)])
         (if found
             (loop (car found) (cons (list i (car found) (list (cons 'terminal-link (cadr found)))) acc))
             (loop (fx+ i 1) acc)))]
      [else (loop (fx+ i 1) acc)])))

(define (%with-links row directory)
  (let ([links (%found-links (%row-text row) directory (%row-links row))])
    (if (equal? links (%row-links row))
        row
        (%make-row (%row-text row) (%row-columns row) (%row-styles row) (%row-cells row) links (%row-inputs row)))))

(define (%spans-shifted spans by)
  (map (lambda (s) (list (fx+ (car s) by) (fx+ (cadr s) by) (caddr s))) spans))

(define (%set-row-spans! b start end rows)
  (let loop ([rows rows] [at start] [styles '()] [cells '()] [links '()] [inputs '()])
    (if (null? rows)
        (begin
          (buffers:set-spans! (buffers:layer b %styles) start end (reverse styles))
          (buffers:set-spans! (buffers:layer b %cells) start end (reverse cells))
          (buffers:set-spans! (buffers:layer b %links) start end (reverse links))
          (buffers:set-spans! (buffers:layer b %inputs) start end (reverse inputs)))
        (let ([r (car rows)])
          (loop (cdr rows) (fx+ at (fx+ (string-length (%row-text r)) 1))
                (append (reverse (%spans-shifted (%row-styles r) at)) styles)
                (append (reverse (%spans-shifted (%row-cells r) at)) cells)
                (append (reverse (%spans-shifted (%row-links r) at)) links)
                (append (reverse (%spans-shifted (%row-inputs r) at)) inputs))))))

(define (%rows-text rows)
  (apply string-append (map (lambda (r) (string-append (%row-text r) "\n")) rows)))

(define (%row-start t i)
  (let ([rows (%terminal-rows t)])
    (let loop ([j 0] [at (%screen-start t)])
      (if (fx= j i) at (loop (fx+ j 1) (fx+ at (fx+ (string-length (%row-text (vector-ref rows j))) 1)))))))

;; The user's edits are refused, so every edit is the plugin's and
;; leaves no unsaved text to ask about.
(define (%splice! b start end datum)
  (buffers:splice! b start end datum)
  (buffers:set-modified! b #f))

(define (%splice-text! b start end text)
  (%splice! b start end (document:from-datum text)))

(define (%write-rows! t new)
  (let* ([old (%terminal-rows t)] [n (vector-length new)] [m (vector-length old)]
         [first (let loop ([i 0])
                  (if (and (fx< i n) (fx< i m) (%row-equal? (vector-ref old i) (vector-ref new i))) (loop (fx+ i 1)) i))])
    (unless (and (fx= n m) (fx= first n))
      (let* ([last-old (let loop ([i (fx- m 1)] [j (fx- n 1)])
                         (if (and (fx>= i first) (fx>= j first) (%row-equal? (vector-ref old i) (vector-ref new j)))
                             (loop (fx- i 1) (fx- j 1))
                             (cons i j)))]
             [old-end (fx+ (car last-old) 1)] [new-end (fx+ (cdr last-old) 1)]
             [b (%terminal-buffer t)]
             [start (%row-start t first)]
             [end (let loop ([j first] [at start])
                    (if (fx= j old-end) at (loop (fx+ j 1) (fx+ at (fx+ (string-length (%row-text (vector-ref old j))) 1)))))]
             [rows (let loop ([j (fx- new-end 1)] [acc '()]) (if (fx< j first) acc (loop (fx- j 1) (cons (vector-ref new j) acc))))]
             [text (%rows-text rows)])
        (%splice-text! b start end text)
        (%set-row-spans! b start (fx+ start (string-length text)) rows)
        (%terminal-rows-set! t new)
        (%terminal-changed?-set! t #t)))))

(define (%append-scrollback! t rows)
  (unless (null? rows)
    (let* ([b (%terminal-buffer t)] [node (%scrollback-node b)] [end (fx- (document:node-end node) 1)])
      (cond
        [(and (%terminal-joining? t) (fx> end (fx+ (document:node-start node) 1)))
         ;; The program wrapped the last row copied, so this one goes on
         ;; its line.
         (let ([at (fx- end 1)] [first (car rows)])
           (%splice-text! b at at (%row-text first))
           (%set-row-spans! b at (fx+ at (string-length (%row-text first))) (list first))
           (%add-scrollback-lines! t b (fx+ at (string-length (%row-text first)) 1) (cdr rows)))]
        [else (%add-scrollback-lines! t b end rows)])
      (%trim-scrollback! t))))

(define (%add-scrollback-lines! t b at rows)
  (unless (null? rows)
    (let ([text (%rows-text rows)])
      (%splice-text! b at at text)
      (%set-row-spans! b at (fx+ at (string-length text)) rows)
      (%terminal-scrollback-count-set! t (fx+ (%terminal-scrollback-count t) (length rows))))))

(define (%trim-scrollback! t)
  (let ([extra (fx- (%terminal-scrollback-count t) (scrollback-lines))])
    (when (fx> extra 0)
      (let* ([b (%terminal-buffer t)] [doc (buffers:document b)] [node (%scrollback-node b)]
             [start (fx+ (document:node-start node) 1)]
             [line (document:line doc start)]
             [end (document:line-start doc (fx+ line extra))])
        (%splice! b start end (document:from-datum ""))
        (%terminal-scrollback-count-set! t (scrollback-lines))))))

(define (%limit-scrollback!)
  (for-each
    (lambda (t)
      (ghostty:terminal-set-scrollback-max-lines! (%terminal-emulator t) (scrollback-lines))
      (%trim-scrollback! t))
    (%all)))

(define (%clear-scrollback! t)
  (let* ([b (%terminal-buffer t)] [node (%scrollback-node b)])
    (%splice! b (fx+ (document:node-start node) 1) (fx- (document:node-end node) 1) (document:from-datum ""))
    (%terminal-scrollback-count-set! t 0)
    (%terminal-joining?-set! t #f)))

(define (%note! t text)
  (%terminal-joining?-set! t #f)
  (%append-scrollback! t (list (%make-row text (list->vector (iota (string-length text))) '() '() '() '()))))

(define (%palette t) (ghostty:color-theme-palette (ghostty:terminal-colors (%terminal-emulator t))))

;; Moving libghostty's viewport to read its history is safe, since
;; nothing draws it: clients draw the buffer.
(define (%read-history t from count)
  (let ([emu (%terminal-emulator t)] [rs (%terminal-render t)] [palette (%palette t)]
        [directory (%terminal-directory t)])
    (let loop ([from from] [left count] [acc '()])
      (if (fx<= left 0)
          (begin
            (ghostty:terminal-scroll-to-bottom! emu)
            (reverse acc))
          (begin
            (ghostty:terminal-scroll-to-row! emu from)
            (ghostty:render-state-update! rs emu)
            (let* ([rows (ghostty:render-state-rows rs)] [k (fxmin left (length rows))])
              (let take ([rows rows] [i 0] [acc acc])
                (if (fx= i k)
                    (loop (fx+ from k) (fx- left k) acc)
                    (take (cdr rows) (fx+ i 1)
                      (cons (cons (%with-links (%row-from (car rows) palette) directory)
                                  (ghostty:render-row-wrap? (car rows)))
                            acc))))))))))

;; Rows the program wrapped become one line, so each device wraps them at
;; its own width and a copy has no break where the program wrapped.
(define (%join-wrapped rows)
  (let loop ([rows rows] [acc '()] [open #f])
    (cond
      [(null? rows) (values (reverse (if open (cons open acc) acc)) (and open #t))]
      [open
       (let* ([r (caar rows)] [joined (%join-rows open r)])
         (if (cdar rows) (loop (cdr rows) acc joined) (loop (cdr rows) (cons joined acc) #f)))]
      [(cdar rows) (loop (cdr rows) acc (caar rows))]
      [else (loop (cdr rows) (cons (caar rows) acc) #f)])))

(define (%join-rows a b)
  (let ([n (string-length (%row-text a))])
    (%make-row (string-append (%row-text a) (%row-text b))
      (%vector-append (%row-columns a) (%row-columns b))
      (append (%row-styles a) (%spans-shifted (%row-styles b) n))
      (append (%row-cells a) (%spans-shifted (%row-cells b) n))
      (append (%row-links a) (%spans-shifted (%row-links b) n))
      (append (%row-inputs a) (%spans-shifted (%row-inputs b) n)))))

(define (%append-history! t rows)
  (unless (null? rows)
    (let-values ([(lines open?) (%join-wrapped rows)])
      (%append-scrollback! t lines)
      (%terminal-joining?-set! t open?))))

(define (%track-newest! t count)
  (let ([old (%terminal-tracked t)])
    (when old (ghostty:tracked-point-close! old))
    (%terminal-tracked-set! t
      (and (fx> count 0)
           (ghostty:make-tracked-point (%terminal-emulator t) (ghostty:make-grid-point 'screen 0 (fx- count 1)))))))

(define (%copy-history! t)
  (let* ([emu (%terminal-emulator t)] [count (ghostty:terminal-scrollback-rows emu)] [tracked (%terminal-tracked t)]
         [point (and tracked (ghostty:tracked-point-valid? tracked) (ghostty:tracked-point-ref tracked 'screen))])
    (cond
      [(and point (fx>= (ghostty:grid-point-y point) count))
       ;; Erasing history, as clear (CSI 3J) or a reset does, moves the
       ;; point onto the screen.
       (%clear-scrollback! t)
       (%append-history! t (%read-history t 0 count))
       (%track-newest! t count)]
      [else
       (let ([from (cond
                     [point (fx+ (ghostty:grid-point-y point) 1)]
                     [tracked (%note! t "[Output was lost here.]") 0]
                     [else 0])])
         (when (fx> count from)
           (%append-history! t (%read-history t from (fx- count from))))
         (when (or (fx> count from) (and tracked (not point)))
           (%track-newest! t count)))])))

(define (%screen-rows t)
  (let* ([emu (%terminal-emulator t)] [rs (%terminal-render t)] [palette (%palette t)] [directory (%terminal-directory t)])
    (ghostty:render-state-update! rs emu)
    (let* ([cursor (ghostty:render-state-cursor rs)]
           [cursor-row (ghostty:render-cursor-row cursor)]
           [cursor-column (ghostty:render-cursor-column cursor)]
           [rows (list->vector
                   (map (lambda (r)
                          (let ([row (%with-links (%row-from r palette) directory)])
                            (if (and cursor-row (fx= (ghostty:render-row-y r) cursor-row))
                                (%pad-row row cursor-column)
                                row)))
                        (ghostty:render-state-rows rs)))])
      (%terminal-cursor-style-set! t
        (if (and (ghostty:render-cursor-visible? cursor) cursor-row) (ghostty:render-cursor-style cursor) 'hidden))
      (values rows (and cursor-row (cons cursor-row cursor-column))))))

(define (%cursor-position t)
  (let ([cursor (%terminal-cursor t)] [rows (%terminal-rows t)])
    (if (and cursor (fx< (car cursor) (vector-length rows)))
        (fx+ (%row-start t (car cursor)) (%column->index (vector-ref rows (car cursor)) (cdr cursor)))
        (%screen-start t))))

(define (%last-row-start t)
  (let ([n (vector-length (%terminal-rows t))])
    (if (fx= n 0) (%screen-start t) (%row-start t (fx- n 1)))))

(define (%following-views t)
  (let ([at (%cursor-position t)])
    (filter (lambda (v) (fx= (views:point v) at)) (views:showing (%terminal-buffer t)))))

(define (%follow! t views)
  (let ([at (%cursor-position t)] [bottom (%last-row-start t)])
    (for-each
      (lambda (v)
        (views:set-point! v at)
        (views:scroll-to! v bottom (views:align bottom)))
      views)))

(define (%writing? t)
  (and (not (eq? (%terminal-input-mode t) 'copy)) (not (%terminal-held? t))))

(define (%takes-mouse? t)
  (and (not (%terminal-status t)) (ghostty:terminal-mouse-tracking? (%terminal-emulator t))))

(define (%alternate-scroll? t)
  (and (not (%terminal-status t))
       (eq? (ghostty:terminal-active-screen (%terminal-emulator t)) 'alternate)
       (ghostty:terminal-mode-enabled? (%terminal-emulator t) 'alt-scroll)))

(define (%update-alternate! t)
  (let ([alternate? (eq? (ghostty:terminal-active-screen (%terminal-emulator t)) 'alternate)])
    (unless (eq? alternate? (%terminal-alternate? t))
      (%terminal-alternate?-set! t alternate?)
      (%narrow-views! t))))

(define (%narrow-views! t)
  (let* ([b (%terminal-buffer t)] [node (%screen-node b)])
    (for-each
      (lambda (v)
        (if (%terminal-alternate? t)
            (views:narrow! v (document:node-start node) (document:node-end node))
            (views:widen! v)))
      (views:showing b))))

(define (%refresh! t)
  (when (%writing? t) (%write-screen! t)))

(define (%write-screen! t)
  (%update-alternate! t)
  (unless (%terminal-alternate? t)
    (%copy-history! t))
  (let ([following (%following-views t)])
    (let-values ([(rows cursor) (%screen-rows t)])
      (%write-rows! t rows)
      (%terminal-cursor-set! t cursor))
    (%follow! t following)))

;; Effects arrive inside libghostty's callbacks, where the terminal
;; cannot change, so the hooks run once the output is applied.
(define (%event! t thunk)
  (%terminal-events-set! t (cons thunk (%terminal-events t))))

(define (%run-events! t)
  (let ([events (reverse (%terminal-events t))])
    (%terminal-events-set! t '())
    (for-each (lambda (e) (e)) events)))

(define %slice 8192)

(define (%apply-output! t bytes end)
  (let ([emu (%terminal-emulator t)] [n (bytevector-length bytes)])
    (let loop ([start 0])
      (when (fx< start n)
        (let ([stop (fxmin n (fx+ start %slice))])
          (ghostty:terminal-write! emu bytes start stop)
          (when (and (%writing? t) (eq? (ghostty:terminal-active-screen emu) 'primary))
            (%copy-history! t))
          (loop stop))))
    (%terminal-applied-set! t end)
    (%refresh! t)
    (%run-events! t)))

(define (%on-output t)
  (lambda (bytes end)
    (when (buffers:live? (%terminal-buffer t))
      (unless (eof-object? bytes)
        (%apply-output! t bytes end)))))

(define (%on-exit t)
  (lambda (status)
    (%terminal-status-set! t status)
    (%forget-entry! t)
    (when (buffers:live? (%terminal-buffer t))
      (exited (%terminal-buffer t) status)
      (when (and (kill-buffer-on-exit?) (buffers:live? (%terminal-buffer t)))
        (buffers:kill! (%terminal-buffer t))))))

(define (%local-path url)
  (let ([prefix (find (lambda (p) (%prefix-at? url 0 p)) '("file://" "kitty-shell-cwd://"))])
    (if (not prefix)
        (and (fx> (string-length url) 0) (char=? (string-ref url 0) #\/) url)
        (let* ([rest (substring url (string-length prefix) (string-length url))]
               [slash (let loop ([i 0]) (cond [(fx= i (string-length rest)) #f] [(char=? (string-ref rest i) #\/) i] [else (loop (fx+ i 1))]))])
          (and slash
               (let ([host (substring rest 0 slash)])
                 (and (or (string=? host "") (string=? host "localhost") (string=? host (%host-name)))
                      (%percent-decoded (substring rest slash (string-length rest))))))))))

(define (%host-name)
  (let ([name (guard (c [(i/o-error? c) #f]) (call-with-input-file "/proc/sys/kernel/hostname" get-line))])
    (if (string? name) name "")))

(define (%percent-decoded s)
  (let loop ([i 0] [acc '()])
    (cond
      [(fx= i (string-length s)) (utf8->string (u8-list->bytevector (reverse acc)))]
      [(and (char=? (string-ref s i) #\%) (fx< (fx+ i 2) (string-length s))
            (string->number (substring s (fx+ i 1) (fx+ i 3)) 16))
       => (lambda (n) (loop (fx+ i 3) (cons n acc)))]
      [else (loop (fx+ i 1) (append (reverse (bytevector->u8-list (string->utf8 (string (string-ref s i))))) acc))])))

(define (%semantic-mark kind)
  (case kind
    [(prompt-start) 'prompt]
    [(input-start) 'input]
    [(output-start) 'command-start]
    [(command-end) 'command-end]
    [else #f]))

(define (%install-effects! t)
  (let ([emu (%terminal-emulator t)] [b (%terminal-buffer t)])
    (ghostty:terminal-set-pty-write-handler! emu
      (lambda (bytes)
        (let ([p (%terminal-process t)])
          (when (and p (not (%terminal-status t)) (not (processes:status p)))
            (processes:send! p bytes)))))
    (ghostty:terminal-set-bell-handler! emu (lambda () (%event! t (lambda () (bell b)))))
    (ghostty:terminal-set-title-changed-handler! emu
      (lambda (title)
        (%terminal-title-set! t title)
        (%event! t (lambda () (title-changed b)))))
    (ghostty:terminal-set-pwd-changed-handler! emu
      (lambda (url)
        (let ([path (%local-path url)])
          (when path (%terminal-directory-set! t path)))))
    (ghostty:terminal-set-color-scheme-handler! emu (lambda () (%color-scheme t)))
    (ghostty:terminal-set-clipboard-write-handler! emu
      (lambda (request)
        (if (program-copy?)
            (let ([content (find (lambda (c) (member (ghostty:clipboard-content-mime c) '("text/plain" "text/plain;charset=utf-8")))
                                 (ghostty:clipboard-write-request-contents request))])
              (when content
                (let ([text (utf8->string (ghostty:clipboard-content-data content))] [client (%terminal-client t)])
                  (%event! t
                    (lambda ()
                      (kill-ring:push! (list text))
                      (when (and client (memq client (web:clients)))
                        (clipboard:copy-to! client text))))))
              'success)
            'denied)))
    (ghostty:terminal-set-clipboard-read-handler! emu
      (lambda (request) (list (ghostty:make-clipboard-content "text/plain" (bytevector)))))
    (ghostty:terminal-set-desktop-notification-handler! emu
      (lambda (n)
        (let ([title (ghostty:desktop-notification-title n)] [body (ghostty:desktop-notification-body n)])
          (%event! t (lambda () (notification b title body))))))
    (ghostty:terminal-set-progress-report-handler! emu
      (lambda (r)
        (let ([state (ghostty:progress-report-state r)] [percent (ghostty:progress-report-progress r)])
          (%event! t (lambda () (progress b state percent))))))
    (ghostty:terminal-set-semantic-prompt-handler! emu
      (lambda (e)
        (let ([mark (%semantic-mark (ghostty:semantic-prompt-kind e))]
              [code (ghostty:semantic-prompt-exit-code e)]
              [command (let ([c (ghostty:semantic-prompt-command e)]) (and (string? c) (not (string=? c "")) c))])
          (when mark
            (%event! t (lambda () (semantic-prompt b mark code command)))))))
    (ghostty:terminal-set-program-status-handler! emu
      (lambda (s)
        (let ([report (append
                        (list (cons 'state (ghostty:program-status-state s)))
                        (filter cdr
                          (list (cons 'id (%non-empty (ghostty:program-status-id s)))
                                (cons 'kind (ghostty:program-status-kind s))
                                (cons 'progress (ghostty:program-status-progress s))
                                (cons 'app (%non-empty (ghostty:program-status-app s)))
                                (cons 'title (%non-empty (ghostty:program-status-title s)))
                                (cons 'message (%non-empty (ghostty:program-status-message s))))))])
          (%event! t (lambda () (program-status b report))))))
    (ghostty:terminal-set-render-hold-handler! emu
      (lambda (held?) (%terminal-held?-set! t held?)))))

(define (%non-empty s) (and (string? s) (not (string=? s "")) s))

(define (%configure! t)
  (let ([emu (%terminal-emulator t)])
    ;; libghostty's own default keeps history by size, a few hundred
    ;; rows; the buffer's scrollback is counted in lines, so libghostty's
    ;; history is too.
    (ghostty:terminal-set-scrollback-max-bytes! emu #f)
    (ghostty:terminal-set-scrollback-max-lines! emu (scrollback-lines))
    (ghostty:terminal-set-resize-pull-scrollback! emu #f)
    (ghostty:terminal-set-terminfo-name! emu "xterm-ghostty")
    (%install-effects! t)
    (%apply-colors! t)))

(define %device-colors (make-weak-eq-hashtable))

(define (%client-colors client) (and client (eq-hashtable-ref %device-colors client #f)))

(define (%color-scheme t)
  (let ([colors (%client-colors (%terminal-client t))])
    (and colors
         (if (> (ghostty:color-perceived-luminance (vector-ref colors 1)) 0.5) 'light 'dark))))

(define (%apply-colors! t)
  (let ([colors (%client-colors (%terminal-client t))] [emu (%terminal-emulator t)])
    (when colors
      (ghostty:terminal-set-default-foreground! emu (vector-ref colors 0))
      (ghostty:terminal-set-default-background! emu (vector-ref colors 1))
      (ghostty:terminal-set-default-cursor-color! emu (vector-ref colors 2))
      (let ([palette (ghostty:color-default-palette)])
        (vector-for-each (lambda (i c) (vector-set! palette i c)) (list->vector (iota 16)) (vector-ref colors 3))
        (ghostty:terminal-set-default-palette! emu palette)))))

(define (%report-scheme! t)
  (let ([scheme (%color-scheme t)])
    (when (and scheme (not (%terminal-status t))
               (ghostty:terminal-mode-enabled? (%terminal-emulator t) 'color-scheme-report))
      (processes:send! (%terminal-process t) (ghostty:color-scheme-report-encode scheme)))))

(define (%colors-item client item)
  (define (field name) (cdr (or (assoc name item) '(#f . #f))))
  (define (color s) (and (string? s) (ghostty:color-parse s)))
  (let ([fg (color (field "foreground"))] [bg (color (field "background"))] [cursor (color (field "cursor"))]
        [palette (field "palette")])
    (unless (and fg bg cursor (vector? palette) (fx= (vector-length palette) 16)
                 (for-all color (vector->list palette)))
      (assertion-violation 'terminal "not a terminal colours item" item))
    (eq-hashtable-set! %device-colors client (vector fg bg cursor (vector-map color palette)))
    (for-each
      (lambda (t)
        (when (eq? (%terminal-client t) client)
          (%apply-colors! t)
          (%report-scheme! t)))
      (%all))))

(define (%unique-name base)
  (if (not (buffers:find base))
      base
      (let loop ([n 2])
        (let ([name (format "~a<~a>" base n)])
          (if (buffers:find name) (loop (fx+ n 1)) name)))))

(define (%program-name command)
  (let* ([program (car command)]
         [slash (let loop ([i (fx- (string-length program) 1)])
                  (cond [(fx< i 0) #f] [(char=? (string-ref program i) #\/) i] [else (loop (fx- i 1))]))])
    (if slash (substring program (fx+ slash 1) (string-length program)) program)))

(define (%shell-command)
  (or (shell)
      (let ([s (getenv "SHELL")]) (and s (not (string=? s "")) (list s)))
      '("/bin/sh")))

(define (%shell-folder) (string-append %plugin-folder "/shell"))

;; The shell reads the plugin's integration without changes to its
;; startup files: bash in POSIX mode reads ENV, zsh reads ZDOTDIR's
;; .zshenv first, and fish reads vendor configuration on XDG_DATA_DIRS.
(define (%integrated command)
  (let ([name (%program-name command)] [folder (%shell-folder)] [bootstrap (string-append (%shell-folder) "/bootstrap")])
    (cond
      [(string=? name "bash")
       (values (cons* (car command) "--posix" (cdr command))
               (append
                 (list (cons "ENV" (string-append bootstrap "/bash/inject.bash"))
                       (cons "TUNA_BASH_INJECT" (apply string-append "1" (map (lambda (a) (string-append " " a)) (cdr command)))))
                 (let ([env (getenv "ENV")]) (if env (list (cons "TUNA_BASH_ENV" env)) '()))
                 (if (getenv "HISTFILE")
                     '()
                     (list (cons "HISTFILE" (string-append (or (getenv "HOME") "") "/.bash_history"))
                           (cons "TUNA_BASH_UNEXPORT_HISTFILE" "1")))
                 (list (cons "TUNA_SHELL_INTEGRATION_DIR" folder))))]
      [(string=? name "zsh")
       (values command
               (append
                 (list (cons "ZDOTDIR" (string-append bootstrap "/zsh")))
                 (let ([z (getenv "ZDOTDIR")]) (if z (list (cons "TUNA_ZSH_ZDOTDIR" z)) '()))
                 (list (cons "TUNA_SHELL_INTEGRATION_DIR" folder))))]
      [(string=? name "fish")
       (values command
               (list (cons "XDG_DATA_DIRS" (string-append bootstrap ":" (or (getenv "XDG_DATA_DIRS") "/usr/local/share:/usr/share")))
                     (cons "TUNA_SHELL_INTEGRATION_XDG_DIR" bootstrap)
                     (cons "TUNA_SHELL_INTEGRATION_DIR" folder)))]
      [else (values command '())])))

(define (%own-environment)
  (list (cons "TERM" "xterm-ghostty")
        (cons "TERMINFO_DIRS" (string-append %plugin-folder "/build/terminfo:" (or (getenv "TERMINFO_DIRS") "")))
        (cons "COLORTERM" "truecolor")
        (cons "TERM_PROGRAM" "tuna")))

(define (%start-size client)
  (let-values ([(columns rows) (if client
                                   (views:body-size (layout:selected-view (layout:frame client)) client)
                                   (values #f #f))])
    (if (and columns rows) (cons columns rows) (cons 80 24))))

(define (%root-datum scrollback screen)
  (%root '() (%scrollback '() scrollback) (%screen '() screen)))

(define (%make-buffer name)
  (let ([b (buffers:make name (%root-datum "" ""))])
    (modes:set-major-mode mode b)
    b))

(define (%register! t)
  (eq-hashtable-set! %by-buffer (%terminal-buffer t) t)
  (%configure! t)
  (processes:set-buffer! (%terminal-process t) (%terminal-buffer t)))

(define (%attach! t from)
  (as-module (this-module)
    (processes:attach! (%terminal-process t) from (%on-output t) (%on-exit t))))

(define (%entry t)
  (vector (buffers:name (%terminal-buffer t)) (processes:id (%terminal-process t)) (%terminal-command t)
          (%terminal-directory t) (%terminal-input-mode t)))

(define (%save-entries!)
  (set-saved! %terminals
    (map %entry (filter (lambda (t) (and (%terminal-process t) (not (%terminal-status t)))) (%all)))))

(define (%forget-entry! t)
  (let ([p (%terminal-process t)])
    (when p
      (set-saved! %terminals (remp (lambda (e) (string=? (%entry-id e) (processes:id p))) (%terminals)))
      (screens:delete-screen! (%screen-file (processes:id p))))))

(define (%spawn command directory environment-changes size)
  (let-values ([(program extra) (if command (values command '()) (%integrated (%shell-command)))])
    (processes:start-for-user (car program) (cdr program)
      (processes:options
        [directory directory]
        [environment (append environment-changes (environment) extra (%own-environment))]
        [terminal (cons (cdr size) (car size))]
        [full-log (processes:full-log pause)]))))

(define (%begin! command directory environment-changes name client)
  (let* ([size (%start-size client)]
         [process (%spawn command directory environment-changes size)]
         [b (%make-buffer (%unique-name name))]
         [t (%make-terminal b process (ghostty:make-terminal (car size) (cdr size)) command directory 'semi-char client)])
    (%register! t)
    (%refresh! t)
    (%attach! t 0)
    (%save-entries!)
    b))

(define start
  (case-lambda
    [(command) (start command #f)]
    [(command options)
     (unless (or (not command) (and (pair? command) (list? command) (for-all string? command)))
       (assertion-violation 'terminal:start "not a list of strings or #f" command))
     (unless (or (not options) (processes:options? options))
       (assertion-violation 'terminal:start "not processes:options" options))
     (let ([directory (or (and options (processes:options-directory options)) (files:directory))]
           [changes (or (and options (processes:options-environment options)) '())])
       (%begin! command directory changes
         (if command (string-append "*" (%program-name command) "*") "*terminal*")
         (web:current-client)))]))


(define %last-selected #f)

(commands:define-command (open [prefix (commands:prefix-argument)])
  "Shows the terminal selected last, starting one when there is none; with a prefix argument, starts a new one."
  (let ([b (or (and (not prefix) %last-selected (%of %last-selected) %last-selected)
               (and (not prefix) (let ([ts (%all)]) (and (pair? ts) (%terminal-buffer (car ts)))))
               (start #f))])
    (layout:switch-to-buffer b)
    (let ([t (%of b)] [v (layout:selected-view)])
      (when t
        (eq-hashtable-set! (%terminal-seen-views t) v #t)
        (%follow! t (list v))))))

(define (terminal? v) (and (%of v) #t))

(define (%check-terminal who v)
  (let ([t (%of v)])
    (unless t (assertion-violation who "not a terminal" v))
    t))

(define (process terminal) (%terminal-process (%check-terminal 'terminal:process terminal)))

(define (title terminal) (%terminal-title (%check-terminal 'terminal:title terminal)))

(define (directory terminal) (%terminal-directory (%check-terminal 'terminal:directory terminal)))

(define (screen-text terminal)
  (let* ([t (%check-terminal 'terminal:screen-text terminal)] [rows (vector->list (%terminal-rows t))])
    (if (null? rows)
        ""
        (fold-left (lambda (acc r) (string-append acc "\n" (%row-text r))) (%row-text (car rows)) (cdr rows)))))

(define (%sendable who t)
  (when (or (%terminal-status t) (not (%terminal-process t)) (processes:status (%terminal-process t)))
    (assertion-violation who "the program has ended" (%terminal-buffer t))))

(define (send! terminal text)
  (let ([t (%check-terminal 'terminal:send! terminal)])
    (unless (string? text)
      (assertion-violation 'terminal:send! "not a string" text))
    (%sendable 'terminal:send! t)
    (processes:send! (%terminal-process t) text)))

(define (fit-size terminal client)
  (%check-terminal 'terminal:fit-size terminal)
  (unless (web:client? client)
    (assertion-violation 'terminal:fit-size "not a client" client))
  (let loop ([views (views:showing terminal)] [columns #f] [rows #f])
    (if (null? views)
        (values columns rows)
        (let-values ([(c r) (views:body-size (car views) client)])
          (if (and c r (memq (car views) (layout:views)))
              (loop (cdr views) (if columns (fxmin columns c) c) (if rows (fxmin rows r) r))
              (loop (cdr views) columns rows))))))

(define (kill-query buffer)
  (unless (buffers:buffer? buffer)
    (assertion-violation 'terminal:kill-query "not a buffer" buffer))
  (let ([t (%of buffer)])
    (or (not t) (%terminal-status t)
        (let* ([p (%terminal-process t)] [group (processes:foreground-group p)] [pid (processes:pid p)])
          (or (not group) (not pid) (= group pid)
              (ask:y-or-n? (format "~a runs a job; kill it and the job? " (buffers:name buffer))))))))

(define (semi-char-mode?) (let ([t (%current-terminal)]) (and t (eq? (%terminal-input-mode t) 'semi-char))))
(define (char-mode?) (let ([t (%current-terminal)]) (and t (eq? (%terminal-input-mode t) 'char))))
(define (copy-mode?) (let ([t (%current-terminal)]) (and t (eq? (%terminal-input-mode t) 'copy))))

(define (%set-input-mode! t mode)
  (%terminal-input-mode-set! t mode)
  (%save-entries!))

(define (%leave-copy-mode! t)
  (%set-input-mode! t (%terminal-mode-before-copy t))
  (for-each (lambda (v) (views:set-mark! v #f)) (views:showing (%terminal-buffer t)))
  (%refresh! t)
  (%follow! t (views:showing (%terminal-buffer t))))

(define (%enter-copy-mode! t)
  (unless (eq? (%terminal-input-mode t) 'copy)
    (%terminal-mode-before-copy-set! t (%terminal-input-mode t))
    (%set-input-mode! t 'copy)))

(commands:define-command (semi-char-mode)
  "Puts the current terminal in semi-char mode, where keys go to the program but those that start Tuna's sequences."
  (let ([t (%current 'terminal:semi-char-mode)])
    (if (eq? (%terminal-input-mode t) 'copy)
        (begin (%terminal-mode-before-copy-set! t 'semi-char) (%leave-copy-mode! t))
        (%set-input-mode! t 'semi-char))))

(commands:define-command (char-mode)
  "Puts the current terminal in char mode, where every key but Super keys and M-RET goes to the program."
  (let ([t (%current 'terminal:char-mode)])
    (if (eq? (%terminal-input-mode t) 'copy)
        (begin (%terminal-mode-before-copy-set! t 'char) (%leave-copy-mode! t))
        (%set-input-mode! t 'char))))

(commands:define-command (copy-mode)
  "Puts the current terminal in copy mode, where keys are Tuna's, or out of it into the mode it was in before."
  (let ([t (%current 'terminal:copy-mode)])
    (if (eq? (%terminal-input-mode t) 'copy)
        (%leave-copy-mode! t)
        (%enter-copy-mode! t))))

(define %named-keys
  '(("RET" . enter) ("TAB" . tab) ("ESC" . escape) ("DEL" . backspace) ("SPC" . space)
    ("<delete>" . delete) ("<insert>" . insert) ("<left>" . arrow-left) ("<right>" . arrow-right)
    ("<up>" . arrow-up) ("<down>" . arrow-down) ("<home>" . home) ("<end>" . end)
    ("<prior>" . page-up) ("<next>" . page-down) ("<f1>" . f1) ("<f2>" . f2) ("<f3>" . f3)
    ("<f4>" . f4) ("<f5>" . f5) ("<f6>" . f6) ("<f7>" . f7) ("<f8>" . f8) ("<f9>" . f9)
    ("<f10>" . f10) ("<f11>" . f11) ("<f12>" . f12)))

;; Characters by their key on a US keyboard, the layout the key encoder
;; assumes for the Kitty protocol's base keys.
(define %us-keys
  (let ([t (make-eqv-hashtable)])
    (define (add! chars shifted key)
      (string-for-each (lambda (c) (hashtable-set! t c (cons key shifted))) chars))
    (do ([i 0 (fx+ i 1)]) ((fx= i 26))
      (let ([key (string->symbol (string (integer->char (fx+ 97 i))))])
        (hashtable-set! t (integer->char (fx+ 97 i)) (cons key #f))
        (hashtable-set! t (integer->char (fx+ 65 i)) (cons key #t))))
    (for-each (lambda (d) (hashtable-set! t (string-ref (number->string d) 0)
                            (cons (string->symbol (format "digit-~a" d)) #f)))
              (iota 10))
    (for-each (lambda (p) (add! (car p) #t (cdr p)))
      '((")" . digit-0) ("!" . digit-1) ("@" . digit-2) ("#" . digit-3) ("$" . digit-4) ("%" . digit-5)
        ("^" . digit-6) ("&" . digit-7) ("*" . digit-8) ("(" . digit-9) ("~" . backquote) ("_" . minus)
        ("+" . equal) ("{" . bracket-left) ("}" . bracket-right) ("|" . backslash) (":" . semicolon)
        ("\"" . quote) ("<" . comma) (">" . period) ("?" . slash)))
    (for-each (lambda (p) (add! (car p) #f (cdr p)))
      '(("`" . backquote) ("-" . minus) ("=" . equal) ("[" . bracket-left) ("]" . bracket-right)
        ("\\" . backslash) (";" . semicolon) ("'" . quote) ("," . comma) ("." . period) ("/" . slash)
        (" " . space)))
    t))

(define %modifiers (enum-set-constructor (ghostty:key-modifiers)))

(define (%unshifted key-symbol c)
  (let ([s (symbol->string key-symbol)])
    (cond
      [(fx= (string-length s) 1) (string-ref s 0)]
      [(%prefix-at? s 0 "digit-") (string-ref s 6)]
      [else (let ([found (find (lambda (p) (eq? (cdr p) key-symbol))
                               '((#\` . backquote) (#\- . minus) (#\= . equal) (#\[ . bracket-left)
                                 (#\] . bracket-right) (#\\ . backslash) (#\; . semicolon) (#\' . quote)
                                 (#\, . comma) (#\. . period) (#\/ . slash) (#\space . space)))])
              (if found (car found) c))])))

(define (%key-event key)
  (let loop ([i 0] [mods '()])
    (if (and (fx< (fx+ i 1) (string-length key)) (char=? (string-ref key (fx+ i 1)) #\-)
             (memv (string-ref key i) '(#\C #\M #\S #\s))
             (fx> (string-length key) (fx+ i 2)))
        (loop (fx+ i 2) (cons (case (string-ref key i) [(#\C) 'ctrl] [(#\M) 'alt] [(#\S) 'shift] [else 'super]) mods))
        (let ([base (substring key i (string-length key))])
          (cond
            [(assoc base %named-keys)
             => (lambda (p)
                  (ghostty:make-key-event 'press (cdr p) (%modifiers mods)
                    (and (string=? base "SPC") (null? (remq 'shift mods)) " ")
                    (and (string=? base "SPC") #\space)))]
            [(fx= (string-length base) 1)
             (let* ([c (string-ref base 0)] [us (hashtable-ref %us-keys c #f)])
               (if us
                   (let ([mods (if (cdr us) (cons 'shift mods) mods)])
                     (ghostty:make-key-event 'press (car us) (%modifiers mods)
                       (and (not (memq 'ctrl mods)) (not (memq 'alt mods)) (string c))
                       (%unshifted (car us) c) #f
                       (if (cdr us) (%modifiers '(shift)) (%modifiers '()))))
                   (ghostty:make-key-event 'press 'unidentified (%modifiers mods)
                     (string c) c)))]
            [else #f])))))

(define (%encoded-key t key)
  (let ([event (%key-event key)] [encoder (%terminal-key-encoder t)])
    (and event
         (begin
           (ghostty:key-encoder-sync! encoder (%terminal-emulator t))
           (let ([bytes (ghostty:key-encoder-encode encoder event)])
             (and (fx> (bytevector-length bytes) 0) bytes))))))

(define (%note-input! t)
  (let ([client (web:current-client)])
    (when (and client (not (eq? client (%terminal-client t))))
      (%terminal-client-set! t client)
      (%apply-colors! t)
      (%report-scheme! t))
    (when client (%terminal-sizes-set! t #f))))

(define (%warn-ended)
  (raise-continuable (condition (make-warning) (make-message-condition "the program has ended"))))

;; Sending brings point back to the program's cursor in the view that
;; sent, so the reply shows where the user typed.
(define (%send-bytes! t bytes)
  (cond
    [(or (%terminal-status t) (processes:status (%terminal-process t))) (%warn-ended)]
    [else
     (%note-input! t)
     (processes:send! (%terminal-process t) bytes)
     (let ([v (views:current)])
       (when (and v (eq? (views:buffer v) (%terminal-buffer t)))
         (%follow! t (list v))))]))

(define (%last-key keys)
  (let loop ([i (fx- (string-length keys) 1)])
    (cond
      [(fx< i 0) keys]
      [(char=? (string-ref keys i) #\space) (substring keys (fx+ i 1) (string-length keys))]
      [else (loop (fx- i 1))])))

(commands:define-command (send-key [keys (keys:command-keys)])
  "Sends the last key of KEYS to the program, encoded as its modes ask; in copy mode, first leaves it."
  (let ([t (%current 'terminal:send-key)])
    (unless (string? keys)
      (assertion-violation 'terminal:send-key "not a key sequence" keys))
    (when (eq? (%terminal-input-mode t) 'copy) (%leave-copy-mode! t))
    (let ([bytes (%encoded-key t (%last-key keys))])
      (when bytes (%send-bytes! t bytes)))))

(commands:define-command (send-next-key)
  "Sends the next key to the program, whatever its bindings."
  (%current 'terminal:send-next-key)
  (keys:push-keymap! (web:current-client) %next-keymap (lambda (found command) #f)))

(define (%paste-text! t text)
  (cond
    [(or (%terminal-status t) (processes:status (%terminal-process t))) (%warn-ended)]
    [else
     (%note-input! t)
     (when (eq? (%terminal-input-mode t) 'copy) (%leave-copy-mode! t))
     (ghostty:terminal-paste-unsafe! (%terminal-emulator t) text)]))

(commands:define-command (paste text)
  "Sends TEXT to the program as a paste: bracketed when it asked, otherwise with line breaks as carriage returns."
  (let ([t (%current 'terminal:paste)])
    (unless (string? text)
      (assertion-violation 'terminal:paste "not a string" text))
    (%paste-text! t text)))

(commands:define-command (yank)
  "Sends the kill ring's current entry to the program as a paste."
  (let ([t (%current 'terminal:yank)] [entry (kill-ring:current)])
    (when entry (%paste-text! t (kill-ring:text entry)))))

(commands:define-command (mouse-yank-primary)
  "Selects the view clicked and sends the primary selection to the program as a paste; does nothing without one."
  (let ([t (%current 'terminal:mouse-yank-primary)] [primary (editing:primary-selection)])
    (layout:select! (views:current))
    (when primary (%paste-text! t (kill-ring:text (list primary))))))

(define (%posn-cell t posn)
  (let-values ([(column row) (views:posn-cell posn)])
    (and column
         (let ([emu (%terminal-emulator t)])
           (cons (fxmin column (fx- (ghostty:terminal-columns emu) 1))
                 (fxmin row (fx- (ghostty:terminal-rows emu) 1)))))))

(define %cell-width 10)
(define %cell-height 20)

(define (%mouse-modifiers event)
  (filter symbol?
    (map (lambda (m) (case m [(control) 'ctrl] [(meta) 'alt] [(shift) 'shift] [(super) 'super] [else #f]))
         (keys:event-modifiers event))))

(define (%mouse-button event)
  (case (keys:event-basic-type event)
    [(mouse-1) 'left]
    [(mouse-2) 'middle]
    [(mouse-3) 'right]
    [(wheel-up) 'four]
    [(wheel-down) 'five]
    [(wheel-left) 'six]
    [(wheel-right) 'seven]
    [else #f]))

(define-table %drag-keymap)

(define (%follow-drag!)
  (keys:push-keymap! (web:current-client) %drag-keymap
    (lambda (found command) (eq? found %drag-keymap))))

(commands:define-command (send-mouse [event (keys:command-event)])
  "Sends a mouse key to the program as a mouse report, at the cell the event names, while it takes the mouse."
  (let ([t (%current 'terminal:send-mouse)])
    (unless (keys:event? event)
      (assertion-violation 'terminal:send-mouse "not a mouse event" event))
    (let* ([basic (keys:event-basic-type event)] [modifiers (keys:event-modifiers event)]
           [action (cond
                     [(eq? basic 'mouse-movement) 'motion]
                     [(or (memq 'down modifiers) (not (memq basic '(mouse-1 mouse-2 mouse-3)))) 'press]
                     [else 'release])]
           [cell (%posn-cell t (keys:event-end event))]
           [emu (%terminal-emulator t)] [encoder (%terminal-mouse-encoder t)])
      (when (and (eq? action 'press) (memq 'down modifiers))
        (%terminal-pressed-set! t (%mouse-button event))
        (%follow-drag!))
      (when cell
        (ghostty:mouse-encoder-sync! encoder emu)
        (ghostty:mouse-encoder-set-geometry! encoder
          (ghostty:make-mouse-geometry (fx* %cell-width (ghostty:terminal-columns emu))
            (fx* %cell-height (ghostty:terminal-rows emu)) %cell-width %cell-height 0 0 0 0))
        (ghostty:mouse-encoder-set-any-button-pressed! encoder (eq? action 'motion))
        (let ([bytes (ghostty:mouse-encoder-encode encoder
                       (ghostty:make-mouse-event action (if (eq? action 'motion) (%terminal-pressed t) (%mouse-button event))
                         (fx+ (fx* (car cell) %cell-width) (fxquotient %cell-width 2))
                         (fx+ (fx* (cdr cell) %cell-height) (fxquotient %cell-height 2))
                         (%modifiers (%mouse-modifiers event))))])
          (when (fx> (bytevector-length bytes) 0)
            (%send-bytes! t bytes))))
      (when (eq? action 'release)
        (%terminal-pressed-set! t #f)))))

(commands:define-command (send-alternate-scroll [event (keys:command-event)])
  "Sends a wheel turn to the program as an up or down arrow key, encoded as its modes ask, as xterm's alternate scroll mode does, while the alternate screen shows and alternate scroll is on."
  (let ([t (%current 'terminal:send-alternate-scroll)])
    (unless (keys:event? event)
      (assertion-violation 'terminal:send-alternate-scroll "not a mouse event" event))
    (let ([key (case (keys:event-basic-type event) [(wheel-up) "<up>"] [(wheel-down) "<down>"] [else #f])])
      (when (and key (%alternate-scroll? t))
        (let ([bytes (%encoded-key t key)])
          (when bytes (%send-bytes! t bytes)))))))

(define (%link-at t position)
  (let ([inside (filter (lambda (s) (and (fx<= (car s) position) (fx< position (cadr s))))
                        (buffers:spans (buffers:layer (%terminal-buffer t) %links) position (fx+ position 1)))])
    (and (pair? inside) (cdr (assq 'terminal-link (caddr (car inside)))))))

(define (%cell-position t cell)
  (let ([rows (%terminal-rows t)])
    (and (fx< (cdr cell) (vector-length rows))
         (let loop ([i 0] [at (%screen-start t)])
           (let ([row (vector-ref rows i)])
             (if (fx= i (cdr cell))
                 (fx+ at (fxmin (%column->index row (car cell)) (string-length (%row-text row))))
                 (loop (fx+ i 1) (fx+ at (string-length (%row-text row)) 1))))))))

;; A click on a screen that names cells names the node, not the
;; character, so the cell gives the position.
(define (%clicked-or-point)
  (let ([event (keys:command-event)] [t (%current-terminal)])
    (or (and (keys:event? event)
             (let ([posn (keys:event-end event)])
               (or (and t (views:posn-node posn) (eq? (document:node-kind (views:posn-node posn)) 'terminal:%screen)
                        (let ([cell (%posn-cell t posn)]) (and cell (%cell-position t cell))))
                   (views:posn-point posn))))
        (views:point (views:current)))))

(commands:define-command (open-link [position (%clicked-or-point)])
  "Opens the link at POSITION: a web address in a new tab of the browser that ran the command, a file at its line."
  (let ([t (%current 'terminal:open-link)])
    (unless (and (fixnum? position) (fx>= position 0))
      (assertion-violation 'terminal:open-link "not a position" position))
    (let ([target (%link-at t position)])
      (cond
        [(not target) (assertion-violation 'terminal:open-link "no link here" position)]
        [(string? target) (browse-url:open target)]
        [else
         (let* ([b (files:visit (vector-ref target 0))] [v (layout:display-buffer b)] [doc (buffers:document b)]
                [line (vector-ref target 1)] [column (vector-ref target 2)])
           (when line
             (let* ([lines (document:line doc (document:length doc))]
                    [line (fxmax 1 (fxmin line lines))]
                    [start (fxmax 1 (document:line-start doc line))]
                    [end (if (fx< line lines) (fx- (document:line-start doc (fx+ line 1)) 1) (fx- (document:length doc) 1))])
               (views:set-point! v (fxmin end (fx+ start (fxmax 0 (fx- (or column 1) 1))))))))]))))

(define (%move-to-span! who layer forward?)
  (let* ([t (%current who)] [v (views:current)] [p (views:point v)] [b (%terminal-buffer t)]
         [doc (buffers:document b)] [spans (buffers:spans (buffers:layer b layer) 0 (document:length doc))]
         [starts (map car spans)]
         [found (if forward?
                    (find (lambda (s) (fx> s p)) starts)
                    (let ([before (filter (lambda (s) (fx< s p)) starts)]) (and (pair? before) (car (reverse before)))))])
    (cond
      [found
       (%enter-copy-mode! t)
       (views:set-point! v found)]
      [else
       (raise-continuable
         (condition (make-warning)
           (make-message-condition
             (format "No ~a ~a" (if forward? "next" "previous") (if (eq? layer %links) "link" "prompt")))))])))

(commands:define-command (next-link)
  "Enters copy mode and moves point to the next link."
  (%move-to-span! 'terminal:next-link %links #t))

(commands:define-command (previous-link)
  "Enters copy mode and moves point to the previous link."
  (%move-to-span! 'terminal:previous-link %links #f))

(commands:define-command (next-prompt)
  "Enters copy mode and moves point to the input of the next prompt the shell marked."
  (%move-to-span! 'terminal:next-prompt %inputs #t))

(commands:define-command (previous-prompt)
  "Enters copy mode and moves point to the input of the previous prompt the shell marked."
  (%move-to-span! 'terminal:previous-prompt %inputs #f))

;; A command that leaves a region outside copy mode puts the terminal in
;; it, so output never moves the region.
(define (%region-to-copy-mode command)
  (let* ([v (views:current)] [t (and v (%of (views:buffer v)))])
    (when (and t (not (eq? (%terminal-input-mode t) 'copy)) (views:mark v))
      (%enter-copy-mode! t))))

(define (%resize-to-fit! t)
  (let ([client (%terminal-client t)])
    (when (and client (memq client (web:clients)) (not (%terminal-status t)))
      (let ([measured (map (lambda (v) (call-with-values (lambda () (views:body-size v client)) cons))
                           (views:showing (%terminal-buffer t)))])
        (unless (equal? measured (%terminal-sizes t))
          (%terminal-sizes-set! t measured)
          (let-values ([(columns rows) (fit-size (%terminal-buffer t) client)])
            (when (and columns rows (not (equal? (cons columns rows) (%terminal-size t))))
              (%terminal-size-set! t (cons columns rows))
              (let ([following (%following-views t)])
                (ghostty:terminal-resize! (%terminal-emulator t) columns rows)
                (processes:resize! (%terminal-process t) rows columns)
                (%refresh! t)
                (%follow! t following)))))))))

(define (%report-focus! t)
  (let* ([selected (layout:selected-view)]
         [focused? (and (memq selected (views:showing (%terminal-buffer t))) #t)])
    (unless (eq? focused? (%terminal-focused? t))
      (%terminal-focused?-set! t focused?)
      (when (and (not (%terminal-status t)) (ghostty:terminal-mode-enabled? (%terminal-emulator t) 'focus-event))
        (processes:send! (%terminal-process t) (ghostty:focus-encode (if focused? 'gained 'lost)))))))

(define (%meet-new-views! t)
  (let ([seen (%terminal-seen-views t)])
    (for-each
      (lambda (v)
        (unless (eq-hashtable-ref seen v #f)
          (eq-hashtable-set! seen v #t)
          (when (%terminal-alternate? t)
            (let ([node (%screen-node (%terminal-buffer t))])
              (views:narrow! v (document:node-start node) (document:node-end node))))
          (%follow! t (list v))))
      (views:showing (%terminal-buffer t)))))

(define (%after-batch)
  (let ([selected (layout:selected-view)])
    (when (and selected (%of (views:buffer selected)))
      (set! %last-selected (views:buffer selected))))
  (for-each
    (lambda (t)
      (%meet-new-views! t)
      (%resize-to-fit! t)
      (%report-focus! t)
      (when (%terminal-changed? t)
        (%terminal-changed?-set! t #f)
        (screen-changed (%terminal-buffer t))))
    (%all)))

(define (%screens-folder)
  (or (%folder)
      (let ([folder (format "~a/.local/share/tuna/terminal/~a-~a" (or (getenv "HOME") "")
                      (time-second (current-time 'time-utc)) (random 1000000000))])
        (set-saved! %folder folder)
        folder)))

(define (%screen-file id) (string-append (%screens-folder) "/" id ".screen"))

(define (%keep-screens!)
  (for-each
    (lambda (t)
      (when (and (%terminal-process t) (not (%terminal-status t)))
        (%write-screen! t)
        (let ([snapshot (ghostty:terminal->snapshot (%terminal-emulator t))] [id (processes:id (%terminal-process t))])
          (screens:keep-screen! id snapshot (%terminal-applied t))
          (screens:write-screen! (%screen-file id) snapshot (%terminal-applied t)))))
    (%all))
  (%save-entries!)
  (for-each %close-natives! (%all))
  (unless (screens:wait-for-writes 2)
    (report (condition (make-warning) (make-message-condition "terminal: screens were not all written within 2 seconds"))))
  (for-each report (screens:take-write-failures)))

(define (%close-natives! t)
  (let ([tracked (%terminal-tracked t)])
    (when tracked (ghostty:tracked-point-close! tracked)))
  (ghostty:render-state-close! (%terminal-render t))
  (ghostty:key-encoder-close! (%terminal-key-encoder t))
  (ghostty:mouse-encoder-close! (%terminal-mouse-encoder t))
  (ghostty:terminal-close! (%terminal-emulator t)))

(define (%fill-from-emulator! t)
  (let ([count (ghostty:terminal-scrollback-rows (%terminal-emulator t))])
    (%clear-scrollback! t)
    (%terminal-rows-set! t (vector))
    (unless (eq? (ghostty:terminal-active-screen (%terminal-emulator t)) 'alternate)
      (%append-history! t (%read-history t 0 count))
      (%track-newest! t count))
    (let-values ([(rows cursor) (%screen-rows t)])
      (%write-rows! t rows)
      (%terminal-cursor-set! t cursor))))

(define (%restored-emulator id)
  (let ([kept (or (screens:take-screen id) (screens:read-screen (%screen-file id)))])
    (and kept
         (guard (c [(ghostty:ghostty-error? c) (report c) #f])
           (cons (ghostty:snapshot->terminal (car kept)) (cdr kept))))))

(define (%entry-buffer name)
  (let ([b (buffers:find name)])
    (if (and b (eq? (modes:major-mode b) mode) (%screen-node b))
        (values b #t)
        (values (%make-buffer (if b (%unique-name name) name)) #f))))

(define (%reattach! entry process)
  (let ([restored (%restored-emulator (%entry-id entry))])
    (let-values ([(b kept?) (%entry-buffer (%entry-name entry))])
      (let* ([emu (if restored (car restored) (ghostty:make-terminal 80 24))]
             [t (%make-terminal b process emu (%entry-command entry) (%entry-directory entry) (%entry-input-mode entry) #f)])
        (%terminal-mode-before-copy-set! t 'semi-char)
        (%register! t)
        (if kept?
            (%adopt-buffer! t)
            (%fill-from-emulator! t))
        (let* ([from (if restored (cdr restored) 0)] [start (%attach! t from)])
          (%terminal-applied-set! t start)
          (when (> start from)
            (ghostty:terminal-reset! emu)
            (%track-newest! t 0)
            (%note! t "[Output was lost here.]")
            (%refresh! t)
            (let ([size (%terminal-size t)])
              (processes:resize! process (cdr size) (fxmax 1 (fx- (car size) 1)))
              (processes:resize! process (cdr size) (car size)))))))))

;; A buffer kept across the plugin's reload already holds what the
;; emulator's snapshot holds, so only the rows it shows are read back.
(define (%adopt-buffer! t)
  (let* ([b (%terminal-buffer t)] [emu (%terminal-emulator t)] [count (ghostty:terminal-scrollback-rows emu)]
         [doc (buffers:document b)] [node (%scrollback-node b)]
         [start (fx+ (document:node-start node) 1)] [end (fx- (document:node-end node) 1)])
    (%terminal-scrollback-count-set! t (if (fx= start end) 0 (fx- (document:line doc end) (document:line doc start))))
    (%terminal-alternate?-set! t (eq? (ghostty:terminal-active-screen emu) 'alternate))
    ;; The primary screen's history cannot be tracked while the alternate
    ;; screen shows, so it is copied again whole when the program leaves.
    (if (%terminal-alternate? t)
        (%clear-scrollback! t)
        (%track-newest! t count))
    (let ([screen (%screen-node b)])
      (let-values ([(rows cursor) (%screen-rows t)])
        ;; The old rows are unknown, so the screen is written whole.
        (%terminal-rows-set! t (vector))
        (%splice! b (fx+ (document:node-start screen) 1) (fx- (document:node-end screen) 1) (document:from-datum ""))
        (%write-rows! t rows)
        (%terminal-cursor-set! t cursor)))))

(define (%revive-shell! entry)
  (let ([restored (%restored-emulator (%entry-id entry))])
    (let-values ([(b kept?) (%entry-buffer (%entry-name entry))])
      (let* ([directory (let ([d (%entry-directory entry)]) (if (file-directory? d) d (files:directory)))]
             [old (and restored (car restored))])
        (when old
          (let ([ghost (%make-terminal b #f old #f directory 'semi-char #f)])
            (%fill-from-emulator! ghost)
            (let ([rows (filter (lambda (r) (not (string=? (%row-text r) ""))) (vector->list (%terminal-rows ghost)))])
              (%terminal-rows-set! ghost (vector))
              (let ([screen (%screen-node b)])
                (%splice! b (fx+ (document:node-start screen) 1) (fx- (document:node-end screen) 1) (document:from-datum "")))
              (%append-scrollback! ghost rows)
              (%note! ghost "[The shell ended.]"))
            (%close-natives! ghost)))
        (screens:delete-screen! (%screen-file (%entry-id entry)))
        (let* ([size (cons 80 24)]
               [process (%spawn #f directory '() size)]
               [t (%make-terminal b process (ghostty:make-terminal (car size) (cdr size)) #f directory 'semi-char #f)])
          (%terminal-scrollback-count-set! t
            (let* ([doc (buffers:document b)] [node (%scrollback-node b)]
                   [start (fx+ (document:node-start node) 1)] [end (fx- (document:node-end node) 1)])
              (if (fx= start end) 0 (fx- (document:line doc end) (document:line doc start)))))
          (%register! t)
          (%refresh! t)
          (%attach! t 0))))))

;; A shell is revived only once the configuration has set the options it
;; starts with, which reach a module after its body has run.
(define (%restore!)
  (let ([gone (filter (lambda (entry) (not (processes:find (%entry-id entry)))) (%terminals))])
    (for-each
      (lambda (entry)
        (guard (c [(not (quit-condition? c)) (report c)])
          (let ([process (processes:find (%entry-id entry))])
            (when process (%reattach! entry process)))))
      (%terminals))
    (if (null? gone)
        (%save-entries!)
        (post!
          (lambda ()
            (for-each
              (lambda (entry)
                (guard (c [(not (quit-condition? c)) (report c)])
                  (if (%entry-command entry)
                      (screens:delete-screen! (%screen-file (%entry-id entry)))
                      (%revive-shell! entry))))
              gone)
            (%save-entries!))))))

(define (%named-key-names) (map car %named-keys))

;; A keymap binds key strings, not every key, so the keys a terminal
;; sends are listed.
(define (%sendable-keys)
  (append
    (apply append
      (map (lambda (name)
             (map (lambda (prefix) (string-append prefix name))
                  '("" "C-" "M-" "S-" "C-M-" "C-S-" "M-S-" "C-M-S-")))
           (%named-key-names)))
    (apply append
      (map (lambda (i)
             (let ([c (string (integer->char i))])
               (list (string-append "C-" c) (string-append "M-" c) (string-append "C-M-" c))))
           (map (lambda (i) (fx+ i 33)) (iota 94))))))

(define (%prefix-of? prefix key)
  (or (string=? prefix key) (%prefix-at? key 0 (string-append prefix " "))))

(define %semi-char-exceptions '("C-c" "C-x" "C-u" "C-h" "M-x" "M-:" "C-SPC"))

(define (%bind-keys!)
  (for-each
    (lambda (key)
      (keys:bind! %next-keymap key send-key)
      (unless (string=? key "M-RET") (keys:bind! char-keymap key send-key))
      (unless (member key %semi-char-exceptions) (keys:bind! semi-char-keymap key send-key)))
    (%sendable-keys))
  (keys:bind! %next-keymap "<printing-char>" send-key)
  (keys:bind! char-keymap "<printing-char>" send-key)
  (keys:bind! semi-char-keymap "<printing-char>" send-key)
  (keys:bind! semi-char-keymap "C-y" yank)
  (keys:bind! semi-char-keymap "C-q" send-next-key)
  (keys:bind! semi-char-keymap "S-<prior>" views:scroll-down)
  (keys:bind! semi-char-keymap "S-<next>" views:scroll-up)
  (keys:remap! semi-char-keymap editing:yank yank)
  (keys:bind! char-keymap "M-RET" semi-char-mode)
  (keys:bind! copy-keymap "<printing-char>" send-key)
  (keys:bind! copy-keymap "q" copy-mode)
  (keys:bind! copy-keymap "C-g" copy-mode)
  (keys:bind! copy-keymap "RET" open-link)
  (keys:bind! keymap "C-c C-c" send-key)
  (keys:bind! keymap "C-c C-z" send-key)
  (keys:bind! keymap "C-c C-\\" send-key)
  (keys:bind! keymap "C-c C-d" send-key)
  (keys:bind! keymap "C-c C-q" send-next-key)
  (keys:bind! keymap "C-c C-y" yank)
  (keys:bind! keymap "C-c C-t" copy-mode)
  (keys:bind! keymap "C-c C-j" semi-char-mode)
  (keys:bind! keymap "C-c M-d" char-mode)
  (keys:bind! keymap "C-c C-n" next-link)
  (keys:bind! keymap "C-c C-p" previous-link)
  (keys:bind! keymap "C-c M-n" next-prompt)
  (keys:bind! keymap "C-c M-p" previous-prompt)
  (keys:remap! keymap editing:paste paste)
  (keys:remap! keymap editing:mouse-yank-primary mouse-yank-primary)
  (for-each
    (lambda (modifiers)
      (for-each (lambda (key) (keys:bind! mouse-keymap (string-append modifiers key) send-mouse))
                '("<down-mouse-1>" "<mouse-1>" "<drag-mouse-1>" "<down-mouse-2>" "<mouse-2>" "<drag-mouse-2>"
                  "<down-mouse-3>" "<mouse-3>" "<drag-mouse-3>" "<wheel-up>" "<wheel-down>" "<wheel-left>" "<wheel-right>")))
    '("" "C-" "M-" "C-M-"))
  (keys:bind! mouse-keymap "C-<mouse-1>" open-link)
  (keys:bind! mouse-keymap "C-<down-mouse-1>" keys:ignore)
  (keys:bind! mouse-keymap "C-<drag-mouse-1>" keys:ignore)
  (keys:bind! mouse-keymap "S-<down-mouse-1>" editing:mouse-drag-region)
  (keys:bind! mouse-keymap "S-<mouse-1>" editing:mouse-set-point)
  (keys:bind! mouse-keymap "S-<drag-mouse-1>" editing:mouse-set-region)
  (keys:bind! %drag-keymap "<mouse-movement>" send-mouse)
  (keys:bind! keymap "<wheel-up>" send-alternate-scroll)
  (keys:bind! keymap "<wheel-down>" send-alternate-scroll)
  (keys:bind! keymap "<wheel-left>" keys:ignore)
  (keys:bind! keymap "<wheel-right>" keys:ignore)
  (keys:bind! %link-keymap "<mouse-1>" open-link)
  (keys:bind! %link-keymap "C-<mouse-1>" open-link))

(define (%no-undo) (set-option-local! undo:limit 0))

(modes:define-major-mode mode
  (lighter "Terminal")
  (keymap keymap)
  (hook mode-hook))

(add-hook! mode-hook %no-undo)

(table-set! modes:minor-modes copy-mode? -30)
(table-set! modes:minor-modes char-mode? -20)
(table-set! modes:minor-modes semi-char-mode? -10)
(table-set! modes:keymaps copy-mode? copy-keymap)
(table-set! modes:keymaps char-mode? char-keymap)
(table-set! modes:keymaps semi-char-mode? semi-char-keymap)
(table-set! modes:lighters copy-mode? "Copy")
(table-set! modes:lighters char-mode? "Char")

(table-set! views:span-properties 'terminal %style-attributes)
(table-set! views:span-properties 'terminal-cells %cells-attributes)
(table-set! views:span-properties 'terminal-link %link-attributes)
(table-set! web:stylesheets 'terminal "terminal/terminal.css")
(table-set! web:scripts 'terminal "terminal/terminal.js")
(table-set! web:input-handlers "terminal-colors" %colors-item)
(add-hook! buffers:kill-queries kill-query)
(add-hook! commands:after-command %region-to-copy-mode)
(advice-add! batch-ended
  (lambda (ended)
    (guard (c [#t (report c)]) (as-module (this-module) (%after-batch)))
    (ended)))
(%bind-keys!)
(%restore!)
(on-unload %keep-screens!)

;;; A terminal's rows as one text, for copy mode: each row a line, as the
;;; screen shows it (runs, and spaces between them), with where each row
;;; starts, which line ends only wrap a longer line of the program's,
;;; highlight spans for the runs' palette colours and links, and the
;;; links. Positions are 1-based characters, as in Tuna's texts. Copying
;;; a region drops the wrapping line ends and each line's trailing
;;; spaces, so the text is what the program wrote (ghostel's
;;; `ghostel--clean-copy-text`).
prelude: :gerbil/core

(import :tuna/plugins/buffers/contract
        (only-in ./screen char-cells))
(export (struct-out copy-text copy-link)
        rows->copy-text
        row-text
        cell->index
        copy-text-row-of
        copy-text-position
        copy-text-prompt-target
        copy-text-clean
        copy-text-link-at)

;; One link: the characters START to END (exclusive) lead to URI.
(defstruct copy-link ((start : :fixnum) (end : :fixnum) (uri : :string))
  final: #t)

;; TEXT, and for each row (from 0) the position its line starts at
;; (ROW-STARTS), the positions of the line ends that only wrap (WRAPS,
;; ascending), highlight SPANS (faces) and LINKS.
(defstruct copy-text ((text : :string)
                      (row-starts : :vector)
                      (wraps : :vector)
                      (spans : :list)
                      (links : :list))
  final: #t)

;; The text a row of RUNS shows: each run's text at its column, spaces
;; between.
(def (row-text (runs : :vector)) => :string
  (let ((out (open-output-string)))
    (let lp ((i 0) (column 0))
      (when (fx< i (vector-length runs))
        (let* ((run (vector-ref runs i))
               (start (vector-ref run 0)))
          (when (fx> start column) (write-string (make-string (fx- start column) #\space) out))
          (write-string (vector-ref run 2) out)
          (lp (fx1+ i) (fx+ start (vector-ref run 1))))))
    (get-output-string out)))

;; The index in ROW-TEXT of RUNS of the character at cell CELL.
(def (cell->index (runs : :vector) (cell : :fixnum)) => :fixnum
  (let lp ((i 0) (column 0) (index 0))
    (if (fx= i (vector-length runs))
      (fx+ index (fxmax 0 (fx- cell column)))
      (let* ((run (vector-ref runs i))
             (start (vector-ref run 0))
             (text (vector-ref run 2)))
        (cond
         ((fx< cell start) (fx+ index (fx- cell column)))
         ((fx< cell (fx+ start (vector-ref run 1)))
          (let walk ((j 0) (at start))
            (if (or (fx= j (string-length text)) (fx>= at cell)
                    (fx> (fx+ at (char-cells (string-ref text j))) cell))
              (fx+ index (fx- start column) j)
              (walk (fx1+ j) (fx+ at (char-cells (string-ref text j)))))))
         (else (lp (fx1+ i) (fx+ start (vector-ref run 1))
                   (fx+ index (fx- start column) (string-length text)))))))))

;; The face of a run's CLASSES: its palette foreground, or #f.
(def (run-face (classes : :string)) => (Maybe :symbol)
  (let lp ((parts (string-split classes #\space)))
    (match parts
      ([] #f)
      ([part . more]
       (if (and (string-prefix? "terminal-fg-" part) (string->number (substring part 12 (string-length part))))
         (string->symbol part)
         (lp more))))))

;; ROWS, each (RUNS . WRAP?), as one text.
(def (rows->copy-text (rows : :list)) => copy-text
  (let ((out (open-output-string))
        (starts [])
        (wraps [])
        (spans [])
        (links []))
    (let lp ((rows rows) (position 1))
      (match rows
        ([] (void))
        ([[runs . wrap?] . more]
         (let ((text (row-text runs)))
           (set! starts (cons position starts))
           (write-string text out)
           ;; The runs' faces and links, by character.
           (let run-loop ((i 0) (column 0) (at position))
             (when (fx< i (vector-length runs))
               (let* ((run (vector-ref runs i))
                      (start (vector-ref run 0))
                      (from (fx+ at (fxmax 0 (fx- start column))))
                      (to (fx+ from (string-length (vector-ref run 2))))
                      (face (run-face (vector-ref run 3)))
                      (uri (and (fx> (vector-length run) 5) (vector-ref run 5))))
                 (when (fx< from to)
                   (cond
                    (uri (set! spans (cons (make-span from to 'terminal-link) spans))
                         (set! links (cons (make-copy-link from to uri) links)))
                    (face (set! spans (cons (make-span from to face) spans)))))
                 (run-loop (fx1+ i) (fx+ start (vector-ref run 1)) to))))
           (let (end (fx+ position (string-length text)))
             (unless (null? more)
               (write-char #\newline out)
               (when wrap? (set! wraps (cons end wraps))))
             (lp more (fx1+ end)))))))
    (make-copy-text (get-output-string out) (list->vector (reverse starts)) (list->vector (reverse wraps))
                    (reverse spans) (reverse links))))

;; The row (from 0) holding POSITION.
(def (copy-text-row-of (c : copy-text) (position : :fixnum)) => :fixnum
  (let ((starts (copy-text-row-starts c)))
    (let search ((low 0) (high (vector-length starts)))
      (if (fx<= (fx- high low) 1)
        low
        (let (middle (fxquotient (fx+ low high) 2))
          (if (fx<= (vector-ref starts middle) position)
            (search middle high)
            (search low middle)))))))

;; The position of character INDEX of row ROW (from 0), kept within that
;; row's line.
(def (copy-text-position (c : copy-text) (row : :fixnum) (index : :fixnum)) => :fixnum
  (let* ((starts (copy-text-row-starts c))
         (row (fxmax 0 (fxmin row (fx1- (vector-length starts)))))
         (start (vector-ref starts row))
         (end (if (fx< (fx1+ row) (vector-length starts))
                (fx1- (vector-ref starts (fx1+ row)))
                (fx1+ (string-length (copy-text-text c))))))
    (fxmax start (fxmin end (fx+ start index)))))

;; Where prompt navigation from POINT goes in C (ghostel-next-prompt,
;; ghostel-previous-prompt): to where the input starts on the first row
;; after POINT's row a prompt starts on, when DIRECTION is 'next, or the
;; last one before it, 'previous; #f when there is none. PROMPTS are
;; those rows, ascending, each (ROW . INDEX): the row (from 0) and the
;; index in its line the input starts at.
(def (copy-text-prompt-target (c : copy-text) (prompts : :list) (point : :fixnum) (direction : :symbol))
  => (Maybe :fixnum)
  (let* ((here (copy-text-row-of c point))
         (prompt (if (eq? direction 'next)
                   (find (lambda ((p : :pair)) (fx> (car p) here)) prompts)
                   (find (lambda ((p : :pair)) (fx< (car p) here)) (reverse prompts)))))
    (and prompt (copy-text-position c (car prompt) (cdr prompt)))))

;; The text from START to END, the wrapping line ends dropped and each
;; line's trailing spaces with them.
(def (copy-text-clean (c : copy-text) (start : :fixnum) (end : :fixnum)) => :string
  (let ((text (copy-text-text c))
        (wraps (copy-text-wraps c))
        (out (open-output-string)))
    (let lp ((position start))
      (when (fx< position end)
        (let (ch (string-ref text (fx1- position)))
          (unless (and (char=? ch #\newline) (vector-index-of wraps position))
            (write-char ch out))
          (lp (fx1+ position)))))
    (string-join (map (lambda ((line : :string))
                        (let trim ((n (string-length line)))
                          (if (and (fx> n 0) (char=? (string-ref line (fx1- n)) #\space))
                            (trim (fx1- n))
                            (substring line 0 n))))
                      (string-split (get-output-string out) #\newline))
                 "\n")))

(def (vector-index-of (v : :vector) (x : :fixnum)) => :boolean
  (let search ((low 0) (high (vector-length v)))
    (and (fx< low high)
         (let* ((middle (fxquotient (fx+ low high) 2))
                (y (vector-ref v middle)))
           (cond
            ((fx= x y) #t)
            ((fx< x y) (search low middle))
            (else (search (fx1+ middle) high)))))))

;; The link at POSITION, or #f.
(def (copy-text-link-at (c : copy-text) (position : :fixnum)) => (Maybe :string)
  (let (link (find (lambda ((l : copy-link)) (and (fx<= (copy-link-start l) position) (fx< position (copy-link-end l))))
                   (copy-text-links c)))
    (and link (copy-link-uri link))))

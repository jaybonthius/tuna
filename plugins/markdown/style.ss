;;; Styling Markdown as it is typed: the highlight spans for a text's raw
;;; Markdown, from md4c's source offsets (gerbil-md4c). Headings are
;;; larger, spans look as they will (bold, italic, struck, code, link),
;;; code blocks are monospace, and the marks that make them (`#`, `**`,
;;; `` ` ``, fences, `>`, bullets, a link's address, table pipes) are
;;; dimmed.
prelude: :gerbil/core

(import :gerbil-md4c/md4c
        "faces")
(export markdown-style-spans)

;; The highlight spans for SOURCE, at text positions from 1.
(def (markdown-style-spans (source : :string)) => :list
  (styled-spans (append-map-blocks (cut block-ranges source <>) (markdown-parse source)) 1))

(def (append-map-blocks (f : :procedure) (l : :list)) => :list
  (apply append (map f l)))

;;; Lines

;; Where the line after the one holding AT ends, or SOURCE's end.
(def (line-end (source : :string) (at : :fixnum)) => :fixnum
  (let lp ((i at))
    (if (or (fx>= i (string-length source)) (char=? (string-ref source i) #\newline))
      i
      (lp (fx1+ i)))))

;; The starts of the lines of START..END of SOURCE.
(def (line-starts (source : :string) (start : :fixnum) (end : :fixnum)) => :list
  (let lp ((at start) (out []))
    (if (fx>= at end)
      (reverse (if (null? out) [start] out))
      (lp (fx1+ (line-end source at)) (cons at out)))))

;; Past the characters from AT that satisfy KEEP?, up to END.
(def (skip (source : :string) (at : :fixnum) (end : :fixnum) (keep? : :procedure)) => :fixnum
  (let lp ((i at))
    (if (and (fx< i end) (keep? (string-ref source i)))
      (lp (fx1+ i))
      i)))

(def (blank? (c : :char)) => :boolean
  (or (char=? c #\space) (char=? c #\tab)))

(def (quote-prefix? (c : :char)) => :boolean
  (or (blank? c) (char=? c #\>)))

;; Whether C may come before a heading's `#` on its line: quote marks
;; and a list item's marker.
(def (container-prefix? (c : :char)) => :boolean
  (or (quote-prefix? c) (char-numeric? c) (and (memv c '(#\- #\* #\+ #\. #\))) #t)))

;; The `>` marks at the start of each line of START..END.
(def (quote-marks (source : :string) (start : :fixnum) (end : :fixnum)) => :list
  (filter-map (lambda ((at : :fixnum))
                (let* ((from (skip source at end blank?))
                       (to (skip source from end quote-prefix?)))
                  (and (fx< from to) (make-styled from to 'marker))))
              (line-starts source start end)))

;; The list marker of the item starting at line START (after any quote
;; marks): a bullet, or a number and its delimiter, and a task's box.
(def (item-marks (source : :string) (start : :fixnum) (end : :fixnum) (task? : :boolean)) => :list
  (let* ((line (line-end source start))
         (from (skip source start line quote-prefix?))
         (to (if (and (fx< from line) (memv (string-ref source from) '(#\- #\* #\+)))
               (fx1+ from)
               (let (digits (skip source from line char-numeric?))
                 (if (and (fx> digits from) (fx< digits line) (memv (string-ref source digits) '(#\. #\))))
                   (fx1+ digits)
                   from))))
         (box (and task? (let (open (skip source to line blank?))
                           (and (fx<= (fx+ open 3) line) (char=? (string-ref source open) #\[)
                                (make-styled open (fx+ open 3) 'marker))))))
    (append (if (fx< from to) [(make-styled from to 'marker)] [])
            (if box [box] []))))

;; Whether the line at AT holds only C (after quote marks and blanks),
;; at least three of them.
(def (line-of? (source : :string) (at : :fixnum) (c : :char)) => :boolean
  (let* ((line (line-end source at))
         (from (skip source at line quote-prefix?))
         (to (skip source from line (cut char=? <> c))))
    (and (fx>= (fx- to from) 3) (fx= (skip source to line blank?) line))))

;;; Blocks

(def (heading-part (level : :fixnum)) => :symbol
  (case level
    ((1) 'heading-1) ((2) 'heading-2) ((3) 'heading-3)
    ((4) 'heading-4) ((5) 'heading-5) (else 'heading-6)))

(def (block-ranges (source : :string) (block : markdown-block)) => :list
  (let ((start (markdown-block-start block))
        (end (markdown-block-end block)))
    (cond
     ((markdown-paragraph? block) (inline-ranges (markdown-paragraph-inlines block)))
     ((markdown-heading? block)
      (let* ((line (line-end source start))
             (hashes (skip source start line container-prefix?))
             (after (skip source hashes line (cut char=? <> #\#)))
             (last-line (car (reverse (line-starts source start end)))))
        (append [(make-styled start end (heading-part (markdown-heading-level block)))]
                (if (fx> after hashes) [(make-styled hashes (skip source after line blank?) 'marker)] [])
                ;; A setext heading's underline.
                (if (and (fx> last-line start) (or (line-of? source last-line #\=) (line-of? source last-line #\-)))
                  [(make-styled last-line end 'marker)]
                  [])
                (inline-ranges (markdown-heading-inlines block)))))
     ((markdown-code-block? block)
      (let (lines (line-starts source start end))
        (cons (make-styled start end 'fence)
              (if (markdown-code-block-fenced? block)
                (let (last-line (car (reverse lines)))
                  (cons (make-styled start (line-end source start) 'marker)
                        (if (and (fx> last-line start)
                                 (or (line-of? source last-line #\`) (line-of? source last-line #\~)))
                          [(make-styled last-line end 'marker)]
                          [])))
                []))))
     ((markdown-quote? block)
      (append (quote-marks source start end)
              (append-map-blocks (cut block-ranges source <>) (markdown-quote-blocks block))))
     ((markdown-list? block)
      (append-map-blocks
       (lambda ((item : markdown-item))
         (append (item-marks source (markdown-block-start item) (markdown-block-end item) (markdown-item-task? item))
                 (append-map-blocks (cut block-ranges source <>) (markdown-item-blocks item))))
       (markdown-list-items block)))
     ((markdown-table? block)
      (let (lines (line-starts source start end))
        (append
         ;; The pipes, and the row of dashes under the header.
         (let lp ((i start) (out []))
           (cond
            ((fx>= i end) (reverse out))
            ((char=? (string-ref source i) #\|) (lp (fx1+ i) (cons (make-styled i (fx1+ i) 'marker) out)))
            (else (lp (fx1+ i) out))))
         (if (pair? (cdr lines))
           [(make-styled (cadr lines) (line-end source (cadr lines)) 'marker)]
           [])
         (append-map-blocks inline-ranges (apply append (markdown-table-header block) (markdown-table-rows block))))))
     ((markdown-rule? block) [(make-styled start end 'marker)])
     (else []))))

;;; Inlines

;; Where the inlines INLINES came from: the first start and last end that
;; are known, as a pair, or #f.
(def (inlines-extent (inlines : :list)) => (Maybe :pair)
  (let ((starts (filter-map markdown-inline-start inlines))
        (ends (filter-map markdown-inline-end inlines)))
    (and (pair? starts) (pair? ends)
         (cons (apply fxmin starts) (apply fxmax ends)))))

;; A span from START to END styled as PART, its content INLINES, whose
;; delimiters (what lies outside the content) are marks.
(def (delimited (start :? :fixnum) (end :? :fixnum) (part :? :symbol) (inlines : :list)) => :list
  (if (not (and start end))
    (inline-ranges inlines)
    (let (extent (inlines-extent inlines))
      (append (if part [(make-styled start end part)] [])
              (if extent
                (append (if (fx< start (car extent)) [(make-styled start (car extent) 'marker)] [])
                        (if (fx< (cdr extent) end) [(make-styled (cdr extent) end 'marker)] []))
                [(make-styled start end 'marker)])
              (inline-ranges inlines)))))

(def (inline-ranges (inlines : :list)) => :list
  (append-map-blocks
   (lambda (inline)
     (cond
      ((markdown-span? inline)
       (delimited (markdown-inline-start inline) (markdown-inline-end inline)
                  (markdown-span-kind inline) (markdown-span-inlines inline)))
      ;; A link's label looks like a link; its brackets and address are
      ;; marks. An autolink is all link.
      ((markdown-link? inline)
       (let ((start (markdown-inline-start inline))
             (end (markdown-inline-end inline))
             (extent (inlines-extent (markdown-link-inlines inline))))
         (append (if (and extent start end)
                   [(make-styled (car extent) (cdr extent) 'link)]
                   [])
                 (delimited start end #f (markdown-link-inlines inline)))))
      ((markdown-image? inline)
       (delimited (markdown-inline-start inline) (markdown-inline-end inline) 'link (markdown-image-inlines inline)))
      (else [])))
   inlines))

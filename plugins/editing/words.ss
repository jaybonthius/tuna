#lang :tuna/prelude
;;; Words, for the editing plugin's word commands and double clicks.
;;;
;;; A word is a run of word constituents (Emacs's word syntax class).
;;; Tuna has no syntax tables yet, so `word-constituent?` is the one
;;; place that decides: Unicode letters and digits, plus `$` and `%`,
;;; which Emacs's standard syntax table also makes word constituents
;;; (src/syntax.c). Every other character separates words; unlike that
;;; table, which makes every non-ASCII character a word constituent until
;;; characters.el changes some, non-ASCII punctuation and symbols (an em
;;; dash, curly quotes, emoji) separate words here. Emacs also splits a
;;; run where the script changes (`word_boundary_p`); Tuna does not.
;;; Modes will replace the predicate when they come.
;;;
;;; Moving by words follows Emacs's `scan_words` (src/syntax.c:1459 at
;;; Emacs 541f693ca2e8): forward, skip separators, then the word; backward,
;;; skip separators, then the word, stopping at its start.
(import :tuna/plugins/buffers/contract)
(export word-constituent?
        forward-word-position
        transpose-words!
        casify-word!
        capitalize-string)

;; Whether C is part of a word (Emacs: its syntax class is word).
(def (word-constituent? (c : :char)) => :boolean
  (or (char-alphabetic? c) (char-numeric? c) (char=? c #\$) (char=? c #\%)))

;; Scans read the text this many characters at a time.
(def word-scan-chunk 256)

;; The end of the first word that ends after FROM in S, or #f when no
;; word starts before the end.
(def (word-end-after (s : snapshot) (from : :fixnum)) => (Maybe :fixnum)
  (let (end (fx1+ (snapshot-size s)))
    (let loop ((pos from) (in-word? #f) (chunk "") (chunk-start from))
      (cond
       ((fx= pos end) (and in-word? pos))
       ((fx= (fx- pos chunk-start) (string-length chunk))
        (loop pos in-word? (snapshot-slice s pos (fxmin end (fx+ pos word-scan-chunk))) pos))
       ((word-constituent? (string-ref chunk (fx- pos chunk-start)))
        (loop (fx1+ pos) #t chunk chunk-start))
       (in-word? pos)
       (else (loop (fx1+ pos) #f chunk chunk-start))))))

;; The start of the first word that starts before FROM in S, or #f when
;; no word ends after the beginning.
(def (word-start-before (s : snapshot) (from : :fixnum)) => (Maybe :fixnum)
  (let loop ((pos from) (in-word? #f) (chunk "") (chunk-start from))
    (cond
     ((fx= pos 1) (and in-word? pos))
     ((fx= pos chunk-start)
      (let (start (fxmax 1 (fx- pos word-scan-chunk)))
        (loop pos in-word? (snapshot-slice s start pos) start)))
     ((word-constituent? (string-ref chunk (fx- (fx1- pos) chunk-start)))
      (loop (fx1- pos) #t chunk chunk-start))
     (in-word? pos)
     (else (loop (fx1- pos) #f chunk chunk-start)))))

;; Where moving COUNT words from FROM in T ends (backward for negative
;; COUNT): the end of the last word forward, the start of the last word
;; backward, or the end of the text when there are not that many words
;; (Emacs `forward-word`, src/syntax.c:1576).
(def (forward-word-position (t : text) (from : :fixnum) (count : :fixnum)) => :fixnum
  (let ((s (text-snapshot t)))
    (let loop ((pos from) (count count))
      (cond
       ((fx= count 0) pos)
       ((fx> count 0)
        (let (next (word-end-after s pos))
          (if next (loop next (fx1- count)) (fx1+ (snapshot-size s)))))
       (else
        (let (next (word-start-before s pos))
          (if next (loop next (fx1+ count)) 1)))))))

;; Swap the word before or around point with the word after it, leaving
;; point after both (Emacs `transpose-words` through `transpose-subr` and
;; `transpose-subr-1`, lisp/simple.el:8752, 8839, 8875).
(def (transpose-words!) => :void
  (let* ((t (current-text))
         (start1 (forward-word-position t (point) -1))
         (end1 (forward-word-position t start1 1))
         (end2 (forward-word-position t end1 1))
         (start2 (forward-word-position t end2 -1))
         (first (cons (fxmin start1 end1) (fxmax start1 end1)))
         (second (cons (fxmin start2 end2) (fxmax start2 end2)))
         (a (if (fx> (car first) (car second)) second first))
         (b (if (fx> (car first) (car second)) first second)))
    (when (fx> (cdr a) (car b))
      (error "Don't have two things to transpose"))
    (let (swapped (string-append (text-substring t (car b) (cdr b))
                                 (text-substring t (cdr a) (car b))
                                 (text-substring t (car a) (cdr a))))
      (delete-region (car a) (cdr b))
      (goto-char (car a))
      (insert swapped)
      (goto-char end2))))

;; Replace the text from point to the end of the next word with CONVERT
;; applied to it, and move point after it (Emacs `casify_word`,
;; src/casefiddle.c:661): `upcase-word`, `downcase-word` and
;; `capitalize-word`.
(def (casify-word! (convert : :procedure)) => :void
  (let* ((t (current-text))
         (start (point))
         (end (forward-word-position t start 1))
         (old (text-substring t start end))
         (new (:- (convert old) :string)))
    (if (string=? new old)
      (goto-char end)
      (begin
        (delete-region start end)
        (goto-char start)
        (insert new)))))

;; S with the first character of each word in upper case and the rest of
;; it in lower case; S's first character starts a word even inside one,
;; as Emacs's `capitalize-word` treats the word part after point.
(def (capitalize-string (s : :string)) => :string
  (let ((out (string-copy s))
        (size (string-length s)))
    (let loop ((i 0) (in-word? #f))
      (if (fx= i size)
        out
        (let* ((c (string-ref s i))
               (word? (word-constituent? c)))
          (when word?
            (string-set! out i (if in-word? (char-downcase c) (char-upcase c))))
          (loop (fx1+ i) word?))))))

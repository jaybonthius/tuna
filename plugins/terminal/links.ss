;;; Links in a terminal's output, as ghostel finds and opens them
;;; (lisp/ghostel-links.el): OSC 8 hyperlinks come with the runs; plain
;;; http(s) URLs and FILE:LINE[:COLUMN] references to files that exist are
;;; found in each line of the program's, rows it wrapped joined first,
;;; and become links too. A link's target is a URI: http(s), file://, or
;;; fileref:PATH[:LINE[:COLUMN]] for a reference found in the text.
prelude: :gerbil/core

(import (only-in ./screen char-cells))
(export find-links
        link-runs
        web-link?
        link-file-target
        percent-decode)

;;; Finding links in text

(def (url-char? (c : :char)) => :boolean
  (not (or (char-whitespace? c) (memv c '(#\" #\< #\> #\( #\))))))

(def (url-end-char? (c : :char)) => :boolean
  (not (memv c '(#\. #\, #\; #\: #\! #\?))))

;; The end of the URL starting at START in TEXT (ghostel--url-regex): its
;; characters, with balanced parenthesised groups, not ending in sentence
;; punctuation.
(def (url-end (text : :string) (start : :fixnum)) => :fixnum
  (let ((size (string-length text)))
    (let lp ((i start) (last-good start))
      (cond
       ((fx= i size) last-good)
       ((char=? (string-ref text i) #\()
        (let close ((j (fx1+ i)))
          (cond
           ((fx= j size) last-good)
           ((char=? (string-ref text j) #\)) (lp (fx1+ j) (fx1+ j)))
           ((url-char? (string-ref text j)) (close (fx1+ j)))
           (else last-good))))
       ((url-char? (string-ref text i))
        (lp (fx1+ i) (if (url-end-char? (string-ref text i)) (fx1+ i) last-good)))
       (else last-good)))))

;; The index of NEEDLE in TEXT from FROM, or #f.
(def (search (text : :string) (needle : :string) (from : :fixnum)) => (Maybe :fixnum)
  (let ((size (string-length text))
        (n (string-length needle)))
    (let lp ((i from))
      (cond
       ((fx> (fx+ i n) size) #f)
       ((string=? (substring text i (fx+ i n)) needle) i)
       (else (lp (fx1+ i)))))))

;; The http(s) URLs in TEXT: (START END URI), END exclusive.
(def (find-urls (text : :string)) => :list
  (let ((size (string-length text)))
    (let lp ((from 0) (out []))
      (let* ((http (search text "http" from)))
        (if (not http)
          (reverse out)
          (let ((scheme-end (cond
                             ((string-prefix? "https://" (substring text http (fxmin size (fx+ http 8)))) (fx+ http 8))
                             ((string-prefix? "http://" (substring text http (fxmin size (fx+ http 7)))) (fx+ http 7))
                             (else #f))))
            (if (not scheme-end)
              (lp (fx1+ http) out)
              (let (end (url-end text scheme-end))
                (if (fx> end scheme-end)
                  (lp end (cons [http end (substring text http end)] out))
                  (lp scheme-end out))))))))))

;; ghostel-file-detection-path-regex, by hand: a path is word characters,
;; ~, ., _ and -, then a slash, then any characters but these, not ending
;; in sentence punctuation.
(def (path-head-char? (c : :char)) => :boolean
  (or (char-alphabetic? c) (char-numeric? c) (memv c '(#\~ #\_ #\. #\-))))
(def (path-char? (c : :char)) => :boolean
  (not (or (char-whitespace? c) (memv c '(#\] #\: #\" #\< #\> #\( #\) #\{ #\} #\[ #\` #\')))))
(def (path-before-ok? (c : :char)) => :boolean
  (not (or (char-alphabetic? c) (char-numeric? c) (memv c '(#\_ #\. #\/ #\~ #\-)))))

;; The FILE:LINE[:COLUMN] references in TEXT whose file EXISTS? (a
;; procedure of the path as written): (START END PATH LINE COLUMN), LINE
;; and COLUMN strings or #f.
(def (find-file-references (text : :string) (exists? : :procedure)) => :list
  (let ((size (string-length text)))
    (def (digits-end (i : :fixnum)) => :fixnum
      (if (and (fx< i size) (char-numeric? (string-ref text i))) (digits-end (fx1+ i)) i))
    (let lp ((i 0) (out []))
      (cond
       ((fx>= i size) (reverse out))
       ((and (or (fx= i 0) (path-before-ok? (string-ref text (fx1- i)))) (path-head-char? (string-ref text i)))
        ;; The head, then a slash, then the rest.
        (let* ((slash (let head ((j i))
                        (cond
                         ((fx= j size) #f)
                         ((char=? (string-ref text j) #\/) j)
                         ((path-head-char? (string-ref text j)) (head (fx1+ j)))
                         (else #f))))
               (raw-end (and slash (let rest ((j (fx1+ slash)))
                                     (if (and (fx< j size) (path-char? (string-ref text j))) (rest (fx1+ j)) j))))
               (end (and raw-end (let back ((j raw-end))
                                   (if (and (fx> j (fx1+ slash)) (not (url-end-char? (string-ref text (fx1- j)))))
                                     (back (fx1- j))
                                     j)))))
          (if (and end (fx> end slash) (not (char=? (string-ref text (fx1- end)) #\/)))
            (let* ((path (substring text i end))
                   (line-end (and (fx< end size) (char=? (string-ref text end) #\:) (digits-end (fx1+ end))))
                   (line (and line-end (fx> line-end (fx1+ end)) (substring text (fx1+ end) line-end)))
                   (column-end (and line (fx< line-end size) (char=? (string-ref text line-end) #\:)
                                    (digits-end (fx1+ line-end))))
                   (column (and column-end (fx> column-end (fx1+ line-end)) (substring text (fx1+ line-end) column-end)))
                   (stop (cond (column column-end) (line line-end) (else end))))
              (if (exists? path)
                (lp stop (cons [i stop path line column] out))
                (lp (fxmax (fx1+ i) end) out)))
            (lp (fx1+ i) out))))
       (else (lp (fx1+ i) out))))))

;; The links in TEXT, one line of the program's: (START END URI), URLs
;; when URLS?, file references when FILES? with RESOLVE (a procedure of
;; the path as written, giving the absolute path of a file that exists,
;; or #f). They do not overlap; URLs win.
(def (find-links (text : :string) (urls? : :boolean) (files? : :boolean) (resolve : :procedure)) => :list
  (let* ((found-urls (if urls? (find-urls text) []))
         (overlaps? (lambda (start end)
                      (ormap (lambda ((u : :list)) (and (fx< start (cadr u)) (fx> end (car u)))) found-urls)))
         (files (if files?
                  (filter-map (lambda ((r : :list))
                                (match r
                                  ([start end path line column]
                                   (and (not (overlaps? start end))
                                        (let (absolute (resolve path))
                                          (and absolute
                                               [start end (string-append "fileref:" absolute
                                                                         (if line (string-append ":" line) "")
                                                                         (if column (string-append ":" column) ""))]))))))
                              (find-file-references text (lambda (path) (and (resolve path) #t))))
                  [])))
    (list-sort (lambda ((a : :list) (b : :list)) (fx< (car a) (car b))) (append found-urls files))))

;;; Links into runs

;; RUNS (a row's, as screen.ss makes them) with LINKS, (START END URI)
;; in the row's text (row-text), attached: a run a link covers part of is
;; split there. A run with an OSC 8 link keeps it.
(def (link-runs (runs : :vector) (links : :list)) => :vector
  (if (null? links)
    runs
    (let lp ((i 0) (column 0) (index 0) (out []))
      (if (fx= i (vector-length runs))
        (list->vector (reverse out))
        (let* ((run (vector-ref runs i))
               (start (vector-ref run 0))
               (text (vector-ref run 2))
               (from (fx+ index (fxmax 0 (fx- start column))))
               (to (fx+ from (string-length text))))
          (lp (fx1+ i) (fx+ start (vector-ref run 1)) to
              (append (reverse (if (and (fx> (vector-length run) 5) (vector-ref run 5))
                                 [run]
                                 (split-run run from links)))
                      out)))))))

;; RUN, whose text starts at index FROM of the row, cut where LINKS start
;; and end inside it, the pieces a link covers carrying its URI.
(def (split-run (run : :vector) (from : :fixnum) (links : :list)) => :list
  (let* ((text (vector-ref run 2))
         (to (fx+ from (string-length text)))
         (cuts (list-sort fx< (filter (lambda ((x : :fixnum)) (and (fx< from x) (fx< x to)))
                                      (apply append (map (lambda ((l : :list)) [(car l) (cadr l)]) links)))))
         (bounds (append [from] (dedupe cuts) [to])))
    (let lp ((bounds bounds) (cell (vector-ref run 0)) (out []))
      (match bounds
        ([a b . more]
         (let* ((piece (substring text (fx- a from) (fx- b from)))
                (width (string-cells piece))
                (link (find (lambda ((l : :list)) (and (fx<= (car l) a) (fx>= (cadr l) b))) links)))
           (lp (cons b more) (fx+ cell width)
               (cons (vector cell width piece (vector-ref run 3) (vector-ref run 4) (and link (caddr link))) out))))
        (else (reverse out))))))

(def (dedupe (xs : :list)) => :list
  (match xs
    ([a b . more] (if (fx= a b) (dedupe (cons b more)) (cons a (dedupe (cons b more)))))
    (else xs)))

;; The cells TEXT takes: its characters', a wide one two.
(def (string-cells (text : :string)) => :fixnum
  (let lp ((i 0) (n 0))
    (if (fx= i (string-length text))
      n
      (lp (fx1+ i) (fx+ n (char-cells (string-ref text i)))))))

;;; Opening links

;; Whether URI is a web address the browser may open.
(def (web-link? (uri : :string)) => :boolean
  (or (string-prefix? "http://" uri) (string-prefix? "https://" uri)))

(def (percent-decode (s : :string)) => :string
  (let (bytes (string->utf8 s))
    (let lp ((i 0) (out []))
      (cond
       ((fx>= i (u8vector-length bytes))
        (let (b (list->u8vector (reverse out)))
          (with-catch (lambda (e) (list->string (map integer->char (u8vector->list b)))) (lambda () (utf8->string b)))))
       ((and (fx= (u8vector-ref bytes i) 37) (fx< (fx+ i 2) (u8vector-length bytes))
             (string->number (utf8->string (subu8vector bytes (fx1+ i) (fx+ i 3))) 16))
        => (lambda (n) (lp (fx+ i 3) (cons n out))))
       (else (lp (fx1+ i) (cons (u8vector-ref bytes i) out)))))))

;; The file URI names, as ghostel opens it (ghostel--open-link): (PATH
;; LINE COLUMN), LINE and COLUMN numbers or #f, for fileref:PATH[:L[:C]],
;; for file://HOST/PATH on this machine (HOST "", "localhost" or LOCAL-HOST),
;; or for a bare PATH[:L[:C]], relative to DIRECTORY; #f for anything else.
(def (link-file-target (uri : :string) (directory : :string) (local-host : :string)) => (Maybe :list)
  (def (with-position (spec : :string)) => :list
    ;; PATH[:LINE[:COLUMN]], the numbers at the end.
    (let* ((parts (string-split spec #\:))
           (n (length parts))
           (number? (lambda (s) (and (fx> (string-length s) 0) (andmap char-numeric? (string->list s))))))
      (cond
       ((and (fx>= n 3) (number? (list-ref parts (fx- n 1))) (number? (list-ref parts (fx- n 2))))
        [(string-join (take parts (fx- n 2)) ":") (string->number (list-ref parts (fx- n 2)))
         (string->number (list-ref parts (fx- n 1)))])
       ((and (fx>= n 2) (number? (list-ref parts (fx- n 1))))
        [(string-join (take parts (fx- n 1)) ":") (string->number (list-ref parts (fx- n 1))) #f])
       (else [spec #f #f]))))
  (def (absolute (path : :string)) => :string
    (if (string-prefix? "/" path) path (path-expand path directory)))
  (cond
   ((string-prefix? "fileref:" uri)
    (match (with-position (substring uri 8 (string-length uri)))
      ([path line column] [(absolute path) line column])))
   ((string-prefix? "file://" uri)
    (let* ((rest (substring uri 7 (string-length uri)))
           (slash (string-index rest #\/)))
      (and slash
           (member (string-downcase (substring rest 0 slash)) ["" "localhost" (string-downcase local-host)])
           [(percent-decode (substring rest slash (string-length rest))) #f #f])))
   ;; A scheme other than a drive letter or NAME:LINE is not a file.
   ((let (colon (string-index uri #\:))
      (and colon (fx> colon 0)
           (char-alphabetic? (string-ref uri 0))
           (not (string-index (substring uri 0 colon) #\/))
           (not (and (fx< (fx1+ colon) (string-length uri)) (char-numeric? (string-ref uri (fx1+ colon)))))))
    #f)
   (else
    (match (with-position uri)
      ([path line column] [(absolute path) line column])))))

(import (test) (document))

(define (raised? who message irritants)
  (lambda (c)
    (and (who-condition? c) (eq? who (condition-who c))
         (message-condition? c) (string=? message (condition-message c))
         (equal? irritants (if (irritants-condition? c) (condition-irritants c) '())))))

(define (utf8 doc start end)
  (let-values ([(port extract) (open-bytevector-output-port)])
    (document:for-each-utf8-chunk doc start end
      (lambda (bv from to) (put-bytevector port bv from (- to from))))
    (extract)))

(define (children node start end)
  (let ([out '()])
    (document:for-each-child node start end (lambda (child at) (set! out (cons (list at child) out))))
    (reverse out)))

(define (node-start-or-token t) (if (document:node? t) (list 'node (document:node-start t)) t))

(define (atoms-in doc)
  (filter (lambda (t) (and (document:node? t) (document:atom? t)))
          (map (lambda (p) (document:token doc p)) (iota (document:length doc)))))

(define (position-after doc text)
  (let ([all (document:text doc)] [n (string-length text)])
    (let loop ([i 0])
      (if (string=? (substring all i (+ i n)) text)
          (- (document:position doc (+ i n 1) (document:unit characters)) 1)
          (loop (+ i 1))))))

(define reply
  (document:from-datum
    '(chat:reply ()
       (md:para () "See " (md:link ((href . "https://scheme.com")) "TSPL") ".\n")
       #(md:image ((src . "plot.png"))))))

(test "a document is made of datums: strings, nodes and atoms, in order"
  (check-equal? 17 (document:length reply))
  (check-equal? '((chat:reply ()
                    (md:para () "See " (md:link ((href . "https://scheme.com")) "TSPL") ".\n")
                    #(md:image ((src . "plot.png")))))
                (document:datums reply))
  (check-equal? 0 (document:length (document:from-datum)))
  (check-equal? '((li () "x") #(hr ((rule . 1))) "ab")
                (document:datums (document:from-datum '(li () "x") '#(hr ((rule . 1))) "a" "b"))))

(test "strings and attribute values are copied in, and attribute values out"
  (let* ([name (string #\a #\b)] [tags (list "x" (vector 1))]
         [d (document:from-datum (list 'p (list (cons 'tags tags)) name))])
    (string-set! name 0 #\z)
    (set-car! tags "changed")
    (set-car! (document:node-attribute (document:token d 0) 'tags) "changed")
    (check-equal? '((p ((tags "x" #(1))) "ab")) (document:datums d))))

(test "a malformed datum, or an attribute value that is not plain data, raises, naming the value unless it holds itself"
  (check-raises (raised? 'document:from-datum "not a datum" '(42)) (document:from-datum 42))
  (check-raises (raised? 'document:from-datum "not a datum" '(#(img))) (document:from-datum '#(img)))
  (check-raises (raised? 'document:from-datum "not a datum" '((p () . "x"))) (document:from-datum '(p () . "x")))
  (check-raises (raised? 'document:from-datum "not an association list from symbols" '("no attributes"))
    (document:from-datum '(p "no attributes")))
  (check-raises (raised? 'document:from-datum "not plain data" (list car))
    (document:from-datum (list 'p (list (cons 'f car)))))
  (let ([holds-itself (list 'p '())])
    (set-cdr! (cdr holds-itself) (list holds-itself))
    (check-raises (raised? 'document:from-datum "a datum holds itself" '()) (document:from-datum holds-itself)))
  (let ([value (list 1)])
    (set-cdr! value value)
    (check-raises (raised? 'document:from-datum "not plain data: a value holds itself" '())
      (document:from-datum (list 'p (list (cons 'v value)))))
    (check-raises (raised? 'document:from-datum "not a datum" '()) (document:from-datum (cons* 'p '() value)))
    (check-raises (raised? 'document:from-datum "not an association list from symbols" '())
      (document:from-datum (list 'p value))))
  (let ([cell (box #f)])
    (set-box! cell cell)
    (check-raises (raised? 'document:from-datum "not plain data" '())
      (document:from-datum (list 'p (list (cons 'v cell)))))))

(test "a raw byte atom needs a byte from 0 to 255"
  (check-raises (raised? 'document:from-datum "a raw byte needs a byte from 0 to 255" '(((byte . 300))))
    (document:from-datum '#(document:raw-byte ((byte . 300)))))
  (check-equal? '(#(document:raw-byte ((byte . 0)))) (document:datums (document:from-datum '#(document:raw-byte ((byte . 0)))))))

(test "each byte that is not part of valid UTF-8 is a raw byte, written back as itself"
  (check-equal? '("caf" #(document:raw-byte ((byte . 233)))) (document:datums (document:from-utf8 #vu8(99 97 102 233))))
  (let* ([bytes #vu8(104 #xC0 #xAF 105 #xE2 #x82 #xAC #xED #xA0 #x80 #xF0 #x9F #x99)]
         [raw (document:from-utf8 bytes)])
    (check-equal? '("h" #(document:raw-byte ((byte . 192))) #(document:raw-byte ((byte . 175))) "i€"
                    #(document:raw-byte ((byte . 237))) #(document:raw-byte ((byte . 160))) #(document:raw-byte ((byte . 128)))
                    #(document:raw-byte ((byte . 240))) #(document:raw-byte ((byte . 159))) #(document:raw-byte ((byte . 153))))
                  (document:datums raw))
    (check-equal? bytes (utf8 raw 0 (document:length raw)))
    (check-equal? 11 (document:length raw))
    (check-equal? 13 (document:offset raw 11 (document:unit bytes)))
    (check-equal? "h\xFFFC;\xFFFC;i" (document:text raw 0 4))))

(test "UTF-8 chunks give an atom U+FFFC and a raw byte its byte, nothing for openings and closings, and a range cuts runs"
  (let ([small (document:from-datum '(p () "aé" #(document:raw-byte ((byte . 255))) #(img ())))])
    (check-equal? #vu8(97 195 169 255 239 191 188) (utf8 small 0 (document:length small)))
    (check-equal? #vu8(195 169 255) (utf8 small 2 4))))

(test "document? holds for documents only, which are plain vectors"
  (check-equal? '(#t #f #f) (list (document? reply) (document? (vector 1)) (document? "x")))
  (check (vector? reply)))

(test "a token is a character, a node for an opening or an atom, close, or the end-of-file object at the end"
  (check-equal? #\S (document:token reply 2))
  (check-equal? '(chat:reply 0) (let ([n (document:token reply 0)]) (list (document:node-kind n) (document:node-start n))))
  (check-equal? '(md:image 15) (let ([n (document:token reply 15)]) (list (document:node-kind n) (document:node-start n))))
  (check-equal? 'close (document:token reply 16))
  (check (eof-object? (document:token reply 17)))
  (check-raises (raised? 'document:token "not a position in the document" '(18)) (document:token reply 18)))

(test "text gives the characters of a range, an atom U+FFFC unless its text is given"
  (check-equal? "See TSPL.\n\xFFFC;" (document:text reply))
  (check-equal? "ee TS" (document:text reply 3 9))
  (check-equal? "TSPL.\n\xFFFC;" (document:text reply 7))
  (check-equal? "TSPL.\n[plot]" (document:text reply 7 17 '((15 . "[plot]"))))
  (let ([raw (document:from-utf8 #vu8(104 #xC0 #xAF 105))])
    (check-equal? "h?!i" (document:text raw 0 4 '((1 . "") (2 . "?!"))))
    (check-equal? "h\xFFFC;?i" (document:text raw 0 4 '((2 . "?"))))
    (check-raises (raised? 'document:text "not the position of an atom in the range, after the one before" '(1))
      (document:text raw 0 4 '((2 . "a") (1 . "b"))))
    (check-raises (raised? 'document:text "not the position of an atom in the range, after the one before" '(2))
      (document:text raw 0 2 '((2 . "a"))))
    (check-raises (raised? 'document:text "not a position and a text" '((1 . #\a)))
      (document:text raw 0 4 '((1 . #\a)))))
  (check-raises (raised? 'document:text "not the position of an atom in the range, after the one before" '(14))
    (document:text reply 0 17 '((14 . "x"))))
  (check-raises (raised? 'document:text "start is after end" '(5 3)) (document:text reply 5 3)))

(test "offsets and positions count characters, UTF-8 bytes or UTF-16 code units"
  (let ([units (document:from-datum "a🙂é")])
    (check-equal? '(3 7 4)
      (map (lambda (unit) (document:offset units 3 unit))
           (list (document:unit characters) (document:unit bytes) (document:unit utf-16))))
    (check-equal? 2 (document:position units 5 (document:unit bytes)))
    (check-equal? 2 (document:position units 3 (document:unit utf-16)))
    (check-raises (raised? 'document:position "offset inside a character" '(2)) (document:position units 2 (document:unit bytes)))
    (check-raises (raised? 'document:position "offset inside a character" '(2)) (document:position units 2 (document:unit utf-16)))
    (check-raises (raised? 'document:position "offset past the end" '(8)) (document:position units 8 (document:unit bytes)))
    (check-raises (raised? 'document:offset "not a unit" '(lines)) (document:offset units 0 'lines)))
  (check-equal? 4 (document:offset reply 7 (document:unit characters))))

(test "a position is the first before which the offset comes: before an opening, not after it"
  (check-equal? 0 (document:position reply 0 (document:unit characters)))
  (check-equal? 6 (document:position reply 4 (document:unit characters))))

(test "atoms, raw bytes among them, are a unit of their own; text counts none"
  (let ([atoms (document:from-datum '(p () "│é" #(img ()) "⠿" #(document:raw-byte ((byte . 255))) "x"))])
    (check-equal? '(0 0 1 1 2 2 2) (map (lambda (p) (document:offset atoms p (document:unit atoms))) '(0 3 4 5 6 7 8)))
    (check-equal? '(4 6) (map (lambda (k) (document:position atoms k (document:unit atoms))) '(1 2)))
    (check-raises (raised? 'document:position "offset past the end" '(3)) (document:position atoms 3 (document:unit atoms))))
  (check-equal? 1 (document:offset reply 17 (document:unit atoms)))
  (check-equal? 0 (document:offset reply 17 (document:unit in-line-atoms))))

(define lines-datum
  '(p ()
     (q () "a" #(document:raw-byte ((byte . 255))) #(document:raw-byte ((byte . 254))) #(document:raw-byte ((byte . 253))) "b")
     (q () "x\n" #(img ()) #(img ()) "\ny")
     (q () "x" #(img ()))
     (q () "x\n" #(img ()))
     (q () (r () "x") #(img ()) #(img ()) (r () "y"))))

(test "an atom is in a line when, past the atoms next to it, a character follows, or one other than a newline comes before"
  (check-equal? '(#t #t #t #t #t #t #f #f #f) (map document:in-line? (atoms-in (document:from-datum lines-datum))))
  (check-equal? '(#f #f) (map document:in-line? (atoms-in (document:from-datum '(p () #(img ()) (q ()) "\n" #(img ()))))))
  (check-equal? '(#t #f) (list (document:in-line? (document:token reply 6)) (document:in-line? (document:token reply 15)))))

(define (in-line-counts doc)
  (let loop ([p 0] [k 0] [acc '()])
    (let ([acc (cons k acc)])
      (if (= p (document:length doc))
          (list->vector (reverse acc))
          (let ([t (document:token doc p)])
            (loop (+ p 1) (if (and (document:node? t) (document:atom? t) (document:in-line? t)) (+ k 1) k) acc))))))

(define (agreeing-in-line-total doc)
  (let* ([in-line (document:unit in-line-atoms)] [w (in-line-counts doc)] [n (document:length doc)] [total (vector-ref w n)])
    (and (for-all (lambda (p) (= (vector-ref w p) (document:offset doc p in-line))) (iota (+ n 1)))
         (for-all (lambda (k)
                    (let ([p (document:position doc k in-line)])
                      (and (= (vector-ref w p) k) (or (= p 0) (< (vector-ref w (- p 1)) k)))))
                  (iota (+ total 1)))
         total)))

(test "the in-line atoms unit counts the atoms in-line? holds for, in a tree of many levels, and follows edits"
  (let* ([many (apply document:from-datum (make-list 300 lines-datum))] [copy-150 (* 150 36)])
    (check-equal? 10800 (document:length many))
    (check-equal? 1800 (agreeing-in-line-total many))
    (check-raises (raised? 'document:position "offset past the end" '(1801))
      (document:position many 1801 (document:unit in-line-atoms)))
    (let ([typed (document:replace many (+ copy-150 18) (+ copy-150 18) (document:from-datum "\n"))])
      (check-equal? #f (document:in-line? (document:token typed (+ copy-150 19))))
      (check-equal? 1799 (agreeing-in-line-total typed)))
    (let ([deleted (document:replace many (+ copy-150 22) (+ copy-150 23) (document:from-datum))])
      (check-equal? #t (document:in-line? (document:token deleted (+ copy-150 22))))
      (check-equal? 1801 (agreeing-in-line-total deleted)))))

(test "a line is one more than the newlines before; a line's start follows the newline before it"
  (let ([lines (document:from-datum "one\ntwo\n\nfour")])
    (check-equal? '(1 1 2 3 4 4) (map (lambda (p) (document:line lines p)) '(0 3 4 8 9 13)))
    (check-equal? '(0 4 8 9) (map (lambda (line) (document:line-start lines line)) '(1 2 3 4)))
    (check-raises (raised? 'document:line-start "the document has fewer lines" '(5)) (document:line-start lines 5))))

(test "a column counts characters from the line's start, a tab to the next multiple of 8"
  (let ([lines (document:from-datum "one\ntwo\n\nfour")])
    (check-equal? '(0 3 0 2 0 0 4) (map (lambda (p) (document:column lines p)) '(0 3 4 6 8 9 13)))
    (check-raises (raised? 'document:column "not a position in the document" '(14)) (document:column lines 14)))
  (check-equal? 2 (document:column (document:from-datum "(let ([x 1])\n  x)\n") 15))
  (check-equal? 9 (document:column (document:from-datum "\tx") 2))
  (check-equal? '(8 9 16 17 19 24 25)
    (map (lambda (p) (document:column (document:from-datum "\ta\tb  \tc") p)) '(1 2 3 4 6 7 8))))

(test "a column's position is at the column, before the character that spans it, or at the line's end"
  (let ([tabbed (document:from-datum "ab\n\tx\ny")])
    (check-equal? '(3 3 4 5 5) (map (lambda (column) (document:column-position tabbed 2 column)) '(0 3 8 9 20)))
    (check-equal? '(1 2) (map (lambda (column) (document:column-position tabbed 1 column)) '(1 5)))
    (check-equal? 7 (document:column-position tabbed 3 4))
    (check-raises (raised? 'document:column-position "not a column" '(-1)) (document:column-position tabbed 2 -1)))
  (check-equal? '(0 2) (map (lambda (column) (document:column-position (document:from-datum "\tx\nabc") 1 column)) '(4 20))))

(test "text-position maps an offset in a range's text, atoms' texts laid in, back to a position"
  (let* ([doc (document:from-datum '(p () "ab" #(pic ()) "é" #(gap ()) "c\n"))]
         [texts '((3 . "XYZ") (5 . ""))]
         [positions (lambda (unit offsets) (map (lambda (o) (document:text-position doc 0 texts o unit)) offsets))])
    (check-equal? "abXYZéc\n" (document:text doc 0 (document:length doc) texts))
    (check-equal? '(0 2 3 3 3 4 5 7) (positions (document:unit characters) '(0 1 2 3 4 5 6 7)))
    (check-equal? '(3 3 3 4 5 7 8) (positions (document:unit bytes) '(2 3 4 5 7 8 9)))
    (check-equal? 5 (document:text-position doc 4 '((5 . "")) 1 (document:unit characters)))
    (check-raises (raised? 'document:text-position "not a unit of text, characters or bytes" '(utf-16))
      (document:text-position doc 0 texts 0 (document:unit utf-16)))
    (check-raises (raised? 'document:text-position "not the position of an atom in the range, after the one before" '(2))
      (document:text-position doc 0 '((2 . "x")) 0 (document:unit characters)))))

(test "a grapheme cluster may end at the ends, next to a node, and between characters as UAX #29 says"
  (let ([doc (document:from-datum "e\x301;x" '(p () "y") "\r\n")])
    (check-equal? '(#t #f #t #t #t #t #t #f #t)
      (map (lambda (p) (document:grapheme-boundary? doc p)) (iota (+ 1 (document:length doc)))))))

(test "enclosing is the innermost node around a position"
  (check-equal? '(#f (node 0) (node 1) (node 6) (node 0) #f)
    (map (lambda (p) (let ([e (document:enclosing reply p)]) (and e (node-start-or-token e)))) '(0 1 6 8 16 17))))

(test "a node has a kind, a start, an end and attributes; an atom is a node"
  (let ([link (document:token reply 6)])
    (check-equal? '(#t #f #f #t)
      (list (document:node? link) (document:node? reply) (document:atom? link) (document:atom? (document:token reply 15))))
    (check-equal? '(md:link 6 12) (list (document:node-kind link) (document:node-start link) (document:node-end link)))
    (check-equal? '("https://scheme.com" #f none)
      (list (document:node-attribute link 'href) (document:node-attribute link 'title) (document:node-attribute link 'title 'none)))
    (check-raises (raised? 'document:node-attribute "not a symbol" '("href")) (document:node-attribute link "href")))
  (check-equal? '(17 15 16) (map (lambda (p) (document:node-end (document:token reply p))) '(0 1 15)))
  (check-raises (raised? 'document:node-kind "not a node" '(p)) (document:node-kind 'p)))

(test "a node's children overlapping a range are its nodes and its text between them, cut at the range"
  (let ([shown (lambda (node start end) (map (lambda (c) (list (car c) (node-start-or-token (cadr c)))) (children node start end)))])
    (check-equal? '((2 "See ") (6 (node 6)) (12 ".\n")) (shown (document:token reply 1) 0 16))
    (check-equal? '((3 "ee ") (6 (node 6))) (shown (document:token reply 1) 3 8))
    (check-equal? '((6 (node 6)) (12 ".\n")) (shown (document:token reply 1) 8 14))
    (check-equal? '((1 (node 1)) (15 (node 15))) (shown (document:token reply 0) 0 17))
    (check-equal? '() (shown (document:token reply 15) 0 17))))

(test "a slice holds a range's tokens and the nodes it leaves open at each edge; a slice of a slice keeps them"
  (let ([s (document:slice reply 9 16)])
    (check-equal? '(2 0) (list (document:open-start s) (document:open-end s)))
    (check-equal? '((md:para () (md:link ((href . "https://scheme.com")) "PL") ".\n") #(md:image ((src . "plot.png"))))
                  (document:datums s))
    (check-equal? '((md:link ((href . "https://scheme.com")) "L") ".") (document:datums (document:slice s 1 4))))
  (check-equal? '() (document:datums (document:slice reply 0 0)))
  (check-equal? '(0 0) (list (document:open-start reply) (document:open-end reply))))

(test "in a slice only nodes that open inside it enclose, and a node it leaves open ends at its end"
  (let ([cut-at-start (document:slice reply 9 16)] [cut-at-end (document:slice reply 1 8)])
    (check-equal? (make-list 8 #f) (map (lambda (p) (document:enclosing cut-at-start p)) (iota 8)))
    (check-equal? '(#f (node 0) (node 0) (node 0) (node 0) (node 0) (node 5) (node 5))
      (map (lambda (p) (let ([e (document:enclosing cut-at-end p)]) (and e (node-start-or-token e)))) (iota 8)))
    (check-equal? '(7 7) (map (lambda (p) (document:node-end (document:token cut-at-end p))) '(0 5)))))

(test "an edit of a slice keeps as many nodes open at each edge as the slice did"
  (let ([s (document:slice reply 9 16)])
    (check-equal? '((md:para () (md:link ((href . "https://scheme.com")) "QL") ".\n") #(md:image ((src . "plot.png"))))
      (document:datums (document:replace s 0 1 (document:from-datum "Q"))))
    (check-raises (raised? 'document:replace "openings and closings would not match" '(0 0))
      (document:replace s 0 0 (document:slice reply 16 17)))))

(test "a kill across nodes is a slice open at both edges; a whole node killed and put back elsewhere comes back as that node"
  (let* ([md (document:from-datum
               '(md:doc ()
                  (md:heading ((level . 1)) "Title\n")
                  (md:para () "Alpha " (md:link ((href . "https://x")) "beta") " gamma.\n")
                  (md:list () (md:item () "one\n") (md:item () "two\n") (md:item () "three\n"))
                  (md:code ((lang . "scheme")) "(car x)\n")
                  (md:para () "Last " #(md:image ((src . "a.png"))) " line.\n")))]
         [kill (document:slice md (position-after md "Alpha be") (position-after md "gamma.\non"))])
    (check-equal? '((md:para () (md:link ((href . "https://x")) "ta") " gamma.\n") (md:list () (md:item () "on")))
                  (document:datums kill))
    (check-equal? '(2 2) (list (document:open-start kill) (document:open-end kill)))
    (check-equal? "beta gamma.\non" (document:text (document:slice md (position-after md "Alpha ") (position-after md "gamma.\non"))))
    (let* ([one-start (- (position-after md "gamma.\n") 1)]
           [one-end (- (position-after md "one\n") 1)]
           [item (document:slice md one-start one-end)]
           [without (document:replace md one-start one-end (document:from-datum))]
           [back (document:replace without (- (position-after without "two\n") 1) (- (position-after without "two\n") 1) item)]
           [the-list (document:enclosing back (document:node-start (document:enclosing back (position-after back "thr"))))])
      (check-equal? '(((md:item () "one\n")) 0 0) (list (document:datums item) (document:open-start item) (document:open-end item)))
      (check-equal? '((md:list () (md:item () "two\n") (md:item () "one\n") (md:item () "three\n")))
        (document:datums (document:slice back (document:node-start the-list) (document:node-end the-list)))))))

(test "replace is exact, and raises when an opening would lose its closing"
  (check-equal? "Do See TSPL.\n\xFFFC;" (document:text (document:replace reply 2 2 (document:from-datum "Do "))))
  (check-equal? '((chat:reply () (md:para () "See " (em () "x") ".\n") #(md:image ((src . "plot.png")))))
    (document:datums (document:replace reply 6 12 (document:from-datum '(em () "x")))))
  (check-raises (raised? 'document:replace "openings and closings would not match" '(6 7))
    (document:replace reply 6 7 (document:from-datum)))
  (check-raises (raised? 'document:replace "openings and closings would not match" '(2 2))
    (document:replace reply 2 2 (document:slice reply 9 16))))

(test "repeat makes copies one after another, and refuses a document that leaves a node open"
  (check-equal? '("ababab") (document:datums (document:repeat (document:from-datum "ab") 3)))
  (check-equal? '((li () "x") #(hr ((rule . 1))) (li () "x") #(hr ((rule . 1))))
    (document:datums (document:repeat (document:from-datum '(li () "x") '#(hr ((rule . 1)))) 2)))
  (check-equal? 0 (document:length (document:repeat (document:from-datum "ab") 0)))
  (check-raises (raised? 'document:repeat "not a count" '(-1)) (document:repeat (document:from-datum "ab") -1))
  (check-raises (raised? 'document:repeat "the document leaves a node open" '())
    (document:repeat (document:slice (document:from-datum '(p () "ab")) 0 2) 2)))

(test "copies share one tree, so millions of rows take under a megabyte, frozen or not"
  (let ([rows (document:repeat (document:from-datum '#(row ((generation . 1)))) 3880000)])
    (check (< (compute-size rows) 1000000))
    (check (< (compute-size (document:freeze rows vector->immutable-vector)) 1000000))
    (check-equal? 3880000 (document:length rows))
    (check-equal? 'row (document:node-kind (document:token rows 3879999)))
    (check-equal? 3880000 (document:offset rows 3880000 (document:unit atoms)))
    (check-equal? #f (document:same-tokens? rows (document:repeat (document:from-datum '#(row ((generation . 2)))) 3880000)))
    (check-equal? #t (document:same-tokens? rows (document:repeat (document:from-datum '#(row ((generation . 1)))) 3880000)))))

(test "same-tokens? compares tokens, however the documents were built"
  (check (document:same-tokens? (document:from-datum "abc" '(p () "d")) (document:from-datum "ab" "c" '(p () "d"))))
  (check (not (document:same-tokens? (document:from-datum "abc") (document:from-datum "abd"))))
  (check-raises (raised? 'document:same-tokens? "not a document" '(ab)) (document:same-tokens? (document:from-datum "ab") 'ab)))

(test "freezing passes only the parts made since the last freeze, and a frozen document freezes to itself"
  (let* ([calls 0]
         [counting-freeze (lambda (v) (set! calls (+ calls 1)) (vector->immutable-vector v))]
         [big (document:from-datum (make-string 100000 #\a) '(p ((k . "v")) "x" #(img ())))]
         [frozen (document:freeze big counting-freeze)])
    (check (eq? frozen (document:freeze frozen counting-freeze)))
    (check-equal? (document:datums big) (document:datums frozen))
    (set! calls 0)
    (let ([edited (document:freeze (document:replace frozen 5 5 (document:from-datum "b")) counting-freeze)])
      (check-equal? 3 calls)
      (check-equal? "aaaaabaa" (document:text edited 0 8)))))

(test "arguments are checked"
  (check-raises (raised? 'document:length "not a document" '(5)) (document:length 5)))

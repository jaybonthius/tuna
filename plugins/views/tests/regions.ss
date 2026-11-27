(import (tuna) (test) (views) (buffers) (document) (options) (test-user) (views-test page) (views-test md))

(options:set! views:scroll-margin 2 views:wrap-lines #f)

(buffers:define-layer matches (priority 1000))
(buffers:define-layer faces (priority -10))
(buffers:define-layer hints)
(buffers:define-layer marks (priority 10))

(define (drawn v) (views-test/page:element-for-no-client v))

(define (attribute e name) (test-user:element-attribute e name))

(define (pieces v)
  (map (lambda (r) (list (attribute r "class") (test-user:element-text r)))
       (test-user:elements (drawn v) "region")))

(define (held-lines v)
  (map (lambda (l) (string->number (attribute l "data-line"))) (test-user:elements (drawn v) "region-line")))

(define (faced e)
  (map (lambda (f) (list (attribute f "data-face") (test-user:element-text f)))
       (test-user:elements-with e "data-face")))

(define (at doc line column)
  (let ([chars (document:unit characters)])
    (document:position doc (+ (document:offset doc (document:line-start doc line) chars) column) chars)))

(define (region-of text from-line from-column to-line to-column)
  (let* ([b (buffers:make (buffers:free-name "region") text)] [v (views:make b)] [doc (buffers:document b)])
    (views:set-point! v (at doc to-line to-column))
    (views:set-mark! v (at doc from-line from-column))
    (pieces v)))

(define (reports-during thunk)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (thunk)
    (advice-remove! report keep)
    (reverse reported)))

(test "each line's piece of the region is a span of its own, and a line the region goes on past is eol, its newline shown"
  (check-equal? '(("region eol" "56789") ("region eol" "0123") ("region eol" "") ("region eol" "01234567")
                  ("region eol" "0123456789ab") ("region" "01"))
    (region-of "0123456789\n0123\n\n01234567\n0123456789ab\n0123\n" 1 5 6 2)))

(test "a region that ends where a line starts holds nothing of it, and one that starts at a line's end shows only its newline"
  (check-equal? '(("region eol" "ab")) (region-of "ab\ncd\n" 1 0 2 0))
  (check-equal? '(("region eol" "") ("region" "c")) (region-of "ab\ncd\n" 1 2 2 1))
  (check-equal? '(("region" "bcd")) (region-of "abcdef\n" 1 1 1 4)))

(define (linked)
  (buffers:make (buffers:free-name "m")
    (views-test/md:doc '()
      (views-test/md:para '() "Alpha beta gamma.\n")
      (views-test/md:para '() "Al " (views-test/md:link '((href . "https://x")) "beta") " gamma.\n")
      (views-test/md:para '() "Last line.\n"))))

(define (second-line-regions from to)
  (let ([v (views:make (linked))])
    (views:set-mark! v from)
    (views:set-point! v to)
    (let ([line (find (lambda (l) (equal? "2" (attribute l "data-line"))) (test-user:elements (drawn v) "line"))])
      (test-user:elements line "region"))))

(define (piece-list regions)
  (map (lambda (r) (list (attribute r "class") (test-user:element-text r))) regions))

(test "a link's element cuts the region where it starts or ends inside the link; a region covering the link is opened once, around it"
  (let ([covering (second-line-regions 3 40)])
    (check-equal? '(("region eol" "Al beta gamma.")) (piece-list covering))
    (check-equal? 1 (length (test-user:elements (car covering) "md-link"))))
  (check-equal? '(("region" "Al ") ("region" "b")) (piece-list (second-line-regions 3 27)))
  (check-equal? '(("region" "eta") ("region eol" " gamma.")) (piece-list (second-line-regions 27 40)))
  (check-equal? '(("region" "be")) (piece-list (second-line-regions 26 28))))

(test "a line the region holds from its start through its newline is a region-line; regions of two cursors that meet are one"
  (let* ([lines (buffers:make (buffers:free-name "lines") "one\ntwo\nthree\nfour\nfive\n")]
         [lv (views:make lines)]
         [doc (buffers:document lines)])
    (views:set-mark! lv (at doc 1 1))
    (views:set-point! lv (at doc 4 2))
    (check-equal? '(2 3) (held-lines lv))
    (views:set-cursor! (car (views:cursors lv)) (at doc 2 2) (at doc 1 0))
    (views:set-cursor! (views:add-cursor! lv (at doc 3 0)) (at doc 3 0) (at doc 2 2))
    (check-equal? '(1 2) (held-lines lv))))

(test "an atom the region holds whole is marked data-region"
  (let ([pv (views:make (buffers:make (buffers:free-name "pic")
                          (views-test/md:doc '() (views-test/md:para '() "a " (views-test/md:image '((src . "a.png"))) " b\n"))))])
    (views:set-mark! pv 2)
    (views:set-point! pv 7)
    (let ([marked (test-user:elements-with (drawn pv) "data-region")])
      (check-equal? '("4") (map (lambda (n) (attribute n "data-at")) marked))
      (check-equal? '("node") (map (lambda (n) (attribute n "class")) marked)))))

(test "the region holds every layer's spans, and marks those of a layer above priority 0 that it reaches as above-region"
  (let* ([found (buffers:make (buffers:free-name "found") "find the needle here\n")] [fv (views:make found)])
    (buffers:add-span! (buffers:layer found matches) 10 16 '((face . match)))
    (buffers:add-span! (buffers:layer found faces) 1 5 '((face . keyword)))
    (views:set-mark! fv 3)
    (views:set-point! fv 20)
    (let ([e (drawn fv)])
      (check-equal? '(("region" "nd the needle her")) (map (lambda (r) (list (attribute r "class") (test-user:element-text r)))
                                                            (test-user:elements e "region")))
      (check-equal? '(("match" "needle")) (faced (car (test-user:elements e "above-region"))))
      (check-equal? '(("keyword" "fi") ("keyword" "nd") ("match" "needle")) (faced e)))
    (views:set-mark! fv 1)
    (views:set-point! fv 6)
    (let ([e (drawn fv)])
      (check-equal? '("find ") (map test-user:element-text (test-user:elements e "region")))
      (check-equal? '() (test-user:elements e "above-region")))))

(test "the region is cut only where a node's element begins or ends, and each face of a layer above it is marked"
  (let* ([code (buffers:make (buffers:free-name "code") "(define x 1)\n")] [v (views:make code)])
    (buffers:add-span! (buffers:layer code hints) 2 8 '((face . keyword)))
    (buffers:add-span! (buffers:layer code marks) 9 10 '((face . (spell.misspelled variable))))
    (views:set-point! v 5)
    (views:set-mark! v 12)
    (let ([e (drawn v)])
      (check-equal? '("ine x 1") (map test-user:element-text (test-user:elements e "region")))
      (check-equal? '(("variable" "x") ("spell.misspelled" "x"))
        (map (lambda (s) (list (attribute s "data-face") (test-user:element-text s))) (test-user:elements e "above-region")))
      (check-equal? '(("keyword" "def") ("keyword" "ine")) (filter (lambda (f) (equal? "keyword" (car f))) (faced e))))))

(define (rectangle region-ranges view cursor)
  (let ([p (views:cursor-point cursor)] [m (views:cursor-mark cursor)]
        [doc (buffers:document (views:buffer view))] [chars (document:unit characters)])
    (define (offset q) (document:offset doc q chars))
    (define (line-offset line) (offset (document:line-start doc line)))
    (define (column q) (- (offset q) (line-offset (document:line doc q))))
    (if m
        (let* ([from (min (column p) (column m))] [to (max (column p) (column m))]
               [end (- (document:length doc) 1)] [last (document:line doc end)])
          (define (line-end line) (if (< line last) (- (line-offset (+ line 1)) 1) (offset end)))
          (let loop ([line (document:line doc (max p m))] [acc '()])
            (if (< line (document:line doc (min p m)))
                acc
                (let ([start (line-offset line)])
                  (loop (- line 1)
                        (cons (cons (document:position doc (min (+ start from) (line-end line)) chars)
                                    (document:position doc (min (+ start to) (line-end line)) chars))
                              acc))))))
        (region-ranges view cursor))))

(test "region-ranges advised to give each line its piece between point's and mark's columns draws a rectangle"
  (let* ([box (buffers:make (buffers:free-name "box") "0123456789\n01\n0123456789\n")]
         [bv (views:make box)]
         [doc (buffers:document box)]
         [ov (views:make (buffers:make (buffers:free-name "open-box") "abcdef\nghijkl"))])
    (views:set-mark! bv (at doc 1 2))
    (views:set-point! bv (at doc 3 6))
    (views:set-mark! ov 3)
    (views:set-point! ov 14)
    (advice-add! views:region-ranges rectangle)
    (check-equal? '(("region" "2345") ("region" "2345")) (pieces bv))
    (check-equal? '() (held-lines bv))
    (check-equal? '(("region" "cdef") ("region" "ijkl")) (pieces ov))
    (advice-remove! views:region-ranges rectangle)
    (check-equal? '(("region eol" "23456789") ("region eol" "01") ("region" "012345")) (pieces bv))))

(test "ranges outside the buffer are reported, and the cursor draws no region"
  (let* ([bv (views:make (buffers:make (buffers:free-name "box") "0123456789\n01\n"))]
         [outside (lambda (region-ranges view cursor) (list (cons 0 1000)))])
    (views:set-mark! bv 3)
    (views:set-point! bv 8)
    (advice-add! views:region-ranges outside)
    (let* ([drawn-pieces #f] [reported (reports-during (lambda () (set! drawn-pieces (pieces bv))))])
      (advice-remove! views:region-ranges outside)
      (check-equal? '() drawn-pieces)
      (check-equal? 1 (length reported))
      (check-equal? 'views:region-ranges (condition-who (car reported)))
      (check-equal? "not a list of ranges in the buffer" (condition-message (car reported))))))

(test "a line held whole in a view that does not wrap is a region-line however long it is"
  (let ([wv (views:make (buffers:make (buffers:free-name "wide") (string-append (make-string 20000 #\x) "\nnext\n")))])
    (views:set-mark! wv 1)
    (views:set-point! wv 20003)
    (check-equal? '(1) (held-lines wv))))

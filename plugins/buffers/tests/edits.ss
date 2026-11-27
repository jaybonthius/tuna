(import (tuna) (test) (hooks) (options) (buffers) (document) (md) (lists) (buffers-test))

(options:define-option width 70 fixnum?)

(define (edit-datums e)
  (list (buffers:edit-version e) (buffers:edit-start e)
        (document:datums (buffers:piece-document (buffers:edit-removed e)))
        (document:datums (buffers:piece-document (buffers:edit-inserted e)))))

(buffers:define-layer responses (travels) (sticky after))
(buffers:define-layer highlights (priority 10))

(define t (buffers-test:fresh "abc\n"))

(test "after-edit runs with the buffer current and its local entries; content is a string, a datum or a document"
  (let* ([seen '()]
         [note (lambda (b e) (set! seen (cons (append (edit-datums e) (list (eq? b (buffers:current)) (width))) seen)))])
    (buffers:with-buffer t (options:set-local! width 4) (hooks:add-local! buffers:after-edit note))
    (check-equal? 1 (buffers:edit-version (buffers:replace! t 2 3 "XY")))
    (buffers:replace! t 1 1 '(md:link () "L"))
    (buffers:replace! t 1 1 (document:from-datum "doc"))
    (buffers:with-buffer t (hooks:remove-local! buffers:after-edit note))
    (check-equal? '((1 2 ("b") ("XY") #t 4) (2 1 () ((md:link () "L")) #t 4) (3 1 () ("doc") #t 4)) (reverse seen))
    (check-equal? (list 3 "docLaXYc\n" #t)
      (list (buffers:version t) (document:text (buffers:document t)) (eq? (buffers:document t) (buffers:document t))))))

(test "an edit tells its buffer, version and start, and is an edit"
  (let ([e (car (buffers:edits-since t 2))])
    (check-equal? (list t 3 1 #t #f) (list (buffers:edit-buffer e) (buffers:edit-version e) (buffers:edit-start e)
                                           (buffers:edit? e) (buffers:edit? 3)))))

(test "edits-since gives the edits after a version, oldest first, and refuses a version not yet made"
  (check-equal? '(3) (map buffers:edit-version (buffers:edits-since t 2)))
  (check-equal? '() (buffers:edits-since t 3))
  (check-equal? '(1 2 3) (map buffers:edit-version (buffers:edits-since t 0)))
  (check-raises (buffers-test:raised-with? 'buffers:edits-since "not a version of the buffer" '(4)) (buffers:edits-since t 4)))

(test "map-position stays before text inserted at a position; inside removed content it goes to the removal's start"
  (check-equal? '(1 8 10 11) (map (lambda (p) (buffers:map-position t p 0)) '(1 2 3 4)))
  (check-equal? 13 (buffers:map-position t 6 0))
  (check-raises (buffers-test:raised-with? 'buffers:map-position "not a position in the buffer at the version" '(7 0))
    (buffers:map-position t 7 0)))

(test "map-position-after moves a position after text inserted at it, as an anchor made with anchor-after moves"
  (check-equal? '(7 10 10 11) (map (lambda (p) (buffers:map-position-after t p 0)) '(1 2 3 4)))
  (let ([a (buffers:anchor-after t 1)] [v (buffers:version t)])
    (buffers:replace! t 1 1 "zz")
    (check-equal? (buffers:anchor-position a) (buffers:map-position-after t 1 v))
    (buffers:replace! t 1 3 ""))
  (check-raises (buffers-test:raised-with? 'buffers:map-position-after "not a position in the buffer at the version" '(7 0))
    (buffers:map-position-after t 7 0)))

(test "splice! replaces tokens exactly, asking no kind, and refuses tokens that would not match or not leave one node"
  (let ([s (buffers-test:fresh "docLaXYc\n")])
    (check-equal? 1 (buffers:edit-version (buffers:splice! s 1 1 (document:from-datum '(md:para ())))))
    (check-equal? '(buffers:text () (md:para ()) "docLaXYc\n") (buffers-test:root s))
    (check-raises (buffers-test:raised-with? 'buffers:splice! "openings and closings would not match" '(1 2))
      (buffers:splice! s 1 2 (document:from-datum "q")))
    (check-raises (buffers-test:raised-with? 'buffers:splice! "the buffer would not be one node" '(0 0))
      (buffers:splice! s 0 0 (document:from-datum '(md:para ()))))
    (check-raises (buffers-test:raised-with? 'buffers:splice! "not a document or a piece" '("q"))
      (buffers:splice! s 1 1 "q"))))

(test "content that fits nowhere raises, and so does an edit outside the root; a block put between blocks goes in"
  (let ([d (buffers-test:fresh '(md:doc () (md:para () "one\n")))])
    (check-raises (buffers-test:raised? 'buffers:replace! "the content does not fit here") (buffers:replace! d 1 1 "text between blocks"))
    (check-raises (buffers-test:raised? 'buffers:replace! "the content does not fit here") (buffers:replace! d 0 0 "before the root"))
    (buffers:replace! d 1 1 '(md:para () "zero\n"))
    (check-equal? '(md:doc () (md:para () "zero\n") (md:para () "one\n")) (buffers-test:root d))
    (check-equal? #f (buffers:refused? 'refused))
    (check-equal? #f (guard (c [#t (buffers:refused? c)]) (buffers:replace! d 0 (document:length (buffers:document d)) "")))))

(test "insert! returns the position after what went in, which fitting can put past the content's length"
  (let* ([q (buffers-test:fresh '(md:doc () (md:para () "One.\n") (md:para () "Two.\n")))] [two (buffers:piece q 8 15)])
    (check-equal? '(((md:para () "Two.\n")) 7) (list (document:datums (buffers:piece-document two)) (buffers:piece-length two)))
    (check-equal? 13 (buffers:insert! q 3 two))
    (check-equal? '(md:doc () (md:para () "O\n") (md:para () "Two.\n") (md:para () "ne.\n") (md:para () "Two.\n")) (buffers-test:root q))
    (check-raises (buffers-test:raised? 'buffers:insert! "not a position in the buffer") (buffers:insert! q 99 "x"))))

(test "an edit that replaces nothing by nothing is an edit, and moves nothing"
  (let* ([e (buffers-test:fresh "abc\n")] [a (buffers:anchor-after e 2)] [edit (buffers:replace! e 2 2 "")])
    (check-equal? '(1 2 #f) (list (buffers:version e) (buffers:anchor-position a) (buffers:edit-moves? edit)))))

(test "replacing a million rows by a new set moves every position inside them to the start; by the same rows moves none"
  (let* ([rows (lambda (generation n)
                 (document:repeat (document:from-datum (vector 'row (list (cons 'generation generation)))) n))]
         [listing (buffers-test:fresh (document:replace (document:from-datum '(buffers:text ())) 1 1 (rows 1 1000000)))]
         [new-set (buffers:splice! listing 1 1000001 (rows 2 1000000))])
    (check-equal? '(#t 1) (list (buffers:edit-moves? new-set) (buffers:map-position listing 500001 0)))
    (let ([same-set (buffers:splice! listing 1 1000001 (rows 2 1000000))])
      (check-equal? '(#f 500001) (list (buffers:edit-moves? same-set) (buffers:map-position listing 500001 1))))))

(test "deleting a range from one paragraph into another joins them, keeping the anchors and spans of the moved text"
  (let* ([m (buffers-test:fresh '(md:doc () (md:para () "Alpha.\n") (md:para () "Beta gamma.\n")))]
         [beta (buffers:anchor m 16)])
    (buffers:add-span! (buffers:layer m responses) 11 15 'bold)
    (buffers:add-span! (buffers:layer m highlights) 11 15 'warn)
    (buffers:replace! m 8 11 "")
    (check-equal? '(md:doc () (md:para () "Alpha.Beta gamma.\n")) (buffers-test:root m))
    (check-equal? '(13 ((8 12 bold)) ((8 12 warn)))
      (list (buffers:anchor-position beta) (buffers:spans (buffers:layer m responses) 0 20)
            (buffers:spans (buffers:layer m highlights) 0 20)))
    (check-equal? "Beta" (document:text (buffers:document m) 8 12))))

(test "a deeper join moves the text it joins, its travelling spans with it, and keeps a piece's own spans"
  (let ([n (buffers-test:fresh '(md:doc () (md:para () "Alpha.\n") (lists:bulleted () (md:item () "Beta gamma.\n"))))]
        [spans-of (lambda (b) (map (lambda (s) (list (document:text (buffers:document b) (car s) (cadr s)) (caddr s)))
                                   (buffers:spans (buffers:layer b responses) 0 20)))])
    (buffers:add-span! (buffers:layer n responses) 12 16 'bold)
    (buffers:replace! n 8 12 "")
    (check-equal? '(md:doc () (md:para () "Alpha.Beta gamma.\n") (lists:bulleted ())) (buffers-test:root n))
    (check-equal? '(("Beta" bold)) (spans-of n))
    (let ([o (buffers-test:fresh '(md:doc () (md:para () "Alpha.\n") (lists:bulleted () (md:item () "Beta gamma.\n"))))]
          [x-piece (let ([x (buffers-test:fresh "X\n")])
                     (buffers:add-span! (buffers:layer x responses) 1 2 'x)
                     (buffers:piece x 1 3))])
      (buffers:add-span! (buffers:layer o responses) 12 16 'bold)
      (buffers:replace! o 8 12 x-piece)
      (check-equal? '(("X" x) ("Beta" bold)) (spans-of o)))))

(test "yanking an open slice into a paragraph splits it, keeps the spans after the yank point and brings the piece's own"
  (let* ([make (lambda ()
                 (let ([b (buffers-test:fresh '(md:doc () (md:para () "One two.\n") (md:para () "Three four.\n") (md:para () "Five six seven.\n")))])
                   (buffers:add-span! (buffers:layer b responses) 33 38 'bold)
                   b))]
         [texts (lambda (b) (map (lambda (s) (list (document:text (buffers:document b) (car s) (cadr s)) (caddr s)))
                                 (buffers-test:all-spans (buffers:layer b responses) b)))]
         [y (make)])
    (buffers:add-span! (buffers:layer y responses) 7 9 'it)
    (let ([slice (document:slice (buffers:document y) 6 17)])
      (check-equal? '((md:para () "two.\n") (md:para () "Thre")) (document:datums slice))
      (buffers:replace! y 30 30 (buffers:piece y 6 17))
      (check-equal? '(md:doc () (md:para () "One two.\n") (md:para () "Three four.\n") (md:para () "Fivtwo.\n") (md:para () "Three six seven.\n"))
                    (buffers-test:root y))
      (check-equal? '(("wo" it) ("wo" it) ("ix se" bold)) (texts y))
      (let ([z (make)])
        (buffers:replace! z 30 30 slice)
        (check-equal? '(("ix se" bold)) (texts z))))))

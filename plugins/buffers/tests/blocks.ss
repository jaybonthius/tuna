(import (tuna) (test) (timers) (buffers) (document) (md) (lists) (sheets) (buffers-test))

(define (fit b s e) (buffers:fitted-ranges b s e))

(define (delete b s e) (buffers:replace! b s e "") (buffers-test:children b))

(define (fits make ranges) (map (lambda (r) (fit (make) (car r) (cdr r))) ranges))

(define (deletes make ranges) (map (lambda (r) (delete (make) (car r) (cdr r))) ranges))

(define (notes) (buffers-test:fresh '(md:doc () (md:heading () "Head\n") (md:para () "First para.\n") (md:para () "Second para.\n") (md:para () "Last.\n"))))

;; "Hi" at 2-4, cell a at 8-11, cell b at 12-15, "Yo" at 18-22.
(define (sheet) (buffers-test:fresh '(md:doc () (md:para () "Hi\n") (sheets:grid () (sheets:row () (sheets:cell () "a\n") (sheets:cell () "b\n"))) (md:para () "Yo\n"))))

(define (plan) (buffers-test:fresh '(md:doc () (md:heading () "Plan\n") (md:para () "Buy milk.\n"))))

(test "kind-isolating? tells the kinds that said (isolating)"
  (check-equal? '(#t #t #f #f) (map (lambda (k) (buffers:kind-isolating? (buffers:kind k))) '(sheets:cell sheets:box sheets:row md:para)))
  (check-raises (buffers-test:raised-with? 'buffers:kind-isolating? "not a kind" '(cell)) (buffers:kind-isolating? 'cell)))

(test "a deletion at a block's end joins the next block's text, keeping the first block's kind; one from a line's start to the next takes the block whole; the last block keeps its line break"
  (check-equal? '(((20 . 23)) ((3 . 9)) ((1 . 8)) () ((38 . 43)) ((3 . 23)))
    (fits notes '((20 . 21) (3 . 7) (2 . 7) (43 . 44) (38 . 44) (3 . 21))))
  (check-equal? '(((md:heading () "Head\n") (md:para () "First para.Second para.\n") (md:para () "Last.\n"))
                  ((md:heading () "HFirst para.\n") (md:para () "Second para.\n") (md:para () "Last.\n"))
                  ((md:para () "First para.\n") (md:para () "Second para.\n") (md:para () "Last.\n"))
                  ((md:heading () "Head\n") (md:para () "First para.\n") (md:para () "Second para.\n") (md:para () "\n"))
                  ((md:heading () "HSecond para.\n") (md:para () "Last.\n")))
    (deletes notes '((20 . 21) (3 . 7) (2 . 7) (38 . 44) (3 . 21)))))

(test "from right after a block's line break, a deletion starts at the next block's first position, and removes it whole when it covers it"
  (let ([abc (buffers-test:fresh '(md:doc () (md:para () "x\n") (md:para () "abc\n") (md:para () "def\n")))])
    (check-equal? '((5 . 14)) (fit abc 4 14))
    (check-equal? '((md:para () "x\n") (md:para () "f\n")) (delete abc 4 14)))
  (let ([gap (buffers-test:fresh '(md:doc () (md:para () "a\n") (md:para () "\n") (md:para () "b\n")))])
    (check-equal? '(((5 . 8)) ((3 . 6))) (list (fit gap 6 9) (fit gap 3 6)))
    (check-equal? '((md:para () "a\n") (md:para () "b\n")) (delete gap 6 9))))

(test "before an atom standing as a block, the atom goes and the line break stays"
  (let ([ruled (lambda () (buffers-test:fresh '(md:doc () (md:para () "abxy\n") #(sheets:rule ()) #(sheets:rule ()) (md:para () "cd\n"))))])
    (check-equal? '(((8 . 9)) ((4 . 6) (8 . 9)) ((9 . 11))) (fits ruled '((6 . 8) (4 . 9) (9 . 11))))
    (check-equal? '(((md:para () "abxy\n") #(sheets:rule ()) (md:para () "cd\n"))
                    ((md:para () "ab\n") #(sheets:rule ()) (md:para () "cd\n"))
                    ((md:para () "abxy\n") #(sheets:rule ()) (md:para () "cd\n")))
      (deletes ruled '((6 . 8) (4 . 9) (9 . 11))))))

(test "a nested block goes with the nodes whose content starts with it and that the deletion covers"
  (let ([listed (buffers-test:fresh '(md:doc () (lists:bulleted () (md:item () "a\n") (md:item () "b\n")) (md:para () "z\n")))])
    (check-equal? '((2 . 6)) (fit listed 3 5))
    (check-equal? '((lists:bulleted () (md:item () "b\n")) (md:para () "z\n")) (delete listed 3 5))))

(test "an inline node's line break is text, and a file buffer, which has no blocks, loses its whole content"
  (check-equal? '((5 . 6)) (fit (buffers-test:fresh '(md:doc () (md:para () "a" (md:link () "b\n") "c\n"))) 5 6))
  (let ([file (buffers-test:fresh "ab\ncd\n")])
    (check-equal? '((1 . 7)) (fit file 1 7))
    (check-equal? '() (delete file 1 7))))

(test "no text goes into or out of an isolating node: a deletion is fitted on each side of its edges"
  (check-equal? '(() ((13 . 14)) ((9 . 10)) ((1 . 6) (9 . 10)) ((3 . 4) (9 . 10) (13 . 14)) ((6 . 20)) ((13 . 14) (19 . 20))
                  ((13 . 14) (19 . 20)) ((1 . 21)) ((1 . 6) (9 . 10) (13 . 14)) () () ((9 . 10) (13 . 14)))
    (fits sheet '((10 . 13) (13 . 15) (9 . 11) (2 . 13) (3 . 14) (9 . 20) (13 . 20) (10 . 20) (2 . 21) (2 . 14) (4 . 9) (14 . 19) (9 . 14))))
  (check-equal? '(((md:para () "Hi\n") (sheets:grid () (sheets:row () (sheets:cell () "a\n") (sheets:cell () "\n"))) (md:para () "Yo\n"))
                  ((sheets:grid () (sheets:row () (sheets:cell () "\n") (sheets:cell () "b\n"))) (md:para () "Yo\n"))
                  ((md:para () "H\n") (sheets:grid () (sheets:row () (sheets:cell () "\n") (sheets:cell () "\n"))) (md:para () "Yo\n"))
                  ((md:para () "Hi\n") (md:para () "o\n"))
                  ((md:para () "Hi\n") (sheets:grid () (sheets:row () (sheets:cell () "a\n") (sheets:cell () "\n"))) (md:para () "o\n"))
                  ((md:para () "\n")))
    (deletes sheet '((13 . 15) (2 . 13) (3 . 14) (9 . 20) (13 . 20) (2 . 21)))))

(test "a deletion that fits to nothing makes an edit that changes nothing, and fitting a fitted range changes nothing"
  (let ([b (sheet)])
    (check-equal? 1 (buffers:edit-version (buffers:replace! b 10 13 "")))
    (check-equal? (buffers-test:children (sheet)) (buffers-test:children b))
    (check-equal? '(#t #t #t #t #t #t)
      (map (lambda (r) (equal? (fit b (car r) (cdr r)) (list r))) '((1 . 6) (9 . 10) (6 . 20) (13 . 14) (19 . 20) (1 . 21))))))

(test "a split deletion is one edit, so one step takes it back, and anchors on what it puts back go to its edges"
  (let* ([split (sheet)] [on-a (buffers:anchor split 10)] [v (buffers:version split)])
    (buffers:replace! split 3 14 "")
    (check-equal? '(1 3) (list (length (buffers:edits-since split v)) (buffers:anchor-position on-a)))
    (let ([e (car (buffers:edits-since split v))])
      (buffers:splice! split (buffers:edit-start e) (+ (buffers:edit-start e) (buffers:piece-length (buffers:edit-inserted e)))
        (buffers:edit-removed e)))
    (check-equal? (buffers-test:children (sheet)) (buffers-test:children split))))

(test "a range from a paragraph into a table's second row removes the first row whole and shortens that cell"
  (let ([rows (buffers-test:fresh '(md:doc () (md:para () "Hi\n") (sheets:grid () (sheets:row () (sheets:cell () "a\n") (sheets:cell () "b\n")) (sheets:row () (sheets:cell () "c\n") (sheets:cell () "d\n"))) (md:para () "Yo\n")))])
    (check-equal? '((1 . 6) (7 . 17) (19 . 20)) (fit rows 2 20))
    (check-equal? '((sheets:grid () (sheets:row () (sheets:cell () "\n") (sheets:cell () "d\n"))) (md:para () "Yo\n")) (delete rows 2 20))))

(test "a row of one cell is a line: taking the cell's text and line break removes the row, or the table of one row, unless it is the last block"
  (let ([column (lambda () (buffers-test:fresh '(md:doc () (md:para () "Hi\n") (sheets:grid () (sheets:row () (sheets:cell () "a\n")) (sheets:row () (sheets:cell () "b\n"))) (md:para () "Yo\n"))))])
    (check-equal? '(((7 . 13)) ((13 . 19))) (fits column '((9 . 11) (15 . 17))))
    (check-equal? '((md:para () "Hi\n") (sheets:grid () (sheets:row () (sheets:cell () "b\n"))) (md:para () "Yo\n")) (delete (column) 9 11)))
  (check-equal? '((md:para () "Hi\n") (md:para () "Yo\n"))
    (delete (buffers-test:fresh '(md:doc () (md:para () "Hi\n") (sheets:grid () (sheets:row () (sheets:cell () "a\n"))) (md:para () "Yo\n"))) 9 11))
  (check-equal? '((md:para () "Hi\n") (sheets:grid () (sheets:row () (sheets:cell () "\n"))))
    (delete (buffers-test:fresh '(md:doc () (md:para () "Hi\n") (sheets:grid () (sheets:row () (sheets:cell () "a\n"))))) 9 11)))

(test "whole nodes go as asked: a cell, the last block, a table"
  (check-equal? '(((md:para () "Hi\n") (sheets:grid () (sheets:row () (sheets:cell () "b\n"))) (md:para () "Yo\n"))
                  ((md:para () "Hi\n") (sheets:grid () (sheets:row () (sheets:cell () "a\n") (sheets:cell () "b\n"))))
                  ((md:para () "Hi\n") (md:para () "Yo\n")))
    (deletes sheet '((8 . 12) (18 . 23) (6 . 18)))))

(test "an isolating node holding blocks that the deletion covers keeps its last block, emptied; the one holding the end loses its content up to it"
  (let ([boxes (buffers-test:fresh '(md:doc () (md:para () "Hi\n") (sheets:grid () (sheets:row () (sheets:box () (md:para () "x\n") (md:para () "y\n")) (sheets:box () (md:para () "z\n")))) (md:para () "Yo\n")))])
    (check-equal? '((1 . 6) (9 . 15) (20 . 21)) (fit boxes 2 21))
    (check-equal? '((sheets:grid () (sheets:row () (sheets:box () (md:para () "\n")) (sheets:box () (md:para () "\n")))) (md:para () "Yo\n"))
      (delete boxes 2 21))))

(test "the last block of an isolating node goes with the nodes around it only when a node around the isolating node goes too"
  (let ([grid-first (lambda () (buffers-test:fresh '(md:doc () (sheets:grid () (sheets:row () (sheets:box () (md:para () "x\n")) (sheets:box () (md:para () "y\n")))) (md:para () "after\n"))))])
    (check-equal? '(((1 . 23)) ((5 . 6))) (fits grid-first '((5 . 23) (5 . 11))))
    (check-equal? '(((md:para () "\n"))
                    ((sheets:grid () (sheets:row () (sheets:box () (md:para () "\n")) (sheets:box () (md:para () "y\n")))) (md:para () "after\n")))
      (deletes grid-first '((5 . 23) (5 . 11)))))
  (let ([alone (buffers-test:fresh '(md:doc () (sheets:grid () (sheets:row () (sheets:box () (md:para () "x\n"))) (sheets:row () (sheets:box () (md:para () "y\n")))) (md:para () "after\n")))])
    (check-equal? '((2 . 10)) (fit alone 5 7))
    (check-equal? '((sheets:grid () (sheets:row () (sheets:box () (md:para () "y\n")))) (md:para () "after\n")) (delete alone 5 7))))

(test "blocks put inside a paragraph split it, the first half ending with a line break; at a block's first position they go before it; in a cell they go in as text"
  (check-equal? '((md:heading () "Plan\n") (md:para () "Buy\n") (md:heading () "H\n") (md:para () " milk.\n"))
    (let ([b (plan)]) (buffers:insert! b 12 '(md:heading () "H\n")) (buffers-test:children b)))
  (check-equal? '((md:heading () "Plan\n") (md:heading () "H\n") (md:para () "Buy milk.\n"))
    (let ([b (plan)]) (buffers:insert! b 9 '(md:heading () "H\n")) (buffers-test:children b)))
  (check-equal? '((md:para () "Hi\n") (sheets:grid () (sheets:row () (sheets:cell () "Plan\na\n") (sheets:cell () "b\n"))) (md:para () "Yo\n"))
    (let ([b (sheet)]) (buffers:insert! b 9 (buffers:piece (plan) 1 8)) (buffers-test:children b)))
  (let ([b (sheet)] [cells (buffers:piece (sheet) 9 14)])
    (check-equal? 1 (document:open-start (buffers:piece-document cells)))
    (buffers:insert! b 3 cells)
    (check-equal? '((md:para () "Ha\nbi\n") (sheets:grid () (sheets:row () (sheets:cell () "a\n") (sheets:cell () "b\n"))) (md:para () "Yo\n"))
      (buffers-test:children b))))

(test "text inserted right after a block's final line break is refused, and a block inserted there goes in after the block"
  (check-equal? '(refused "the edit would leave a block without its final line break")
    (buffers-test:refusal (lambda () (buffers:insert! (plan) 7 "x"))))
  (check-equal? '(#t #f) (list (buffers:refuses-text? (plan) 7 7) (buffers:refuses-text? (plan) 6 6)))
  (check-equal? '((md:heading () "Plan\n") (md:heading () "H\n") (md:para () "Buy milk.\n"))
    (let ([b (plan)]) (buffers:insert! b 7 '(md:heading () "H\n")) (buffers-test:children b))))

(test "a replacement is not fitted: it is refused when a block would lose its final line break or the range crosses an isolating node's edge"
  (check-equal? '(refused "the edit would leave a block without its final line break")
    (buffers-test:refusal (lambda () (buffers:replace! (plan) 2 7 "PLAN"))))
  (check-equal? '(refused "the edit would cross an isolating node's edge")
    (buffers-test:refusal (lambda () (buffers:replace! (sheet) 9 13 "x"))))
  (check-equal? #t (buffers:refuses-text? (sheet) 9 13))
  (check-equal? '((md:heading () "PLAN\n") (md:para () "Buy milk.\n"))
    (let ([b (plan)]) (buffers:replace! b 2 7 "PLAN\n") (buffers-test:children b))))

(test "typing over a selected heading, deleted first, goes where the deletion leaves the cursor"
  (check-equal? '((md:para () "xBuy milk.\n"))
    (let ([b (plan)]) (buffers:replace! b 2 9 "") (buffers:insert! b (buffers:stop b 1) "x") (buffers-test:children b))))

(define seen #f)

(buffers:define-kind page (content nodes)
  (consent (lambda (n e) (set! seen (list (buffers:edit-start e) (buffers:piece-length (buffers:edit-removed e)))) #t)))

(buffers:define-layer fence (read-only))

(test "a consent sees the fitted edit, and a read-only span the fitted range"
  (let ([b (buffers-test:fresh (page '() (md:heading '() "Plan\n") (md:para '() "Buy milk.\n")))])
    (buffers:replace! b 2 7 "")
    (check-equal? '(1 7) seen))
  (let ([locked-next (buffers-test:fresh '(md:doc () (md:para () "ab\n") (md:para () "cd\n")))])
    (buffers:add-span! (buffers:layer locked-next fence) 6 10 'fence)
    (check-equal? '(((4 . 7)) (refused "a read-only span refuses the edit"))
      (list (fit locked-next 4 5) (buffers-test:refusal (lambda () (buffers:replace! locked-next 4 5 "")))))))

;; Chez finds a module stale when its source is newer than its object, and
;; file times step with the kernel's clock tick, 1 to 10 ms, so a rewrite
;; in the tick of the last compile would look unchanged.
(define (write-module! name text)
  (timers:sleep 0.01)
  (call-with-output-file (string-append (getenv "HOME") "/.config/tuna/lib/" name ".sls")
    (lambda (p) (put-string p text))
    'replace))

(test "a kind redefined with (isolating) or without it fits the next deletion by its new definition, in a document fitted before"
  (let ([boxed (lambda () (buffers-test:fresh '(md:doc () (md:para () "Hi\n") (boxes:box () (md:para () "x\n")) (boxes:box () (md:para () "y\n")) (md:para () "Yo\n"))))])
    (write-module! "boxes" "#!tuna\n(import (buffers))\n\n(buffers:define-kind box (content nodes))\n")
    (load-module! '(boxes))
    (let ([bx (boxed)])
      (check-equal? '(((1 . 20)) ((1 . 20))) (list (fit bx 2 20) (fit bx 2 20)))
      (write-module! "boxes" "#!tuna\n(import (buffers))\n\n(buffers:define-kind box (content nodes) (isolating))\n")
      (reload-modules! '((boxes)))
      (check-equal? '(((1 . 6) (8 . 9) (14 . 15) (19 . 20)) ((1 . 6) (8 . 9) (14 . 15) (19 . 20)))
        (list (fit bx 2 20) (fit (boxed) 2 20))))))

(test "fitted-ranges checks its arguments"
  (check-raises (buffers-test:raised? 'buffers:fitted-ranges "not a buffer") (buffers:fitted-ranges "b" 1 2))
  (check-raises (buffers-test:raised? 'buffers:fitted-ranges "the start is after the end") (buffers:fitted-ranges (plan) 3 1))
  (check-raises (buffers-test:raised? 'buffers:fitted-ranges "not a position in the buffer") (buffers:fitted-ranges (plan) 0 99)))

(test "the docs' examples of fitted ranges hold"
  (let ([plan (buffers:make "*plan*" '(notes:page () (md:heading ((level . 1)) "Plan\n") (md:para () "Buy milk.\n")))]
        [sheet (buffers:make "*sheet*"
                 '(notes:page () (md:para () "Hi\n")
                    (sheets:grid () (sheets:row () (sheets:cell () "a\n") (sheets:cell () "b\n")))
                    (md:para () "Yo\n")))])
    (check-equal? '(((6 . 9)) ((1 . 8)) ()) (list (fit plan 6 7) (fit plan 2 7) (fit plan 18 19)))
    (check-equal? '(() ((13 . 14)) ((1 . 6) (9 . 10)) ((6 . 20)))
      (list (fit sheet 10 13) (fit sheet 13 15) (fit sheet 2 13) (fit sheet 9 20)))))

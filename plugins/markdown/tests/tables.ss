(import (tuna) (test) (test-user) (buffers) (document) (views) (layout) (keys) (commands) (options) (editing) (kill-ring)
        (echo-area) (markdown) (buffers-test) (markdown-test page))

(define (view) (layout:selected-view))

(define (show! b)
  (views:set-buffer! (view) b)
  (views:set-point! (view) 1)
  b)

(define (datums b) (document:datums (buffers:document b)))

(define (press! keys) (test-user:press! keys))

;; A key whose command raises is reported; each test names the reports
;; its keys cause.
(define (reported keys)
  (map (lambda (c) (list (condition-who c) (condition-message c))) (buffers-test:reports-during (lambda () (press! keys)))))

(define (at text)
  (let* ([b (views:buffer (view))] [s (document:text (buffers:document b))])
    (let loop ([i 0])
      (if (string=? (substring s i (+ i (string-length text))) text)
          (buffers:stop b (document:position (buffers:document b) i (document:unit characters)))
          (loop (+ i 1))))))

(define (cell-text)
  (let* ([doc (buffers:document (views:buffer (view)))] [p (views:point (view))] [n (document:enclosing doc p)])
    (list (document:node-kind n) (document:text doc (document:node-start n) p) (document:text doc p (document:node-end n)))))

(define t (show! (markdown-test/page:make "*table*" "Before\n\n| name | size |\n|---|---|\n| alpha | 1 |\n| b | 22 |\n\nAfter\n")))

(test "in a table C-n and C-p move to the cell below and above in the same column, at the same character as far as its text goes"
  (show! t)
  (views:set-point! (view) (+ (at "name") 3))
  (press! "C-n")
  (check-equal? '(markdown:table-cell "alp" "ha\n") (cell-text))
  (press! "C-n")
  (check-equal? '(markdown:table-cell "b" "\n") (cell-text))
  (press! "C-p C-p")
  (check-equal? '(markdown:table-cell "nam" "e\n") (cell-text))
  (views:set-point! (view) (+ (at "size") 4))
  (press! "<down> <down>")
  (check-equal? '(markdown:table-cell "22" "\n") (cell-text)))

(test "a count moves that many rows; past the table's edge, to the lines before or after it"
  (show! t)
  (views:set-point! (view) (at "name"))
  (press! "C-u 2 C-n")
  (check-equal? '(markdown:table-cell "" "b\n") (cell-text))
  (press! "C-n")
  (check-equal? '(markdown:paragraph "" "After\n") (cell-text))
  (views:set-point! (view) (at "size"))
  (press! "C-p")
  (check-equal? '(markdown:paragraph "" "Before\n") (cell-text)))

(test "the column is kept through a run of line motions, into the table and out of it"
  (show! t)
  (views:set-point! (view) (+ (at "alpha") 4))
  (press! "C-n C-n")
  (check-equal? '(markdown:paragraph "Afte" "r\n") (cell-text))
  (views:set-point! (view) (+ (at "Before") 4))
  (press! "C-n C-n")
  (check-equal? '(markdown:table-cell "alph" "a\n") (cell-text)))

(test "Shift extends the region from where point was, and the next motion without it clears the region"
  (show! t)
  (views:set-point! (view) (at "name"))
  (press! "S-<down>")
  (check-equal? (list (at "name") (at "alpha")) (list (views:mark (view)) (views:point (view))))
  (press! "C-n")
  (check-equal? (list #f '(markdown:table-cell "" "b\n")) (list (views:mark (view)) (cell-text))))

(test "other cursors in cells move by row too, and cursors outside the table by line"
  (show! t)
  (views:set-point! (view) (at "name"))
  (views:add-cursor! (view) (at "size"))
  (views:add-cursor! (view) (at "Before"))
  (press! "C-n")
  (check-equal? (list (at "alpha") (at "1\n") (at "name")) (map views:cursor-point (views:cursors (view))))
  (for-each (lambda (c) (views:remove-cursor! (view) c)) (cdr (views:cursors (view)))))

(test "cursors that reach one place merge, so typing there inserts once"
  (show! t)
  (views:set-point! (view) (at "name"))
  (views:add-cursor! (view) (at "alpha"))
  (press! "C-u 5 C-n")
  (check-equal? 1 (length (views:cursors (view))))
  (check-equal? '(markdown:paragraph "After" "\n") (cell-text))
  (press! "x")
  (check-equal? "Before\nname\nsize\nalpha\n1\nb\n22\nAfterx\n" (document:text (buffers:document t))))

(test "at the buffer's edges, as next-line and previous-line: to the edge, then an error"
  (show! (markdown-test/page:make "*edges*" "| name | size |\n|---|---|\n| alpha | 1 |\n| b | 22 |\n"))
  (views:set-point! (view) (at "b\n"))
  (press! "C-n")
  (check-equal? '(markdown:table-cell "22" "\n") (cell-text))
  (check-equal? '((markdown:next-row "end of buffer")) (reported "C-n"))
  (views:set-point! (view) (+ (at "size") 1))
  (press! "C-p")
  (check-equal? '(markdown:table-cell "" "name\n") (cell-text))
  (check-equal? '((markdown:previous-row "beginning of buffer")) (reported "C-p")))

(keys:bind! keys:global "C-c n" editing:next-line)

(test "the table remaps next-line and previous-line, so other keys bound to them move by row too"
  (show! t)
  (views:set-point! (view) (at "name"))
  (press! "C-c n")
  (check-equal? '(markdown:table-cell "" "alpha\n") (cell-text)))

(test "the commands check their count"
  (check-raises (buffers-test:raised? 'markdown:previous-row "not an exact integer") (markdown:previous-row 'x))
  (check-raises (buffers-test:raised? 'markdown:next-row "not an exact integer") (markdown:next-row 1.5)))

(test "where point is in a table: the header or a row counted after it, and the column; in a code block its own line and column"
  (show! t)
  (views:set-point! (view) (at "22"))
  (check-equal? "row 2, column 2" (views:with-view (view) (views:describe-at-point (view))))
  (views:set-point! (view) (at "size"))
  (check-equal? "header, column 2" (views:with-view (view) (views:describe-at-point (view))))
  (let ([c (show! (markdown-test/page:make "*code*" "Text\n\n```\none\ntwo\n```\n"))])
    (views:set-point! (view) 14)
    (check-equal? '("L2" "L3") (list (views:with-view (view) (views:describe-at-point (view))) (views:describe-line (document:token (buffers:document c) 0) (view))))
    (check-raises (buffers-test:raised? 'markdown:describe-cell "not a Markdown table cell") (markdown:describe-cell (document:token (buffers:document c) 0) (view)))))

;; On a sheet, "Hi" is at 2-4, cell a at 9-10, cell b at 13-14 and "Yo" at 19-21.
(define (sheet)
  (markdown-test/page:page '() (markdown:paragraph '() "Hi\n")
    (markdown:table '((columns . 2)) (markdown:table-row '() (markdown:table-cell '() "a\n") (markdown:table-cell '() "b\n")))
    (markdown:paragraph '() "Yo\n")))

(define (fresh-sheet point)
  (let ([b (buffers:make (buffers:free-name "sheet") (sheet))])
    (show! b)
    (views:set-point! (view) point)
    b))

(define (on-sheet point keys)
  (let ([b (fresh-sheet point)])
    (buffers-test:reports-during (lambda () (press! keys)))
    (list (cddr (car (datums b))) (views:point (view)))))

(define (row a b) `(markdown:table ((columns . 2)) (markdown:table-row () (markdown:table-cell () ,a) (markdown:table-cell () ,b))))

(define whole-sheet `((markdown:paragraph () "Hi\n") ,(row "a\n" "b\n") (markdown:paragraph () "Yo\n")))

(test "cells are isolating: these deletions, case changes and word kills at cells' and paragraphs' edges change nothing"
  (check-equal? '() (filter (lambda (case) (not (equal? whole-sheet (car (on-sheet (car case) (cadr case))))))
                            '((4 "C-d") (10 "C-d") (14 "C-d") (9 "DEL") (13 "DEL") (19 "DEL") (4 "C-k") (10 "C-k") (14 "C-k")
                              (4 "M-d") (10 "M-d") (14 "M-d") (13 "M-DEL") (19 "M-DEL") (9 "M-^") (13 "M-^") (19 "M-^") (10 "M-u")))))

(test "a kill that removes nothing adds no entry, so the kill before stays the one C-y yanks"
  (let ([b (fresh-sheet 2)])
    (views:set-mark! (view) 4)
    (press! "M-w")
    (views:set-point! (view) 10)
    (press! "C-k C-y")
    (check-equal? "Hi" (kill-ring:text (kill-ring:current)))
    (check-equal? `((markdown:paragraph () "Hi\n") ,(row "aHi\n" "b\n") (markdown:paragraph () "Yo\n")) (cddr (car (datums b))))))

(test "word motions stop at a cell's edges"
  (check-equal? '(4 10 9 19) (map (lambda (case) (cadr (on-sheet (car case) (cadr case)))) '((4 "M-f") (10 "M-f") (9 "M-b") (19 "M-b")))))

(test "a count of deletions or kills inside a cell stops at its end"
  (check-equal? (list `((markdown:paragraph () "Hi\n") ,(row "\n" "\n") (markdown:paragraph () "Yo\n")) 9) (on-sheet 9 "C-u 3 C-d"))
  (check-equal? (list `((markdown:paragraph () "Hi\n") ,(row "\n" "b\n") (markdown:paragraph () "Yo\n")) 9) (on-sheet 9 "C-k"))
  (check-equal? (list `((markdown:paragraph () "Hi\n") ,(row "\n" "b\n") (markdown:paragraph () "Yo\n")) 9) (on-sheet 9 "C-u 2 C-k"))
  (check-equal? (list `((markdown:paragraph () "Hi\n") ,(row "a\n" "\n") (markdown:paragraph () "Yo\n")) 13) (on-sheet 14 "C-u - 1 C-k"))
  (check-equal? (list `(,(row "\n" "b\n") (markdown:paragraph () "Yo\n")) 4) (on-sheet 2 "C-u 2 C-k")))

(test "C-S-DEL in a cell kills its text; in a paragraph beside the table, the paragraph's line"
  (check-equal? (list `((markdown:paragraph () "Hi\n") ,(row "\n" "b\n") (markdown:paragraph () "Yo\n")) 9) (on-sheet 9 "C-S-DEL"))
  (check-equal? (list `((markdown:paragraph () "Hi\n") ,(row "a\n" "\n") (markdown:paragraph () "Yo\n")) 13) (on-sheet 13 "C-S-DEL"))
  (check-equal? (list `(,(row "a\n" "b\n") (markdown:paragraph () "Yo\n")) 4) (on-sheet 2 "C-S-DEL"))
  (check-equal? (list `((markdown:paragraph () "Hi\n") ,(row "a\n" "b\n") (markdown:paragraph () "\n")) 19) (on-sheet 19 "C-S-DEL")))

(test "a case change stops at the paragraph's edge; transposing across a cell's edge refuses"
  (check-equal? (list `((markdown:paragraph () "HI\n") ,(row "a\n" "b\n") (markdown:paragraph () "Yo\n")) 4) (on-sheet 2 "M-3 M-u"))
  (let ([b (fresh-sheet 10)])
    (check-equal? '((editing:transpose-chars "no two characters to transpose")) (reported "C-t"))
    (check-equal? whole-sheet (cddr (car (datums b)))))
  (let ([b (fresh-sheet 13)])
    (check-equal? '((editing:transpose-words "no two words to transpose")) (reported "M-t"))
    (check-equal? whole-sheet (cddr (car (datums b))))))

(test "lines in different cells move as texts, so the cells stay"
  (check-equal? (list `((markdown:paragraph () "Hi\n") ,(row "b\n" "a\n") (markdown:paragraph () "Yo\n")) 19) (on-sheet 13 "C-x C-t"))
  (check-equal? (list `((markdown:paragraph () "Hi\n") ,(row "b\n" "a\n") (markdown:paragraph () "Yo\n")) 13) (on-sheet 9 "M-<down>"))
  (check-equal? (list `((markdown:paragraph () "Hi\n") ,(row "a\n" "Yo\n") (markdown:paragraph () "b\n")) 21) (on-sheet 19 "C-x C-t")))

(define (over-sheet point mark keys)
  (let ([b (fresh-sheet point)])
    (views:set-mark! (view) mark)
    (press! keys)
    (list (cddr (car (datums b))) (views:point (view)))))

(test "typing over a region deletes it first and goes where the deletion leaves the cursor"
  (options:set! editing:delete-selection #t)
  (check-equal? (list `((markdown:paragraph () "Hx\n") ,(row "\n" "\n") (markdown:paragraph () "Yo\n")) 4) (over-sheet 14 3 "x"))
  (check-equal? (list `(,(row "x\n" "b\n") (markdown:paragraph () "Yo\n")) 5) (over-sheet 13 2 "x"))
  (check-equal? (list `((markdown:paragraph () "Hi\n") ,(row "ax\n" "\n") (markdown:paragraph () "o\n")) 11) (over-sheet 20 10 "x"))
  (options:unset! editing:delete-selection))

(test "a kill reaching into cells yanks back as text; blocks yanked into a cell go in as their text; yank-pop and RET in a cell"
  (check-equal? (list `(,(row "Hi\na\n" "b\n") (markdown:paragraph () "Yo\n")) 8) (over-sheet 13 2 "C-w C-y"))
  (check-equal? "Hi\na" (kill-ring:text (kill-ring:current)))
  (kill-ring:push! (list (buffers:piece (markdown-test/page:make "*plan*" "# Plan\n\nBuy.\n") 1 8)))
  (check-equal? (list `((markdown:paragraph () "Hi\n") ,(row "Plan\na\n" "b\n") (markdown:paragraph () "Yo\n")) 14) (on-sheet 9 "C-y"))
  (kill-ring:push! (list "one"))
  (kill-ring:push! (list "two"))
  (check-equal? (list `((markdown:paragraph () "Hi\n") ,(row "onea\n" "b\n") (markdown:paragraph () "Yo\n")) 12) (on-sheet 9 "C-y M-y"))
  (check-equal? (list `((markdown:paragraph () "Hi\n") ,(row "a\n\n" "b\n") (markdown:paragraph () "Yo\n")) 11) (on-sheet 10 "RET")))

(test "the primary selection and duplicate-dwim read a region as M-w does"
  (fresh-sheet 14)
  (views:set-mark! (view) 3)
  (press! "C-f C-b")
  (check-equal? "iab" (kill-ring:text (list (editing:primary-selection))))
  (let ([b (fresh-sheet 14)])
    (views:set-mark! (view) 9)
    (views:call-with-view (view) (lambda () (commands:run editing:duplicate-dwim 1)))
    (check-equal? `((markdown:paragraph () "Hi\n") ,(row "a\n" "bab\n") (markdown:paragraph () "Yo\n")) (cddr (car (datums b))))))

(test "a row of one cell is a line, which C-S-DEL removes, unless the table is the buffer's last block"
  (let ([one (show! (markdown-test/page:make "*one*" "Hi\n\n| a |\n|---|\n| b |\n\nYo\n"))])
    (views:set-point! (view) (at "b\n"))
    (press! "C-S-DEL")
    (check-equal? '((markdown:paragraph ((key . 0)) "Hi\n")
                    (markdown:table ((key . 1) (columns . 1)) (markdown:table-row ((key . 0) (header . #t)) (markdown:table-cell ((key . 0)) "a\n")))
                    (markdown:paragraph ((key . 2)) "Yo\n"))
                  (cddr (car (datums one))))
    (check-equal? 15 (views:point (view))))
  (let ([last (show! (markdown-test/page:make "*last*" "Hi\n\n| a |\n|---|\n| b |\n"))])
    (views:set-point! (view) (at "b\n"))
    (press! "C-S-DEL")
    (check-equal? '((markdown:paragraph ((key . 0)) "Hi\n")
                    (markdown:table ((key . 1) (columns . 1)) (markdown:table-row ((key . 0) (header . #t)) (markdown:table-cell ((key . 0)) "a\n"))
                                    (markdown:table-row ((key . 1)) (markdown:table-cell ((key . 0)) "\n"))))
                  (cddr (car (datums last))))))

(test "a region from a paragraph into a table's second row removes the first row and shortens that cell"
  (let ([two (show! (markdown-test/page:make "*two*" "Hi\n\n| a | b |\n|---|---|\n| c | d |\n\nYo\n"))])
    (views:set-point! (view) (+ (at "c\n") 1))
    (views:set-mark! (view) (at "Hi"))
    (press! "C-w")
    (check-equal? '((markdown:table ((key . 1) (columns . 2)) (markdown:table-row ((key . 1)) (markdown:table-cell ((key . 0)) "\n") (markdown:table-cell ((key . 1)) "d\n")))
                    (markdown:paragraph ((key . 2)) "Yo\n"))
                  (cddr (car (datums two))))
    (check-equal? 4 (views:point (view)))))

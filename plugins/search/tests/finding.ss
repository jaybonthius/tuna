(import (tuna) (test) (test-runner) (rename (only (chezscheme) sleep) (sleep chez:sleep))
        (buffers) (search) (search-test))

(define forward search-test:forward)
(define backward search-test:backward)
(define find-in search-test:find-in)
(define text-buffer search-test:text-buffer)
(define end-of search-test:end-of)

(define b (text-buffer "f" "one two three two one\n"))
(define aaaa (text-buffer "aaaa" "aaaa\n"))
(define fb (text-buffer "fb" "foobar foo\nfoo bar\n"))

(define (rx text) (search:make-query text search:regexp))

(buffers:define-kind page (content nodes))
(buffers:define-kind para)
(define (tag-text node) "TAG")
(buffers:define-kind tag (content atom) (text tag-text))

(test "forward, the first match at or after the place; backward, the last that ends at or before it"
  (let ([two (search:make-query "two")])
    (check-equal? '((5 8 "two") (15 18 "two") (15 18 "two"))
                  (list (find-in b two 0 forward) (find-in b two 6 forward) (find-in b two 9 forward)))
    (check-equal? '((15 18 "two") (5 8 "two") #f)
                  (list (find-in b two 23 backward) (find-in b two 17 backward) (find-in b two 4 backward)))))

(test "backward reads as if the text ended at the place"
  (check-equal? '(2 4 "aa") (find-in (text-buffer "aaa" "aaa\n") (search:make-query "aa") 4 backward)))

(test "a find from inside a forward chain's match gives the match that starts there, before and after a scan covers it"
  (let ([aa (search:make-query "aa")])
    (check-equal? '(2 4 "aa") (find-in aaaa aa 2 forward))
    (check-equal? '((1 3 "aa") (3 5 "aa")) (search-test:scan-spans aaaa (search-test:scanned aaaa aa)))
    (check-equal? '(2 4 "aa") (find-in aaaa aa 2 forward))))

(test "backward, a lookahead or an assertion at the place reads the text after it"
  (check-equal? '(7 8 "o") (find-in b (rx "o(?= t)") 23 backward))
  (check-equal? '(3 4 "e") (find-in b (rx "e\\b") 13 backward))
  (check-equal? #f (find-in fb (rx "foo\\b") 4 backward))
  (check-equal? #f (find-in fb (rx "foo\\z") 4 backward))
  (check-equal? '(8 11 "foo") (find-in fb (rx "foo\\b") 11 backward)))

(test "a match runs across a node's edge as the text reads, and one touching an atom's text covers the atom"
  (let ([nodes (buffers:make "nodes" (page '() (para '() "first line\n") (para '() "second " (tag '()) " end\n")))])
    (check-equal? "first line\nsecond TAG end\n" (buffers:text-between (buffers:document nodes) 0 (end-of nodes)))
    (check-equal? '((8 21) (22 23) (22 27) (19 23))
                  (map (lambda (q) (let ([m (search:find nodes q 0 forward)]) (list (search:match-start m) (search:match-end m))))
                       (list (rx "line\\nsecond") (search:make-query "TAG") (search:make-query "AG end") (search:make-query "nd T"))))))

(test "a narrowing is seen text, so ^ matches at its start mid-line, in a find and a scan alike; a range seen from before its start does not"
  (let ([n (text-buffer "n" "xfoo foo\nfoo\n")] [caret (rx "^foo")])
    (check-equal? '(2 5 "foo") (find-in n caret 2 forward 2 9))
    (check-equal? '((2 5 "foo")) (search-test:scan-spans n (search-test:scanned n caret 2 9)))
    (check-equal? #f (find-in n caret 2 forward 2 9 1 14))
    (check-equal? '() (search-test:scan-spans n (search-test:scanned n caret 2 9 1 14)))
    (check-equal? #f (find-in n (rx "(?<=x)foo") 2 forward 2 9))
    (check-equal? '(2 5 "foo") (find-in n (rx "(?<=x)foo") 2 forward 2 9 1 14))))

(test "a match never runs past the range's end: a greedy one is cut there, and an assertion at the end reads on up to the seen text's end"
  (check-equal? '(1 3 "aa") (find-in aaaa (rx "a+") 1 forward 1 3 1 6))
  (let ([cut (lambda (text end) (find-in fb (rx text) 1 forward 1 end 1 (end-of fb)))])
    (check-equal? '(#f #f #f #f (1 4 "foo"))
                  (list (cut "\\bfoo\\b" 4) (cut "foo$" 4) (cut "foo\\z" 4) (cut "foo\\Z" 4) (cut "foo(?=bar)" 4)))
    (check-equal? '((8 11 "foo") (8 11 "foo") (12 15 "foo") (8 11 "foo"))
                  (list (cut "foo$" 11) (cut "\\bfoo\\b" 15) (cut "foo(?= )" 15) (cut "foo\\b" 15)))
    (check-equal? #f (find-in fb (search:make-query "foo" search:word) 1 forward 1 4 1 (end-of fb)))
    (check-equal? '(1 4 "foo") (cut "\\w+\\b" 4)))
  (let ([fz (text-buffer "fz" "fooz\n")])
    (check-equal? #f (find-in fz (rx "fo+\\B") 1 forward 1 3 1 (end-of fz)))))

(test "finds and a scan agree over a text of many pieces, for matches at pieces' edges and assertions at their starts"
  (let ([big (text-buffer "big" (apply string-append
                                   (map (lambda (k) (format "w~a x-y z ~a\n" k (if (= 0 (mod k 997)) "needle" "")))
                                        (iota 9000))))])
    (check (> (end-of big) 70000))
    (check-equal? '((10 #t) (899 #t) (9000 #t) (9000 #t) (10 #t))
                  (map (lambda (text)
                         (let* ([q (rx text)] [found (search-test:all-in big q)])
                           (list (length found) (equal? found (search-test:scan-spans big (search-test:scanned big q))))))
                       '("needle" "^w\\d+3 " "\\bx-y\\b" "(?<=-)y" "z needle\\n")))))

(test "a quit between pieces stops a long find"
  (let* ([slow (text-buffer "slow" (make-string 20000000 #\x))]
         [finder (spawn-task (lambda (restore) (search:find slow (rx "\\b\\w+-\\w+\\b") 0 forward)))]
         [reports (test-runner:reports-during
                    (lambda ()
                      (fork-task
                        (lambda (restore)
                          (let wait ([n 0])
                            (unless (or (eq? (task-state finder) 'running) (= n 30000))
                              (chez:sleep (make-time 'time-duration 1000000 0))
                              (wait (+ n 1))))
                          (chez:sleep (make-time 'time-duration 20000000 0))
                          (cancel-task finder)))
                      (check-raises cancelled? (test-runner:join finder))))])
    (check (for-all cancelled? reports))))

(test "find checks its arguments"
  (let ([q (search:make-query "one")])
    (check-equal? '(search:find "not a direction" (sideways))
                  (search-test:raised (lambda () (search:find b q 0 'sideways))))
    (check-equal? 'search:find (car (search-test:raised (lambda () (search:find b q 99 forward)))))))

(import (tuna) (test) (tables) (search) (search-test))

(define b (search-test:text-buffer "f" "aaaa one two one two\n"))

(define one (search:make-query "one"))

(define (literal-with filter text) (search:make-query text search:literal (search:case smart) (search:spaces literal) filter))

(test "a predicate of search:filters must accept a match, in a find, a scan and its count"
  (let ([not-first? (lambda (buffer start end) (> start 7))])
    (tables:set! search:filters not-first? #t)
    (check-equal? '((14 17 "one")) (search-test:all-in b one))
    (let ([s (search-test:scanned b one)])
      (check-equal? '(((14 17 "one")) 1) (list (search-test:scan-spans b s) (search:scan-count s)))
      (search:stop-scan! s))
    (tables:remove! search:filters not-first?)
    (check-equal? '((6 9 "one") (14 17 "one")) (search-test:all-in b one))))

(test "the query's filter and search:filters must both accept a match"
  (let ([not-first? (lambda (buffer start end) (> start 7))])
    (tables:set! search:filters not-first? #t)
    (check-equal? '() (search-test:all-in b (search:query-with-filter one (lambda (buffer start end) (< start 10)))))
    (tables:remove! search:filters not-first?)))

(test "past a refused match a find goes on from its end, so from inside it a find gives what a find from there gives, before and after a scan"
  (let ([aa (literal-with (lambda (buffer start end) (not (= start 1))) "aa")])
    (check-equal? '((3 5 "aa")) (search-test:all-in b aa))
    (check-equal? '(2 4 "aa") (search-test:find-in b aa 2 search-test:forward))
    (check-equal? '((3 5 "aa")) (search-test:scan-spans b (search-test:scanned b aa)))
    (check-equal? '(2 4 "aa") (search-test:find-in b aa 2 search-test:forward))))

(test "backward, the last match accepted, passing over refused ones nearer"
  (check-equal? '(10 13 "two")
                (search-test:find-in b (search:query-with-filter (search:make-query "two") (lambda (buffer start end) (not (= start 18))))
                                     (search-test:end-of b) search-test:backward)))

(test "past a refused empty match a find goes on one character further"
  (let ([empty (search:make-query "x*" search:regexp (search:case smart) (search:spaces literal) (lambda (buffer start end) (> start 3)))])
    (check-equal? '(4 4 "") (search-test:find-in b empty 1 search-test:forward))))

(test "a filter that raises is reported once per find or scan, and then accepts"
  (let* ([broken (lambda (buffer start end) (error 'broken "no answer"))]
         [q (search:query-with-filter one broken)]
         [found #f]
         [reports (search-test:reports-during (lambda () (set! found (search-test:all-in b q))))])
    (check-equal? '((6 9 "one") (14 17 "one")) found)
    (check-equal? '("no answer" "no answer") (map condition-message reports))
    (let* ([s #f] [reports (search-test:reports-during (lambda () (set! s (search-test:scanned b q))))])
      (check-equal? '((6 9 "one") (14 17 "one")) (search-test:scan-spans b s))
      (check-equal? '("no answer") (map condition-message reports)))))

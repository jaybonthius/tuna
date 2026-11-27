(import (tuna) (test) (test-runner) (buffers) (document) (search) (search-test))

(define needle (search:make-query "needle"))

(test "a scan reports the matches around its position first, and an index is known only once the text before it is covered"
  (let* ([b (search-test:text-buffer "s" (apply string-append (map (lambda (k) (format "line ~a has a needle\n" k)) (iota 9000))))]
         [end (search-test:end-of b)]
         [middle (search:match-start (search:find b (search:make-query "line 8000 ") 0 search-test:forward))]
         [first-update #f]
         [s (search:scan b needle 0 end middle
              (lambda (s)
                (unless first-update
                  (set! first-update
                    (list (search:scan-index s middle) (search:scan-index s end)
                          (> (search:match-start (car (search:scan-matches s middle end))) middle))))))])
    (check (search:scan? s))
    (test-runner:wait-until (lambda () (search:scan-done? s)))
    (check-equal? '(#f #f #t) first-update)
    (check-equal? (list 9000 8000 #t needle)
                  (list (search:scan-count s) (search:scan-index s middle) (search:scan-done? s) (search:scan-query s)))
    (check-equal? '((14 20 "needle") (34 40 "needle") (54 60 "needle"))
                  (map (lambda (m) (search-test:span b m)) (search:scan-matches s 1 60)))))

(test "after a batch that edits the buffer the scan starts again, its old matches following the edit meanwhile"
  (let* ([e (search-test:text-buffer "e" "aa needle bb needle\n")] [es (search-test:scanned e needle)])
    (buffers:replace! e 1 1 "needle ")
    (search-test:end-batch)
    (check-equal? '((11 17 "needle") (21 27 "needle"))
                  (map (lambda (m) (search-test:span e m))
                       (filter (lambda (m) (> (search:match-start m) 1)) (search:scan-matches es 0 (search-test:end-of e)))))
    (test-runner:wait-until (lambda () (= 3 (search:scan-count es))))
    (check-equal? '((1 7 "needle") (11 17 "needle") (21 27 "needle")) (search-test:scan-spans e es))))

(test "a stopped scan keeps its matches and follows no more edits"
  (let* ([e (search-test:text-buffer "stopped" "needle\n")] [es (search-test:scanned e needle)])
    (search:stop-scan! es)
    (buffers:replace! e 1 1 "needle ")
    (search-test:end-batch)
    (check-equal? #f (search:scan-answers? es needle))
    (check-equal? 1 (search:scan-count es))))

(test "a scan answers for another query only while it runs on the text it scanned and the two compile alike"
  (let* ([e (search-test:text-buffer "answers" "needle\n")] [es (search-test:scanned e needle)])
    (check-equal? '(#t #t #f)
                  (map (lambda (q) (search:scan-answers? es q))
                       (list (search:make-query "needle") (search:make-query "needle" search:regexp)
                             (search:make-query "needle" search:literal (search:case exact)))))
    (search:stop-scan! es)))

(buffers:define-kind rows (content nodes))
(define (row-text node) (string-append "row " (number->string (document:node-attribute node 'n)) "\n"))
(buffers:define-kind row (content atom) (text row-text))

(test "a scan of a region among many atoms gathers the atoms' texts near it, and further ones only when a match reaching the region's end reads on"
  (let* ([many (buffers:make "many" (apply rows '() (map (lambda (k) (row (list (cons 'n k)))) (iota 100000))))]
         [asked '()]
         [note-atoms (lambda (atom-texts doc start end) (set! asked (cons (list start end) asked)) (atom-texts doc start end))])
    (advice-add! buffers:atom-texts note-atoms)
    (check-equal? '((11 12 "row 10\n") (12 13 "row 11\n") (13 14 "row 12\n") (14 15 "row 13\n") (15 16 "row 14\n") (16 17 "row 15\n"))
                  (search-test:scan-spans many (search-test:scanned many (search:make-query "row 1[0-5]$" search:regexp) 10 20)))
    (check-equal? '((10 20)) (reverse asked))
    (set! asked '())
    (check-equal? '()
                  (search-test:scan-spans many
                    (search-test:scanned many (search:make-query "(?s)row 1[0-5]\\n.*row 99990" search:regexp) 10 20 10 (search-test:end-of many))))
    (check-equal? '((10 65556) (65556 100002)) (reverse asked))
    (advice-remove! buffers:atom-texts note-atoms)))

(test "a scan raises at once for a pattern PCRE2 refuses"
  (let ([e (search-test:text-buffer "refused" "x\n")])
    (check-raises search:pattern-error? (search:scan e (search:make-query "(x" search:regexp) 0 2 0 (lambda (s) (void))))))

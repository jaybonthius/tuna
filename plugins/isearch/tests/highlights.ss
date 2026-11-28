(import (tuna) (test) (test-runner) (test-user) (options) (layout) (layout-split) (views) (search) (isearch) (isearch-test))

(define here isearch-test:here)

(define faced isearch-test:faced)

(define with-setting isearch-test:with-setting)

(define other (test-user:open-client))

(define (at! p) (views:set-point! (isearch-test:view) p))

(define (others text n) (map (lambda (i) (list "match.other" text)) (iota n)))

(test "other matches are highlighted in the search's view for its client only, the current match in match"
  (with-setting isearch:lazy-highlight-no-delay-length 1
    (lambda ()
      (isearch-test:show! "h" "ab ab ab\nab\n")
      (test-user:press! "C-s a b")
      (isearch-test:wait-scan)
      (check-equal? (cons '("match" "ab") (others "ab" 3)) (faced (test-user:client)))
      (check-equal? '() (faced other))
      (test-user:press! "RET")
      (check-equal? '() (faced (test-user:client))))))

(test "with the lazy count on, the prompt starts with the match's number and the total, ? for a total the scan has not reached"
  (with-setting isearch:lazy-count #t
    (lambda ()
      (isearch-test:show! "h" "ab ab ab\nab\n")
      (test-user:press! "C-s a b C-s")
      (isearch-test:wait-scan)
      (check-equal? '(6 "2/4 I-search: ab" "ab") (here))
      (test-user:press! "RET")
      (let ([never-done (lambda (done? scan) #f)])
        (isearch-test:show! "c" "ab ab ab ab\n")
        (advice-add! search:scan-done? never-done)
        (test-user:press! "C-s a b C-s C-s")
        (check-equal? '(9 "3/? I-search: ab" "ab") (here))
        (test-user:press! "RET")
        (advice-remove! search:scan-done? never-done)))))

(test "with lazy-highlight-cleanup off the highlights stay after the search, for every client of the view, until clear-highlights or the next search"
  (with-setting isearch:lazy-highlight-cleanup #f
    (lambda ()
      (isearch-test:show! "h" "ab ab ab\nab\n")
      (test-user:press! "C-s a b RET")
      (test-runner:wait-until (lambda () (= 4 (length (faced (test-user:client))))))
      (check-equal? 4 (length (faced other)))
      (isearch:clear-highlights (isearch-test:view))
      (check-equal? '() (faced (test-user:client)))
      (at! 1)
      (test-user:press! "C-s a b RET")
      (test-runner:wait-until (lambda () (= 4 (length (faced other)))))
      (at! 1)
      (with-setting isearch:lazy-highlight-no-delay-length 1
        (lambda ()
          (test-user:press! "C-s b")
          (isearch-test:wait-scan)
          (test-runner:wait-until (lambda () (= 4 (length (faced (test-user:client))))))
          (check-equal? (list (cons '("match" "b") (others "b" 3)) '()) (list (faced (test-user:client)) (faced other)))
          (test-user:press! "RET")))
      (isearch:clear-highlights (isearch-test:view)))))

(test "under a short text the other matches wait for isearch:lazy-highlight-delay; the current match is drawn at once"
  (with-setting isearch:lazy-highlight-no-delay-length 5
    (lambda ()
      (isearch-test:show! "h" "ab ab ab\nab\n")
      (test-user:press! "C-s a")
      (check-equal? '(("match" "a")) (faced (test-user:client)))
      (test-runner:wait-until (lambda () (= 4 (length (faced (test-user:client))))))
      (check-equal? (cons '("match" "a") (others "a" 3)) (faced (test-user:client)))
      (test-user:press! "RET"))))

(test "a failing search keeps its last match drawn"
  (with-setting isearch:lazy-highlight-no-delay-length 1
    (lambda ()
      (isearch-test:show! "fl" "ab ab\n")
      (test-user:press! "C-s a b z")
      (check-equal? '(3 "Failing I-search: ab{z}" "ab") (here))
      (check (member '("match" "ab") (faced (test-user:client))))
      (check (isearch-test:cancelling! "C-g C-g")))))

(test "a repeat keeps the scan, so the count and the other matches stay; a new text makes a new scan"
  (options:set! isearch:lazy-highlight-no-delay-length 1)
  (with-setting isearch:lazy-count #t
    (lambda ()
      (isearch-test:show! "rp" "ab ab ab ab ab\n")
      (test-user:press! "C-s a b")
      (isearch-test:wait-scan)
      (let ([s1 (isearch:search-scan (isearch:current (test-user:client)))]
            [scan (lambda () (isearch:search-scan (isearch:current (test-user:client))))])
        (check-equal? '((3 "1/5 I-search: ab" "ab") 5) (list (here) (length (faced (test-user:client)))))
        (test-user:press! "C-s")
        (check-equal? (list '(6 "2/5 I-search: ab" "ab") 5 #t) (list (here) (length (faced (test-user:client))) (eq? s1 (scan))))
        (test-user:press! "C-s C-r")
        (check-equal? (list '(7 "3/5 I-search backward: ab" "ab") 5 #t) (list (here) (length (faced (test-user:client))) (eq? s1 (scan))))
        (test-user:press! "z")
        (check-equal? #f (eq? s1 (scan)))
        (test-user:press! "RET"))))
  (options:unset! isearch:lazy-highlight-no-delay-length))

(test "with isearch:lazy-highlight none, only the current match is drawn"
  (with-setting isearch:lazy-highlight 'none
    (lambda ()
      (with-setting isearch:lazy-highlight-no-delay-length 1
        (lambda ()
          (isearch-test:show! "nn" "abc ab abc ab\n")
          (test-user:press! "C-s a b c")
          (isearch-test:wait-scan)
          (check-equal? '(("match" "abc")) (faced (test-user:client)))
          (test-user:press! "RET"))))))

(test "with isearch:lazy-highlight all, every view of the buffer draws the matches and the current one"
  (with-setting isearch:lazy-highlight 'all
    (lambda ()
      (isearch-test:show! "al" "ab ab ab\n")
      (let ([first (isearch-test:view)])
        (layout-split:split-below #f)
        (let ([second (find (lambda (v) (and (not (eq? v first)) (eq? (views:buffer v) (views:buffer first)))) (layout:views))])
          (layout:select! first)
          (test-user:press! "C-s a b C-s")
          (isearch-test:wait-scan)
          (let ([drawn '(("match.other" "ab") ("match" "ab") ("match.other" "ab"))])
            (test-runner:wait-until (lambda () (equal? drawn (faced (test-user:client) first))))
            (check-equal? drawn (faced (test-user:client) second)))
          (test-user:press! "RET")
          (layout:select! second)
          (test-user:press! "C-x 0"))))))

(test "a match in a fold opens the fold while it is current and closes it again when the search moves on; the last match's fold stays open"
  (isearch-test:show! "f" "x one\ny one\nz one\n")
  (let ([v (isearch-test:view)])
    (views:fold! v 7 12)
    (test-user:press! "C-s o n e")
    (check-equal? '((6 "I-search: one" "one") ((7 . 12))) (list (here) (views:folds-at v 9)))
    (test-user:press! "C-s")
    (check-equal? '((12 "I-search: one" "one") ()) (list (here) (views:folds-at v 9)))
    (test-user:press! "C-s")
    (check-equal? '((18 "I-search: one" "one") ((7 . 12))) (list (here) (views:folds-at v 9)))
    (test-user:press! "RET")))

(test "M-s i makes the search pass over matches in folds"
  (isearch-test:show! "f" "x one\ny one\nz one\n")
  (let ([v (isearch-test:view)])
    (views:fold! v 7 12)
    (test-user:press! "C-s o n e M-s i C-s")
    (check-equal? '(18 "I-search: one" "one") (here))
    (test-user:press! "RET")
    (views:unfold! v 9)))

(test "with isearch:search-folds off, a search passes over a fold of its own view but not one of another view of the buffer"
  (isearch-test:show! "g" "x one\ny one\nz one\n")
  (let ([first (isearch-test:view)])
    (views:fold! first 7 12)
    (with-setting isearch:search-folds #f
      (lambda ()
        (test-user:press! "C-s o n e C-s")
        (check-equal? '(18 "I-search: one" "one") (here))
        (test-user:press! "RET")
        (layout-split:split-below #f)
        (let ([second (find (lambda (v) (and (not (eq? v first)) (eq? (views:buffer v) (views:buffer first)))) (layout:views))])
          (views:unfold! second 9)
          (layout:select! second)
          (views:set-point! second 1)
          (test-user:press! "C-s o n e C-s")
          (check-equal? 12 (views:point second))
          (test-user:press! "RET C-x 0"))))))

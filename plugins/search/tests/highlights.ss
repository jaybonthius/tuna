(import (tuna) (test) (test-user) (layout) (views) (faces) (search) (search-test))

(define other (test-user:open-client))

(define b (search-test:text-buffer "h" "ab-cd ef-gh ab-cd\n"))

(define v (layout:selected-view))

(views:set-buffer! v b)
(views:set-point! v (search-test:end-of b))

(define q (search:make-query "(\\w+)-(\\w+)" search:regexp))

(define s (search-test:scanned b q))

(define (view-element client)
  (let ([id (number->string (views:id v))])
    (find (lambda (e) (equal? id (test-user:element-attribute e "data-view")))
          (test-user:elements-with (test-user:screen client) "data-view"))))

(define (faced client)
  (test-user:settle)
  (map (lambda (e) (list (test-user:element-attribute e "data-face") (test-user:element-text e)))
       (test-user:elements-with (view-element client) "data-face")))

(define others '(("match.other" "ab-cd") ("match.other" "ef-gh") ("match.other" "ab-cd")))

(test "a highlight draws a scan's matches in one view for one client, in faces:match.other"
  (let ([h (search:highlight! v (test-user:client) s)])
    (check (search:highlight? h))
    (check-equal? others (faced (test-user:client)))
    (check-equal? '() (faced other))
    (search:end-highlight! h)))

(test "the current match is drawn in its face and its groups in search.group-1 and search.group-2, until it is cleared"
  (let ([h (search:highlight! v (test-user:client) s)])
    (search:set-current! h (search:find b q 7 search-test:forward) faces:match)
    (check-equal? '(("match.other" "ab-cd") ("match" "ef-gh") ("search.group-1" "ef") ("search.group-2" "gh") ("match.other" "ab-cd"))
                  (faced (test-user:client)))
    (search:set-current! h #f faces:match)
    (check-equal? others (faced (test-user:client)))
    (search:end-highlight! h)))

(test "with no scan a highlight draws its current match alone, and set-scan! gives it other matches"
  (let ([h (search:highlight! v (test-user:client) #f)])
    (search:set-current! h (search:find b q 0 search-test:forward) faces:match)
    (check-equal? '(("match" "ab-cd") ("search.group-1" "ab") ("search.group-2" "cd")) (faced (test-user:client)))
    (search:set-scan! h s)
    (check-equal? '(("match" "ab-cd") ("search.group-1" "ab") ("search.group-2" "cd") ("match.other" "ef-gh") ("match.other" "ab-cd"))
                  (faced (test-user:client)))
    (search:end-highlight! h)))

(test "a highlight for no client is drawn for every client that draws the view; an ended one draws nothing"
  (let ([all (search:highlight! v #f s)])
    (check-equal? others (faced other))
    (check-equal? others (faced (test-user:client)))
    (search:end-highlight! all)
    (check-equal? '() (faced other))
    (check-equal? '() (faced (test-user:client)))))

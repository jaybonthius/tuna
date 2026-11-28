(import (tuna) (test) (test-runner) (views) (haml) (web) (test-user) (views-test page))

(define desktop (views-test/page:open 400))
(define phone (views-test/page:open 200))

(define (client page) (views-test/page:client page))

(define rested '())

(define s
  (views:make-scroller
    (lambda (scroller c item align focus) (set! rested (cons (list c item align focus) rested)))))

(define (strip page)
  (web:send-screen! (client page) (haml (:div (views:draw-scroller s (client page) (views:axis row) "strip" "items"))) "strip")
  (car (test-user:elements (test-user:screen (client page)) "strip")))

(define (number e name) (string->number (test-user:element-attribute e name)))

(define (place-of page)
  (let ([e (strip page)])
    (list (number e "data-placement") (number e "data-place-item")
          (string->symbol (test-user:element-attribute e "data-place-align")) (number e "data-place-focus"))))

(define %reports 0)

(define (scrolled! page items whole . rest)
  (set! %reports (+ %reports 1))
  (web:post-input! (client page)
    (append `(("type" . "scroller") ("scroller" . ,(number (strip page) "data-scroller"))
              ("placement" . ,(car (place-of page))) ("report" . ,%reports)
              ("items" . ,(list->vector items)) ("whole" . ,(list->vector whole)) ("settled" . ,(pair? rest)))
            (if (pair? rest) `(("item" . ,(car rest)) ("align" . ,(cadr rest)) ("focus" . ,(caddr rest))) '())))
  (test-user:settle))

(views:place-scroller! s 4 (views:scroller-align nearest) 4)

(define d0 (place-of desktop))
(define p0 (place-of phone))

(test "a scroller keeps one place for every client, each placed under its own number, and draws what the page script needs"
  (check-equal? '(4 nearest 4) (cdr d0))
  (check-equal? '(4 nearest 4) (cdr p0))
  (check (not (= (car d0) (car p0))))
  (let ([e (strip desktop)])
    (check-equal? "row" (test-user:element-attribute e "data-axis"))
    (check-equal? "items" (test-user:element-text e)))
  (check-raises (test-runner:raised-with 'views:place-scroller! "not a scroller alignment") (views:place-scroller! s 4 'left 4))
  (check-raises (test-runner:raised-with 'views:draw-scroller "not an axis") (views:draw-scroller s (client desktop) 'diagonal "strip" "")))

(test "a report while scrolling tells only what is in view, and which items wholly, on that client"
  (scrolled! desktop '(4 5) '(4 5))
  (check-equal? '((4 5) #f ()) (list (views:scroller-in-view s (client desktop)) (views:scroller-in-view s (client phone)) rested))
  (check-equal? 1 (number (strip desktop) "data-reported"))
  (check-equal? #f (views:scroller-wholly-in-view s (client phone)))
  (scrolled! desktop '(4 5) '(4))
  (check-equal? '((4 5) (4)) (list (views:scroller-in-view s (client desktop)) (views:scroller-wholly-in-view s (client desktop))))
  (check-raises (test-runner:raised-with 'views:scroller-wholly-in-view "not a client") (views:scroller-wholly-in-view s 'desktop)))

(test "at rest the scroller takes the client's place: every other client is placed there, the one that scrolled is not, and the maker hears"
  (scrolled! desktop '(5 6) '(5 6) 5 "start" 6)
  (check-equal? 6 (views:scroller-focus s))
  (check-equal? (list (list (client desktop) 5 'start 6)) rested)
  (let ([d1 (place-of desktop)] [p1 (place-of phone)])
    (check-equal? (car d0) (car d1))
    (check (not (= (car p0) (car p1))))
    (check-equal? '(5 start 6) (cdr p1))))

(test "the same place again is no news, and a report under an older placement moves nothing"
  (scrolled! desktop '(5 6) '(5 6) 5 "start" 6)
  (check-equal? 1 (length rested))
  (web:post-input! (client phone)
    `(("type" . "scroller") ("scroller" . ,(number (strip phone) "data-scroller"))
      ("placement" . ,(car p0)) ("report" . 99) ("items" . #(1)) ("whole" . #(1)) ("settled" . #t)
      ("item" . 1) ("align" . "start") ("focus" . 1)))
  (test-user:settle)
  (check-equal? '(6 1 (1)) (list (views:scroller-focus s) (length rested) (views:scroller-in-view s (client phone)))))

(test "a report that is not one is refused"
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (web:post-input! (client phone) '(("type" . "scroller") ("scroller" . 1)))
    (test-user:settle)
    (advice-remove! report keep)
    (check-equal? '("not a scroller report") (map condition-message reported))))

(test "a removed client is forgotten, and a dropped scroller ignores reports and refuses use"
  (web:close-client! (client desktop))
  (check-equal? #f (views:scroller-in-view s (client desktop)))
  (views:drop-scroller! s)
  (check-raises (test-runner:raised-with 'views:scroller-focus "a dropped scroller") (views:scroller-focus s)))

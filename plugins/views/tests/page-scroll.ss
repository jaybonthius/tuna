(import (tuna) (test) (test-runner) (views) (buffers) (document) (options) (layout) (test-user)
        (views-test page) (views-test text))

(define desktop (views-test/page:open 400))

(define v (layout:selected-view))
(define b (buffers:make (buffers:free-name "long") (views-test/text:lines 300)))
(views:set-buffer! v b)

(define (line-start n) (views-test/text:line-start v n))

(define (start) (buffers:stop b 0))

(define (end) (line-start 301))

(define (field value key) (cdr (assoc key value)))

(define (asking keys answer)
  (let ([asked '()])
    (views-test/page:set-answer! desktop
      (lambda (name value)
        (when (equal? name "views-page") (set! asked (cons value asked)))
        (answer name value)))
    (test-user:press! (views-test/page:client desktop) keys)
    (reverse asked)))

(define (limit name value) '(("limit" . #t)))

(define (scrolled top start end) (views-test/page:report-answer desktop v top start end))

(define (kept top start end at place)
  (let ([report (scrolled top start end)])
    (lambda (name value)
      (cons* (cons "kept" (list (cons "at" at))) (cons "keptAt" place) (report name value)))))

(define (reports-during thunk)
  (map (lambda (c) (list (condition-who c) (condition-message c))) (test-runner:reports-during thunk)))

(test "C-v and M-v ask the page to keep views:page-overlap rows in view, as the view reads it, a count not below 0"
  (let ([overlaps (lambda (keys) (map (lambda (a) (field a "context")) (asking keys (scrolled 1 1 18))))])
    (check-equal? '(2) (overlaps "C-v"))
    (options:set! views:page-overlap 0)
    (check-equal? '(0) (overlaps "M-v"))
    (views:set-option! v views:page-overlap 5)
    (check-equal? '(5) (overlaps "C-v"))
    (views:remove-option! v views:page-overlap)
    (for-each (lambda (bad) (check-raises message-condition? (options:set! views:page-overlap bad)))
              (list -1 1.5 'two))
    (check-equal? 0 (views:page-overlap))
    (options:set! views:page-overlap 2)))

(test "with views:page-scroll-to-ends off, C-v where the view can go no further raises end of buffer and leaves point"
  (views:set-point! v (line-start 290))
  (check-equal? '((views:scroll-up "end of buffer")) (reports-during (lambda () (asking "C-v" limit))))
  (check-equal? (line-start 290) (views:point v)))

(test "with views:page-scroll-to-ends on, C-v where the view can go no further moves point to the end, and raises only from there; M-v the same at the start"
  (options:set! views:page-scroll-to-ends #t)
  (views:set-point! v (line-start 290))
  (check-equal? '() (reports-during (lambda () (asking "C-v" limit))))
  (check-equal? (end) (views:point v))
  (check-equal? '((views:scroll-up "end of buffer")) (reports-during (lambda () (asking "C-v" limit))))
  (views:set-point! v (line-start 5))
  (check-equal? '() (reports-during (lambda () (asking "M-v" limit))))
  (check-equal? (start) (views:point v))
  (check-equal? '((views:scroll-down "beginning of buffer")) (reports-during (lambda () (asking "M-v" limit))))
  (options:set! views:page-scroll-to-ends #f))

(test "with views:page-scroll-to-ends on, the ends of a narrowed view are its narrowing's"
  (options:set! views:page-scroll-to-ends #t)
  (views:narrow! v (line-start 10) (line-start 20))
  (views:set-point! v (line-start 12))
  (asking "C-v" limit)
  (check-equal? (line-start 20) (views:point v))
  (asking "M-v" limit)
  (check-equal? (line-start 10) (views:point v))
  (views:widen! v)
  (options:set! views:page-scroll-to-ends #f))

(test "with views:page-scroll-to-ends on and a count, C-v where the view can go no further moves point that many lines, as forward-line does"
  (options:set! views:page-scroll-to-ends #t)
  (views:set-point! v (+ (line-start 100) 2))
  (asking "C-u 3 C-v" limit)
  (check-equal? (line-start 103) (views:point v))
  (asking "C-u 3 M-v" limit)
  (check-equal? (line-start 100) (views:point v))
  (views:set-point! v (line-start 299))
  (asking "C-u 5 C-v" limit)
  (check-equal? (end) (views:point v))
  (options:set! views:page-scroll-to-ends #f))

(test "with views:page-scroll-keeps-row off, C-v asks the page to keep nothing"
  (check-equal? '(#f) (map (lambda (a) (field a "keep")) (asking "C-v" (scrolled 1 1 18)))))

(test "with views:page-scroll-keeps-row on, C-v asks the page to keep point's place, and point goes to the place the page answers"
  (options:set! views:page-scroll-keeps-row #t)
  (views:set-point! v (line-start 10))
  (check-equal? '(#t) (map (lambda (a) (field a "keep")) (asking "C-v" (kept 20 20 37 (line-start 30) '(("x" . 40.5) ("y" . 90))))))
  (check-equal? (line-start 30) (views:point v))
  (options:set! views:page-scroll-keeps-row #f))

(test "with views:page-scroll-keeps-row on, the next C-v or M-v in the view sends back the place the last one kept, and after another command none"
  (options:set! views:page-scroll-keeps-row #t)
  (views:set-point! v (line-start 10))
  (let ([place '(("x" . 40.5) ("y" . 90))])
    (asking "C-v" (kept 20 20 37 (line-start 30) place))
    (check-equal? (list place) (map (lambda (a) (field a "keep")) (asking "M-v" (kept 1 1 18 (line-start 10) place))))
    (check-equal? (line-start 10) (views:point v))
    (asking "C-l" (scrolled 1 1 18))
    (check-equal? '(#t) (map (lambda (a) (field a "keep")) (asking "C-v" (kept 20 20 37 (line-start 30) place)))))
  (options:set! views:page-scroll-keeps-row #f))

(test "views:scroll-forward! and views:scroll-backward! scroll by a page or a count, and raise at once at the limit even with views:page-scroll-to-ends on"
  (options:set! views:page-scroll-to-ends #t)
  (let ([asked '()])
    (views-test/page:set-answer! desktop
      (lambda (name value)
        (set! asked (cons (map (lambda (key) (field value key)) '("forward" "by")) asked))
        '(("limit" . #t))))
    (views:set-point! v (line-start 290))
    (check-raises views:scroll-limit? (views:scroll-forward! v))
    (check-raises views:scroll-limit? (views:scroll-backward! v 3))
    (check-raises views:scroll-limit? (views:scroll-forward! v -2))
    (check-raises views:scroll-limit? (views:scroll-backward! v -2))
    (check-equal? '((#t null) (#f 3) (#f 2) (#t 2)) (reverse asked))
    (check-equal? (line-start 290) (views:point v))
    (check-raises (test-runner:raised-with 'views:scroll-forward! "not a count or #f") (views:scroll-forward! v 'page)))
  (options:set! views:page-scroll-to-ends #f))

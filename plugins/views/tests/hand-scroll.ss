(import (tuna) (test) (views) (buffers) (options) (commands) (keys) (layout) (web) (test-user)
        (views-test page) (views-test text))

(options:set! views:scroll-margin 2 views:wrap-lines #f)

(define desktop (views-test/page:open 400))

(define (client page) (views-test/page:client page))
(define report! views-test/page:report!)
(define (line-of v p) (views-test/text:line-of v p))
(define (line-start v n) (views-test/text:line-start v n))

(define v (layout:selected-view))
(define b (buffers:make (buffers:free-name "rows") (views-test/text:lines 300)))
(buffers:with-buffer b (options:set-local! views:hand-scroll-moves-point #f))
(views:set-buffer! v b)

(define target 1)

(commands:define-command (go-to-target)
  "Moves point to the position the test chose."
  (views:set-point! (views:current) target))

(keys:bind! keys:global "C-c g" go-to-target)

(test "with hand-scroll-moves-point #f a hand scroll at rest places the view and leaves point where it was"
  (report! desktop v 1 0 #f)
  (report! desktop v 151 5 #f)
  (report! desktop v 151 5 #t)
  (check-equal? '(151 1) (list (line-of v (views:top v (client desktop))) (line-of v (views:point v)))))

(test "later reports leave point out of view, and the view does not follow it"
  (report! desktop v 151 5 #t (cons "pointVisible" #f))
  (report! desktop v 160 0 #t (cons "pointVisible" #f))
  (check-equal? '((new position 160) 160 1)
    (list (views-test/page:placement desktop v) (line-of v (views:top v (client desktop))) (line-of v (views:point v)))))

(test "a report from the leading page that finds point out of view without the hand, as after a resize, leaves the view where the hand put it"
  (report! desktop v 160 0 #f (cons "pointVisible" #f) (cons "hand" #f))
  (report! desktop v 160 0 #f (cons "pointVisible" #f) (cons "hand" #f) (cons "fraction" 0.1))
  (check-equal? '((same position) 1)
    (list (list-head (views-test/page:placement desktop v) 2) (line-of v (views:point v)))))

(test "C-v, a scroll command, still moves point into what the page then shows"
  (views-test/page:set-answer! desktop
    (lambda (name value)
      `(("report" . (("type" . "scroll") ("view" . ,(views:id v))
                     ("placement" . ,(string->number (test-user:element-attribute (views-test/page:shown-element desktop v)
                                                                                  "data-placement")))
                     ("version" . 0) ("top" . (("line" . 178))) ("spacer" . #f) ("fraction" . 0) ("left" . null)
                     ("past" . 0) ("sides" . #()) ("start" . (("line" . 180))) ("end" . (("line" . 195)))
                     ("shownStart" . null) ("shownEnd" . null)
                     ("atStart" . #f) ("atEnd" . #f) ("columns" . 80) ("rows" . 20) ("pointVisible" . #f)
                     ("wanted" . (("aboveLines" . 41) ("aboveChars" . 3280) ("belowLines" . 41) ("belowChars" . 3280)
                                  ("side" . 160)))
                     ("hand" . #t) ("settled" . #t) ("edge" . "top") ("report" . 500))))))
  (test-user:press! (client desktop) "C-v")
  (check-equal? '(178 180) (list (line-of v (views:top v (client desktop))) (line-of v (views:point v)))))

(test "a command that moves point makes the view follow it again"
  (set! target (line-start v 20))
  (test-user:press! (client desktop) "C-c g")
  (check-equal? '(new follow) (list-head (views-test/page:placement desktop v) 2)))

(test "with hand-scroll-moves-point #t, the default, a hand scroll at rest moves point into view"
  (buffers:with-buffer b (options:set-local! views:hand-scroll-moves-point #t))
  (report! desktop v 20 0 #f)
  (report! desktop v 100 0 #f)
  (report! desktop v 100 0 #t)
  (check-equal? 102 (line-of v (views:point v))))

(test "point the leading page lost by anything but the hand makes the view follow point, as Emacs's redisplay keeps point in view"
  (report! desktop v 100 0 #f (cons "pointVisible" #f) (cons "hand" #f) (cons "lost" #t))
  (check-equal? '(new follow) (list-head (views-test/page:placement desktop v) 2)))

(test "when the leading page closes, the next page drawn leads the view"
  (let* ([first (views-test/page:open 300)] [second (views-test/page:open 200)]
         [leads? (lambda (page) (and (test-user:element-attribute (views-test/page:view-element page v) "data-lead") #t))])
    (set! target (line-start v 40))
    (test-user:press! (client first) "C-c g")
    (check-equal? '(#t #f) (list (leads? first) (leads? second)))
    (web:close-client! (client first))
    (check-equal? #t (leads? second))))

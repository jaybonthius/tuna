(import (tuna) (test) (views) (buffers) (options) (test-user) (views-test page) (views-test text))

(options:set! views:scroll-margin 2 views:wrap-lines #f)

(define desktop (views-test/page:open 400))
(define c (views-test/page:client desktop))

(define (raised-with who message)
  (lambda (e)
    (and (who-condition? e) (eq? who (condition-who e))
         (message-condition? e) (string=? message (condition-message e)))))

(define b (buffers:make (buffers:free-name "anchored") (views-test/text:lines 300)))
(define v (views:make b))
(define a (views:add-anchor! v 7))

(test "an anchor follows edits and is found by its number"
  (check (views:anchor? a))
  (check-equal? v (views:anchor-view a))
  (check-equal? 7 (views:anchor-position a))
  (check-equal? a (views:find-anchor (views:anchor-id a)))
  (buffers:replace! b 1 1 "ab")
  (check-equal? 9 (views:anchor-position a))
  (views:move-anchor! a 12)
  (check-equal? 12 (views:anchor-position a))
  (views:move-anchor! a 9))

(test "an anchor is drawn as an empty element named by its number, before a cursor at the same position"
  (views:set-point! v 9)
  (let* ([e (views-test/page:view-element desktop v)]
         [classed (map (lambda (x) (test-user:element-attribute x "class")) (test-user:elements-with e "class"))]
         [anchor (car (test-user:elements e "view-anchor"))])
    (check-equal? (format "--views-anchor-name:--view-anchor-~a" (views:anchor-id a)) (test-user:element-attribute anchor "style"))
    (check-equal? "" (test-user:element-text anchor))
    (check (member "cursor primary" (member "view-anchor" classed)))))

(test "an anchor is drawn for a client when its view was drawn for it in this batch and the lines drawn hold the anchor"
  (test-user:settle)
  (check (not (views:anchor-drawn? a c)))
  (views-test/page:view-element desktop v)
  (check (views:anchor-drawn? a c))
  (let ([far (views:add-anchor! v (views-test/text:line-start v 280))])
    (views-test/page:view-element desktop v)
    (check (not (views:anchor-drawn? far c)))
    (views:scroll-to! v (views-test/text:line-start v 250) (views:align top))
    (test-user:settle)
    (check (not (views:anchor-drawn? far c)))
    (views-test/page:view-element desktop v)
    (check (views:anchor-drawn? far c))
    (views:remove-anchor! far)))

(test "an anchor goes when removed, removing it again does nothing, and it goes with its view's buffer"
  (let* ([far (views:add-anchor! v 20)] [far-id (views:anchor-id far)] [a-id (views:anchor-id a)])
    (views:remove-anchor! far)
    (views:remove-anchor! far)
    (check-equal? #f (views:find-anchor far-id))
    (check-raises (raised-with 'views:anchor-position "a removed anchor") (views:anchor-position far))
    (views:set-buffer! v (buffers:make (buffers:free-name "other") "x\n"))
    (check-equal? #f (views:find-anchor a-id))
    (check-raises (raised-with 'views:add-anchor! "not a position in the view's buffer") (views:add-anchor! v 99))))

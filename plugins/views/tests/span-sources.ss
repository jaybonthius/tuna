(import (tuna) (test) (test-runner) (views) (buffers) (document) (options) (tables) (test-user)
        (views-test page) (views-test text) (views-test md))

(options:set! views:scroll-margin 2 views:wrap-lines #f)

(buffers:define-layer marks (priority 1000))

(define desktop (views-test/page:open 400))
(define phone (views-test/page:open 200))

(define (client page) (views-test/page:client page))

(define (make-buffer name content) (buffers:make (buffers:free-name name) content))

(define (faced e)
  (map (lambda (f) (list (test-user:element-attribute f "data-face") (test-user:element-text f)))
       (test-user:elements-with e "data-face")))

(define (drawn page view) (views-test/page:view-element page view))

(define b (make-buffer "sourced" "alpha beta gamma\nbeta again\n"))
(define v (views:make b))
(define asked '())

(define (source view c start end)
  (set! asked (cons (list c start end) asked))
  (if (and (eq? view v) (eq? c (client desktop)))
      (list (list 7 11 '((face . match))) (list 18 22 '((face . match.other))))
      '()))

(test "a span source answers for one view and one client, asked for the run drawn for that client"
  (tables:set! views:span-sources source 1000)
  (set! asked '())
  (check-equal? '(("match" "beta") ("match.other" "beta")) (faced (drawn desktop v)))
  (check-equal? '() (faced (drawn phone v)))
  (check-equal? (list (list (client desktop) 1 29) (list (client phone) 1 29)) (reverse asked)))

(test "a view drawn for no client asks no source"
  (set! asked '())
  (check-equal? '() (faced (views-test/page:element-for-no-client v)))
  (check-equal? '() asked))

(test "of a source and a layer of one priority the source's span is inside, and of a lower priority outside"
  (buffers:add-span! (buffers:layer b marks) 1 12 '((face . keyword)))
  (let ([e (drawn desktop v)])
    (check-equal? '("match") (map (lambda (f) (test-user:element-attribute f "data-face"))
                                  (cdr (test-user:elements-with (car (test-user:elements-with e "data-face")) "data-face")))))
  (tables:set! views:span-sources source 10)
  (let* ([e (drawn desktop v)] [match (car (filter (lambda (f) (equal? "match" (test-user:element-attribute f "data-face")))
                                                     (test-user:elements-with e "data-face")))])
    (check-equal? '(("match" "beta") ("keyword" "beta")) (faced match)))
  (buffers:remove-span! (buffers:layer b marks) '((face . keyword)))
  (tables:set! views:span-sources source 1000))

(test "a source above priority 0 that the region reaches keeps its background"
  (views:set-mark! v 1)
  (views:set-point! v 13)
  (let ([e (drawn desktop v)])
    (check-equal? '(("match" "beta") ("match.other" "beta")) (faced e))
    (check-equal? '("match") (map (lambda (f) (test-user:element-attribute f "data-face")) (test-user:elements e "above-region"))))
  (views:set-mark! v 13))

(test "a source that raises, or returns what is not a list of spans, is reported, and the view still draws"
  (let ([broken (lambda (view client start end) (error 'broken "no spans here"))]
        [malformed (lambda (view client start end) '((1 2)))]
        [e #f])
    (tables:set! views:span-sources broken 5)
    (check-equal? '("no spans here") (map condition-message (test-runner:reports-during (lambda () (set! e (drawn desktop v))))))
    (check-equal? '(("match" "beta") ("match.other" "beta")) (faced e))
    (tables:remove! views:span-sources broken)
    (tables:set! views:span-sources malformed 5)
    (check-equal? '("a source returned what is not a list of spans")
                  (map condition-message (test-runner:reports-during (lambda () (set! e (drawn desktop v))))))
    (check-equal? '(("match" "beta") ("match.other" "beta")) (faced e))
    (tables:remove! views:span-sources malformed)))

(test "a source removed draws nothing more"
  (tables:remove! views:span-sources source)
  (check-equal? '() (faced (drawn desktop v))))

(test "a hand scroll, which runs no command, shows the spans of the run then drawn"
  (let* ([long (make-buffer "long" (views-test/text:lines 300))] [lv (views:make long)] [runs '()]
         [each-line (lambda (view client start end)
                      (set! runs (cons (list (views-test/text:line-of view start) (views-test/text:line-of view end)) runs))
                      (if (eq? view lv) (list (list start (+ start 4) '((face . match)))) '()))])
    (tables:set! views:span-sources each-line 1000)
    (views-test/page:report! desktop lv 1 0 #t)
    (drawn desktop lv)
    (check-equal? '(1 60) (car runs))
    (views-test/page:report! desktop lv 151 0 #t)
    (drawn desktop lv)
    (check-equal? '(110 193) (car runs))
    (tables:remove! views:span-sources each-line)))

(test "a span covering a node standing alone puts its face on the node's element"
  (let* ([pic (make-buffer "pic" (views-test/md:doc '() (views-test/md:heading '() "a\n") (views-test/md:image '((src . "a.png")))
                                                        (views-test/md:heading '() "b\n")))]
         [pv (views:make pic)]
         [cover (lambda (view client start end) (if (eq? view pv) (list (list 5 6 '((face . match)))) '()))]
         [image-node (lambda () (car (test-user:elements (drawn desktop pv) "whole")))])
    (tables:set! views:span-sources cover 1000)
    (check-equal? "match" (test-user:element-attribute (image-node) "data-face"))
    (tables:remove! views:span-sources cover)
    (check-equal? #f (test-user:element-attribute (image-node) "data-face"))))

(test "a span covering an atom standing alone gives the atom's element what views:span-properties gives the span, a class among them; a node with content is not marked"
  (tables:set! views:span-properties 'test-mark (lambda (v) (list (cons "data-test-mark" v) (cons "class" "test-marked"))))
  (let* ([pic (make-buffer "pic" (views-test/md:doc '() (views-test/md:heading '() "a\n") (views-test/md:image '((src . "a.png")))
                                                        (views-test/md:heading '() "b\n")))]
         [pv (views:make pic)]
         [n (document:length (buffers:document pic))]
         [cover (lambda (view client start end) (if (eq? view pv) (list (list 0 n '((face . match) (test-mark . "x")))) '()))]
         [marked (lambda () (filter (lambda (e) (test-user:element-attribute e "data-face")) (test-user:elements (drawn desktop pv) "node")))])
    (tables:set! views:span-sources cover 1000)
    (let ([nodes (marked)])
      (check-equal? '(("match" "x")) (map (lambda (e) (map (lambda (a) (test-user:element-attribute e a)) '("data-face" "data-test-mark"))) nodes))
      (check-equal? '("node whole test-marked") (map (lambda (e) (test-user:element-attribute e "class")) nodes)))
    (tables:remove! views:span-sources cover)
    (tables:remove! views:span-properties 'test-mark)
    (check-equal? '() (marked))))

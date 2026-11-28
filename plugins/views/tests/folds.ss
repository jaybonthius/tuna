(import (tuna) (test) (test-runner) (views) (buffers) (document) (hooks) (options) (test-user)
        (views-test page) (views-test md))

(options:set! views:scroll-margin 2 views:wrap-lines #f)

(define (bounds v) (call-with-values (lambda () (views:bounds v)) list))

(define (drawn-lines v)
  (filter (lambda (l) (equal? "line" (test-user:element-attribute l "class")))
          (test-user:elements (views-test/page:element-for-no-client v) "line")))

(define (line-texts v) (map test-user:element-text (drawn-lines v)))

(define (fold-marks v)
  (map (lambda (f)
         (list (string->number (test-user:element-attribute f "data-at"))
               (string->number (test-user:element-attribute f "data-to"))
               (test-user:element-text f)))
       (test-user:elements (views-test/page:element-for-no-client v) "fold")))

(define (make-text text) (buffers:make (buffers:free-name "notes") text))

(test "a fold hides its text, drawn as one mark joining the text around it, and a cursor passes over it in one step"
  (let* ([notes (make-text "one three\nfour five six\nseven\n")] [v (views:make notes)] [w (views:make notes)])
    (views:fold! v 4 14)
    (check-equal? '(#t #t #t #f) (map (lambda (p) (views:folded? v p)) '(4 9 14 15)))
    (check-equal? '(14 4 4) (list (views:next-stop v 4) (views:previous-stop v 14) (views:next-stop v 3)))
    (check-equal? '("one…r five six" "seven" "") (line-texts v))
    (check-equal? '((4 14 "…")) (fold-marks v))
    (check (not (views:folded? w 9)))))

(test "a fold follows edits: text typed before it moves it, and text typed at its start stays outside"
  (let* ([notes (make-text "one three\nfour five six\nseven\n")] [v (views:make notes)])
    (views:fold! v 4 14)
    (buffers:replace! notes 1 1 "0 ")
    (check-equal? '(#f #t #t) (map (lambda (p) (views:folded? v p)) '(5 6 16)))
    (buffers:replace! notes 6 6 "x")
    (check-equal? '(#f #t) (map (lambda (p) (views:folded? v p)) '(6 7)))))

(test "a cursor that ends a batch inside a fold opens it"
  (let ([v (views:make (make-text "one three\nfour five six\nseven\n"))])
    (views:fold! v 12 17)
    (views:set-point! v 14)
    (test-user:settle)
    (check (not (views:folded? v 14)))))

(test "unfold! opens every fold holding the position, and a fold goes when its text does"
  (let* ([notes (make-text "0 one three\nfour five six\nseven\n")] [v (views:make notes)])
    (views:fold! v 6 16)
    (views:fold! v 8 10)
    (views:unfold! v 9)
    (check (not (views:folded? v 9)))
    (check (not (views:folded? v 12)))
    (views:fold! v 2 4)
    (buffers:replace! notes 1 6 "")
    (check-equal? '(#f #f) (list (views:folded? v 1) (views:folded? v 2)))))

(test "a narrowed view draws and moves only within its bounds, while other views see all of the buffer"
  (let* ([notes (make-text "x three\nfour five six\nseven\n")] [v (views:make notes)] [w (views:make notes)])
    (views:narrow! v 15 26)
    (check-equal? '(15 26) (bounds v))
    (check-equal? 15 (views:point v))
    (check-equal? '(26 #f 25) (list (views:next-stop v 25) (views:previous-stop v 15) (views:next-stop v 24)))
    (views:set-point! v 2)
    (check-equal? 15 (views:point v))
    (check-equal? '("ive six" "sev") (line-texts v))
    (check-equal? "15" (test-user:element-attribute (car (drawn-lines v)) "data-at"))
    (check-equal? '(0 30) (bounds w))
    (buffers:replace! notes 15 15 "x")
    (buffers:replace! notes 27 27 "y")
    (check-equal? '(15 28) (bounds v))
    (views:widen! v)
    (check-equal? '(0 32) (bounds v))
    (check-raises (test-runner:raised-with 'views:narrow! "the start is after the end") (views:narrow! v 10 5))))

(test "a fold that ends inside a node's text joins the lines around it"
  (let ([t (views:make (make-text "one\ntwo\nthree\n"))])
    (views:fold! t 3 9)
    (check-equal? '("on…three" "") (line-texts t))))

(test "a fold across nodes stands where the first node it wholly folds was, and a cursor at its start rests there"
  (let ([across (views:make (buffers:make (buffers:free-name "across")
                              (views-test/md:doc '() (views-test/md:para '() "one\ntwo\n") (views-test/md:para '() "three\n")
                                                     (views-test/md:para '() "four\nfive\n"))))])
    (views:fold! across 6 21)
    (check-equal? '("one" "…" "our" "five") (line-texts across))
    (views:set-point! across 6)
    (check-equal? '("one" "…" "our" "five") (line-texts across))
    (check-equal? '((6 21 "…")) (fold-marks across))))

(test "a fold that ends at a node's closing ends its line there, so many hidden nodes draw as many lines as the page wants"
  (let* ([desktop (views-test/page:open 400)]
         [many (buffers:make (buffers:free-name "many")
                 (apply views-test/md:doc '()
                   (map (lambda (i) (views-test/md:para '() (format "head ~a\nbody\nbody\n" i))) (iota 2000))))]
         [v (views:make many)]
         [doc (buffers:document many)])
    (document:for-each-child (document:token doc 0) 1 (- (document:length doc) 1)
      (lambda (child at)
        (let* ([s (document:node-start child)]
               [text (document:text doc (+ s 1) (document:node-end child))]
               [newline (let loop ([i 0]) (if (char=? (string-ref text i) #\newline) i (loop (+ i 1))))])
          (views:fold! v (+ s 1 newline) (- (document:node-end child) 1)))))
    (let ([texts (map test-user:element-text
                   (filter (lambda (l) (equal? "line" (test-user:element-attribute l "class")))
                           (test-user:elements (views-test/page:view-element desktop v) "line")))])
      (check-equal? '(1 304 102 () (5694)) (views-test/page:drawn desktop v))
      (check-equal? "head 1…" (cadr texts))
      (check (not (member "head 1999…" texts))))))

(test "folds-at gives every fold holding a position, ends included, nested or touching; folded? whether any does"
  (let ([nest (views:make (make-text "abcdefghijklmnopqrstuvwxyz\n"))])
    (views:fold! nest 2 20)
    (views:fold! nest 5 10)
    (views:fold! nest 20 24)
    (check-equal? '(() ((2 . 20)) ((2 . 20) (5 . 10)) ((2 . 20) (5 . 10)) ((2 . 20)) ((2 . 20) (20 . 24)) ((20 . 24)) ())
      (map (lambda (p) (list-sort (lambda (a b) (< (car a) (car b))) (views:folds-at nest p))) '(1 2 7 10 15 20 24 25)))
    (check-equal? '(#f #t #t #f) (map (lambda (p) (views:folded? nest p)) '(1 2 22 25)))))

(test "fold-opened is told, after the draw, of the folds a draw opens around a cursor, inner first, with the buffer current"
  (let* ([nest (views:make (make-text "abcdefghijklmnopqrstuvwxyz\n"))]
         [opened '()]
         [entry (lambda (view start end)
                  (when (eq? view nest)
                    (set! opened (cons (list start end (buffers:current)) opened))))])
    (hooks:add! views:fold-opened entry)
    (views:fold! nest 2 20)
    (views:fold! nest 5 10)
    (views:fold! nest 20 24)
    (views:set-point! nest 7)
    (views-test/page:element-for-no-client nest)
    (check-equal? '(() ((20 . 24))) (map (lambda (p) (views:folds-at nest p)) '(7 22)))
    (test-runner:wait-until (lambda () (= 2 (length opened))))
    (check-equal? (list (list 5 10 (views:buffer nest)) (list 2 20 (views:buffer nest))) (reverse opened))
    (set! opened '())
    (views:reveal! nest 20 20)
    (check-equal? '() opened)
    (check-equal? '((20 . 24)) (views:folds-at nest 20))
    (views:reveal! nest 19 21)
    (check-equal? (list (list 20 24 (views:buffer nest))) opened)
    (check-equal? '() (views:folds-at nest 22))
    (set! opened '())
    (views:set-point! nest 1)
    (views:fold! nest 3 8)
    (views:unfold! nest 4)
    (test-user:settle)
    (check-equal? '() opened)
    (hooks:remove! views:fold-opened entry)))

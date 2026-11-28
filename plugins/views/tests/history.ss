(import (tuna) (test) (test-runner) (views) (buffers) (options) (test-user) (views-test page) (views-test text))

(options:set! views:scroll-margin 2 views:wrap-lines #f)

(define (names bs) (map buffers:name bs))

(define (make-buffer name content) (buffers:make (buffers:free-name name) content))

(define (bounds v) (call-with-values (lambda () (views:bounds v)) list))

(define desktop (views-test/page:open 400))

(test "a buffer shown again in a view comes back with its cursors, place, folds and narrowing, and its history holds the buffer left"
  (let* ([a (make-buffer "a" (views-test/text:lines 40))]
         [b (make-buffer "b" (views-test/text:lines 40))]
         [c (make-buffer "c" (views-test/text:lines 40))]
         [v (views:make a)])
    (views:set-point! v 30)
    (views:set-mark! v 20)
    (views:fold! v 50 60)
    (views:narrow! v 10 100)
    (views:scroll-to! v 40 (views:align top))
    (views:set-buffer! v b)
    (check-equal? 1 (views:point v))
    (check (not (views:folded? v 55)))
    (check-equal? (list a) (views:previous-buffers v))
    (views:set-buffer! v a)
    (check-equal? '(30 20 #t (10 100)) (list (views:point v) (views:mark v) (views:folded? v 55) (bounds v)))
    (check-equal? '(new top 6) (views-test/page:placement desktop v))
    (check-equal? (list b) (views:previous-buffers v))
    (views:set-buffer! v c)
    (buffers:replace! a 1 1 "xyz")
    (views:set-buffer! v a)
    (check-equal? '(33 23) (list (views:point v) (views:mark v)))))

(test "each view has its own place in a buffer, and a view that never showed it shows it at its last point"
  (let* ([a (make-buffer "a" (views-test/text:lines 40))]
         [b (make-buffer "b" (views-test/text:lines 40))]
         [c (make-buffer "c" (views-test/text:lines 40))]
         [v (views:make a)]
         [w (views:make b)])
    (views:set-point! v 33)
    (views:set-buffer! w a)
    (check-equal? '(33 33) (list (views:point v) (views:point w)))
    (views:set-point! w 12)
    (views:set-buffer! w b)
    (views:set-buffer! w a)
    (check-equal? '(33 12) (list (views:point v) (views:point w)))
    (views:set-point! v 50)
    (check-equal? 50 (views:last-point a))
    (views:set-point! w 18)
    (check-equal? 18 (views:last-point a))
    (let ([u (views:make c)])
      (views:set-buffer! u a)
      (check-equal? 18 (views:point u))
      (views:drop! u))
    (views:set-buffer! w c)
    (views:set-buffer! v c)
    (check-equal? 50 (views:last-point a))
    (views:set-last-point! a 70)
    (let ([x (views:make b)])
      (views:set-buffer! x a)
      (check-equal? 70 (views:point x)))
    (check-raises (test-runner:raised-with 'views:set-last-point! "not a position in the buffer") (views:set-last-point! a 100000))))

(test "an internal buffer has no last point and is never in a history"
  (let* ([a (make-buffer "a" "a\n")]
         [b (make-buffer "b" "b\n")]
         [inner (make-buffer " inner" "i\n")]
         [x (views:make b)])
    (views:set-buffer! x inner)
    (views:set-point! x 2)
    (views:set-buffer! x a)
    (check-equal? #f (views:last-point inner))
    (check-equal? (list b) (views:previous-buffers x))))

(test "previous-buffer! and next-buffer! walk the view's previous buffers, newest first, then the ones the view never showed"
  (let* ([p1 (make-buffer "p1" "1\n")]
         [p2 (make-buffer "p2" "2\n")]
         [p3 (make-buffer "p3" "3\n")]
         [h (views:make p1)])
    (views:set-buffer! h p2)
    (views:set-buffer! h p3)
    (check-equal? (list p2 p1) (views:previous-buffers h))
    (check-equal? (list p2 p1) (list (views:previous-buffer! h) (views:previous-buffer! h)))
    (check-equal? (list p2 p3) (views:previous-buffers h))
    (check-equal? (list p2 p3) (list (views:next-buffer! h) (views:next-buffer! h)))
    (let ([fresh (make-buffer "fresh" "f\n")])
      (buffers:move-to-front! fresh)
      (check-equal? fresh (views:next-buffer! h)))))

(test "past its own history previous-buffer! goes through the buffer list from its far end, never to an internal buffer"
  (let* ([a (make-buffer "a" "a\n")]
         [b (make-buffer "b" "b\n")]
         [lone (views:make (make-buffer "lone" "l\n"))])
    (buffers:move-to-front! a)
    (buffers:move-to-back! b)
    (check-equal? b (views:previous-buffer! lone))))

(test "a killed buffer leaves every history, and a view that showed it shows its own previous buffer"
  (let* ([a (make-buffer "a" "a\n")]
         [p1 (make-buffer "p1" "1\n")]
         [p2 (make-buffer "p2" "2\n")]
         [p3 (make-buffer "p3" "3\n")]
         [h (views:make p2)])
    (views:set-buffer! h p3)
    (views:set-buffer! h a)
    (views:set-buffer! h p1)
    (check-equal? (list a p3 p2) (views:previous-buffers h))
    (buffers:kill! p3)
    (check-equal? (list a p2) (views:previous-buffers h))
    (buffers:kill! p1)
    (check-equal? a (views:buffer h))))

(test "skipped-buffer-predicate passes over the buffers it accepts, for the reason it is given"
  (let* ([a (make-buffer "a" "a\n")]
         [b (make-buffer "b" "b\n")]
         [c (make-buffer "c" "c\n")]
         [s (views:make a)])
    (options:with ([views:skipped-buffer-predicate
                    (lambda (view buffer reason) (and (eq? reason (views:switch-reason previous)) (eq? buffer b)))])
      (views:set-buffer! s b)
      (views:set-buffer! s c)
      (check-equal? a (views:previous-buffer! s))
      (views:set-buffer! s b)
      (views:set-buffer! s c)
      (buffers:kill! c)
      (check-equal? b (views:buffer s)))))

(test "replace-buffer! shows the newest previous buffer and drops the one shown; with nothing to show it changes nothing"
  (let* ([r1 (make-buffer "r1" "r\n")]
         [b (make-buffer "b" "b\n")]
         [r (views:make r1)]
         [only (make-buffer " only" "o\n")]
         [q (views:make only)])
    (views:set-buffer! r b)
    (check-equal? r1 (views:replace-buffer! r))
    (check-equal? #f (memq b (views:previous-buffers r)))
    (options:with ([views:skipped-buffer-predicate (lambda (view buffer reason) #t)])
      (check-equal? #f (views:replace-buffer! q)))
    (check-equal? only (views:buffer q))))

(test "a preview shows a buffer as set-buffer! would, and its end puts back the buffer, the state and the history"
  (let* ([a (make-buffer "a" (views-test/text:lines 40))]
         [b (make-buffer "b" (views-test/text:lines 40))]
         [r1 (make-buffer "r1" "r\n")]
         [pv (views:make a)])
    (views:set-buffer! pv b)
    (views:set-point! pv 2)
    (views:preview-buffer! pv a)
    (check (views:previewing? pv))
    (views:preview-buffer! pv r1)
    (views:end-preview! pv)
    (check (not (views:previewing? pv)))
    (check-equal? (list b 2 (list a)) (list (views:buffer pv) (views:point pv) (views:previous-buffers pv)))
    (views:end-preview! pv)
    (check-equal? b (views:buffer pv))))

(test "a preview changes no buffer's last point"
  (let* ([a (make-buffer "a" (views-test/text:lines 40))]
         [b2 (make-buffer "b2" (views-test/text:lines 40))]
         [text-view (views:make b2)])
    (views:set-point! text-view 5)
    (views:set-buffer! text-view a)
    (views:set-point! text-view 18)
    (let ([help-view (views:make b2)])
      (views:set-point! help-view 30)
      (let ([before (list (views:last-point b2) (views:last-point a))])
        (check-equal? '(30 18) before)
        (views:preview-buffer! text-view b2)
        (check-equal? 5 (views:point text-view))
        (views:end-preview! text-view)
        (check-equal? before (list (views:last-point b2) (views:last-point a)))))))

(test "a view keeps its body size when it shows another buffer, until its page reports again"
  (let ([sized (views:make (make-buffer "sized" (views-test/text:lines 50)))])
    (views-test/page:report! desktop sized 1 0 #t)
    (check-equal? '(80 20) (call-with-values (lambda () (views:body-size sized (views-test/page:client desktop))) list))
    (views:set-buffer! sized (make-buffer "a" "a\n"))
    (check-equal? '(80 20) (call-with-values (lambda () (views:body-size sized (views-test/page:client desktop))) list))))

(test "the place kept for a buffer is the item at the top and the fraction above the edge, which every page puts back"
  (let* ([d (make-buffer "d" (views-test/text:lines 300))] [u (views:make d)])
    (views-test/page:report! desktop u 1 0 #f)
    (views-test/page:report! desktop u 151 5 #f)
    (views-test/page:report! desktop u 151 5 #t)
    (views:set-buffer! u (make-buffer "a" "a\n"))
    (views:set-buffer! u d)
    (check-equal? '(new position 151) (views-test/page:placement desktop u))
    (check-equal? "0.25" (test-user:element-attribute (views-test/page:view-element desktop u) "data-place-fraction"))))

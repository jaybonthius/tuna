(import (tuna) (test) (views) (buffers) (document) (options) (views-test page) (views-test text))

(options:set! views:scroll-margin 2 views:wrap-lines #f)

(define desktop (views-test/page:open 400))

(define (kind-of view) (list-head (views-test/page:placement desktop view) 2))

(define (end-of b) (- (document:length (buffers:document b)) 1))

(define (text-buffer name)
  (buffers:make (buffers:free-name name) (views-test/text:lines 3)))

(define (inserting-buffer name)
  (let ([b (text-buffer name)])
    (buffers:with-buffer b (options:set-local! views:point-after-insertion? #t))
    b))

(test "with point-after-insertion? set in a buffer, a point where text is inserted stays after it and the view follows it"
  (let* ([out (inserting-buffer "out")] [v (views:make out)] [w (views:make out)] [end (end-of out)])
    (views:set-point! v end)
    (check-equal? '((new follow) (same follow)) (list (kind-of v) (kind-of v)))
    (buffers:insert! out end "line 4\n")
    (check-equal? (+ end 7) (views:point v))
    (check-equal? 1 (views:point w))
    (check-equal? '(same follow) (kind-of v))
    (buffers:replace! out end (+ end 7) "line 4, again\n")
    (check-equal? (end-of out) (views:point v))))

(test "without the option a point stays before text inserted there, and the view does not move"
  (let* ([plain (text-buffer "plain")] [u (views:make plain)] [end (end-of plain)])
    (views:set-point! u end)
    (check-equal? '((new follow) (same follow)) (list (kind-of u) (kind-of u)))
    (buffers:insert! plain end "line 4\n")
    (check-equal? end (views:point u))
    (check-equal? '(same follow) (kind-of u))))

(test "a view the hand placed follows point again when text goes in at point with the option, and stays without it"
  (let* ([out (inserting-buffer "out")] [v (views:make out)] [plain (text-buffer "plain")] [u (views:make plain)])
    (views:set-point! v (end-of out))
    (views:set-point! u (end-of plain))
    (check-equal? '((new follow) (new follow)) (list (kind-of v) (kind-of u)))
    (views-test/page:report! desktop v 2 0 #t)
    (views-test/page:report! desktop u 2 0 #t)
    (check-equal? '((same position) (same position)) (list (kind-of v) (kind-of u)))
    (buffers:insert! out (views:point v) "line 6\n")
    (buffers:insert! plain (views:point u) "line 5\n")
    (check-equal? '((new follow) (same position)) (list (kind-of v) (kind-of u)))))

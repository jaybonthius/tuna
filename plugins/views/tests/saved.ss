(import (tuna) (test) (views) (buffers) (document) (options) (plugins) (test-user)
        (views-test page) (views-test md) (views-test fill))

(define (bounds v) (call-with-values (lambda () (views:bounds v)) list))

(define desktop (views-test/page:open 400))

(define notes (buffers:make "notes" "one two\nthree four\nfive\n"))
(define host (buffers:make "*host*" (views-test/md:doc '() (views:view '((view . 400) (buffer . "notes"))))))
(define v (views:atom-view (document:token (buffers:document host) 1)))
(define loose (views:make notes))
(define applied #f)

(test "a view an atom names by number is saved with its cursors, place, folds, narrowing and the plugin's options"
  (check-equal? 400 (views:id v))
  (views:set-point! v 10)
  (views:set-mark! v 3)
  (views:add-cursor! v 19)
  (views:fold! v 13 17)
  (views:narrow! v 1 20)
  (views:set-option! v views:wrap-lines #t)
  (views:set-option! v views:drawn-screens 1)
  (views:set-option! v views:cursor-visible #f)
  (views:set-option! v views-test/fill:column 50)
  (views:scroll-to! v 9 (views:align top))
  (set! applied (string->number (test-user:element-attribute (views-test/page:view-element desktop v) "data-placement")))
  (test-user:settle)
  (reload-modules! '((views)))
  (let ([v2 (views:find 400)])
    (check (not (eq? v v2)))
    (check-equal? #f (views:find (views:id loose)))
    (check-equal? notes (views:buffer v2))
    (check-equal? '(10 3 (10 19) 9) (list (views:point v2) (views:mark v2) (map views:cursor-point (views:cursors v2)) (views:top v2 #f)))
    (check-equal? '(#t (1 20)) (list (views:folded? v2 15) (bounds v2)))
    (check-equal? '(#t 1 70 #f)
      (views:with-view v2 (list (views:wrap-lines) (views:drawn-screens) (views-test/fill:column) (views:cursor-visible))))))

(test "a page compares placement numbers for equality, so a reload numbers them from another base, and the place comes back"
  ;; Reloading views reloads test-user and the pretend page, which import
  ;; it, so the clients opened before are gone.
  (let ([v2 (views:find 400)] [page (views-test/page:open 400)])
    (check (> (abs (- (string->number (test-user:element-attribute (views-test/page:view-element page v2) "data-placement"))
                      applied))
              1000000))
    (check-equal? '(new position 2) (views-test/page:placement (views-test/page:open 400) v2))))

(test "new views take numbers after the saved ones"
  (check (> (views:id (views:make notes)) 400)))

(test "a view whose buffer is not made yet draws empty, and shows it, where it was, once it is made"
  (reload-modules! '((buffers)))
  (let ([v3 (views:find 400)])
    (check-equal? '(#f 10) (list (views:buffer v3) (views:point v3)))
    (let ([e (views-test/page:element-for-no-client v3)])
      (check-equal? "view" (test-user:element-attribute e "class"))
      (check-equal? "" (test-user:element-text e)))
    (set! notes (buffers:make "notes" "one two\nthree four\nfive\n"))
    (check-equal? (list notes 10 3 #t) (list (views:buffer v3) (views:point v3) (views:mark v3) (views:folded? v3 15)))))

(test "a view keeps the name its buffer has now"
  (buffers:rename! notes "todo")
  (test-user:settle)
  (reload-modules! '((views)))
  (check-equal? notes (views:buffer (views:find 400))))

(test "saved positions beyond a shorter buffer's end are clamped"
  (reload-modules! '((buffers)))
  (buffers:make "todo" "one\n")
  (let ([v4 (views:find 400)])
    (check-equal? '(5 (5 5) (1 6)) (list (views:point v4) (map views:cursor-point (views:cursors v4)) (bounds v4)))))

(test "writing the views after a batch that moved point makes no batch of its own"
  (let* ([v4 (views:find 400)] [batches 0] [counting (lambda (ended) (set! batches (+ batches 1)) (ended))])
    (define (batches-during thunk)
      (set! batches 0)
      (advice-add! batch-ended counting)
      (spawn-task (lambda (restore) (thunk)))
      (test-user:settle)
      (test-user:settle)
      (advice-remove! batch-ended counting)
      batches)
    (check-equal? (batches-during void) (batches-during (lambda () (views:set-point! v4 2))))))

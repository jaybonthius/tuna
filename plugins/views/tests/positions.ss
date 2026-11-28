(import (tuna) (test) (test-runner) (views) (buffers) (document) (options) (tables) (views-test md))

(define (root-of v) (document:token (buffers:document (views:buffer v)) 0))

(define (make-buffer name content) (buffers:make (buffers:free-name name) content))

(define (pictures)
  (views:make (make-buffer "pictures"
                (views-test/md:doc '() (views-test/md:heading '() "a\n") (views-test/md:image '()) (views-test/md:image '())
                                       (views-test/md:heading '() "b\n")))))

(test "where point is reads as its line, and its line and column while column-number is on, as Emacs's column-number-mode"
  (let ([v (views:make (make-buffer "lines" "abc\ndef\n"))])
    (views:set-point! v 6)
    (check-equal? "L2" (views:describe-line (root-of v) v))
    (check-equal? "L2" (views:with-view v (views:describe-at-point v)))
    (options:with ([views:column-number #t])
      (check-equal? "2:1" (views:describe-line (root-of v) v)))))

(test "within a node its own lines and columns count, from the node's start"
  (let* ([page (make-buffer "page" (views-test/md:doc '() (views-test/md:para '() "one\n") (views-test/md:para '() "two\nthree\n")))]
         [w (views:make page)])
    (views:set-point! w 13)
    (options:with ([views:column-number #t])
      (check-equal? "2:1" (views:describe-line (document:enclosing (buffers:document page) 13) w))
      (check-equal? "3:1" (views:describe-line (root-of w) w)))))

(test "the kind at point describes it: the atom right after point, else the innermost node holding point whose kind has an entry, else the root's line"
  (let* ([page (make-buffer "page" (views-test/md:doc '() (views-test/md:para '() "one\n") (views-test/md:para '() "two\nthree\n")))]
         [w (views:make page)]
         [x (pictures)])
    (tables:set! views:position-describers views-test/md:para (lambda (node view) (format "para at ~a" (document:node-start node))))
    (tables:set! views:position-describers views-test/md:image (lambda (node view) "an image"))
    (views:set-point! w 13)
    (check-equal? "para at 7" (views:describe-at-point w))
    (views:set-point! x 4)
    (check-equal? "an image" (views:describe-at-point x))
    (views:set-point! x 2)
    (options:with ([views:column-number #t])
      (check-equal? "1:0" (views:describe-at-point x)))
    (tables:remove! views:position-describers views-test/md:para)
    (tables:remove! views:position-describers views-test/md:image)))

(test "a describer's #f shows nothing, and a key that is no kind's constructor matches nothing"
  (let ([x (pictures)])
    (views:set-point! x 2)
    (tables:set! views:position-describers views-test/md:doc (lambda (node view) #f))
    (tables:set! views:position-describers (lambda (attributes) 'heading) (lambda (node view) "never"))
    (check-equal? #f (views:describe-at-point x))
    (tables:remove! views:position-describers views-test/md:doc)
    (check-equal? "L1" (views:describe-at-point x))))

(test "position-description is read in the view, so a buffer's local value applies"
  (let* ([x (pictures)] [b (views:buffer x)])
    (views:set-point! x 2)
    (check-equal? "L1" (views:with-view x ((views:position-description) x)))
    (buffers:with-buffer b (options:set-local! views:position-description (lambda (view) "page 1 of 1")))
    (check-equal? "page 1 of 1" (views:with-view x ((views:position-description) x)))
    (buffers:with-buffer b (options:set-local! views:position-description #f))
    (check-equal? #f (views:with-view x (views:position-description)))))

(test "a view with no buffer describes nothing"
  (let* ([holder (make-buffer "holder" (views-test/md:doc '() (views:view '((buffer . "nowhere")))))]
         [empty (views:atom-view (document:token (buffers:document holder) 1))])
    (check-equal? #f (views:describe-at-point empty))
    (check-raises (test-runner:raised-with 'views:describe-line "not a view")
      (views:describe-line (document:token (buffers:document holder) 0) 'v))))

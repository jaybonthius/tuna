(import (tuna) (test) (test-user) (layout) (layout-split) (layout-tabs) (views) (buffers) (tables)
        (layout-split-test parts))

(define atom layout-split-test/parts:atom)
(define named layout-split-test/parts:named)
(define outline layout-split-test/parts:outline)
(define raised-with layout-split-test/parts:raised-with)
(define set-parts! layout-split-test/parts:set-parts!)

(define (name-of d) (if (vector? d) (cdr (assq 'buffer (vector-ref d 1))) (cons (car d) (map name-of (cddr d)))))

(define (shape) (name-of (layout-split-test/parts:tree)))

(define placements
  (list (cons "*echo*" (layout-split:display-at-side (layout:direction down) 90 'content '((locked . #t))))
        (cons "*explorer*" (layout-split:display-at-side (layout:direction left) 50 '(columns 30)))
        (cons "*outline*" (layout-split:display-at-side (layout:direction right) 60 '(columns 24)))))

(define (permutations l)
  (if (null? l)
      '(())
      (apply append (map (lambda (x) (map (lambda (p) (cons x p)) (permutations (remove x l)))) l))))

(define (start!)
  (set-parts! (layout-split:container '((direction . row)) (atom (views:make (named "notes.org"))) (atom (views:make (named "*pi*")))))
  (layout:select! (car (layout:views))))

(define (place-all! order)
  (for-each (lambda (p) ((cdr p) (named (car p)))) order)
  (shape))

(define user '(layout:level (layout-split:container "notes.org" "*pi*")))

(define all-placed
  '(layout:level (layout-split:container (layout-split:container "*explorer*" (layout:level (layout-split:container "notes.org" "*pi*")) "*outline*") "*echo*")))

(test "parts placed at the sides make one tree whatever the order, by depth, and removing them in any order gives back the user's windows"
  (for-each
    (lambda (order)
      (start!)
      (check-equal? all-placed (place-all! order)))
    (permutations placements))
  (for-each
    (lambda (order)
      (start!)
      (place-all! placements)
      (for-each (lambda (p) (layout:delete-part! (layout:view-node (layout:find-view (named (car p)))))) order)
      (check-equal? user (shape)))
    (permutations placements)))

(test "a part placed deeper goes nearer the edge, and of two at one depth on one side the later sits nearer it"
  (start!)
  (place-all! placements)
  ((layout-split:display-at-side (layout:direction down) 100 'content) (named "*minibuffer*"))
  ((layout-split:display-at-side (layout:direction left) 50 '(columns 20)) (named "*bookmarks*"))
  (check-equal? '(layout:level
                  (layout-split:container
                    (layout-split:container "*bookmarks*" "*explorer*" (layout:level (layout-split:container "notes.org" "*pi*")) "*outline*")
                    "*echo*" "*minibuffer*"))
                (shape)))

(test "the user's windows are the level the walk reaches through splits; a level made inside tabs is never taken for them"
  (let ([t1 (views:make (named "notes.org"))] [t2 (views:make (named "*pi*"))])
    (set-parts! (layout-tabs:container '() (atom t1) (layout:level '() (atom t2))))
    (layout:select! t1)
    ((layout-split:display-at-side (layout:direction down) 90 'content) (named "*echo*"))
    (check-equal? '(layout:level (layout-split:container (layout:level (layout-tabs:container "notes.org" (layout:level "*pi*"))) "*echo*"))
                  (shape))))

(test "a placed part keeps its size; the user may split it, and the new view is not placed, so a display may choose it"
  (let ([t1 (views:make (named "notes.org"))])
    (set-parts! (atom t1))
    (layout:select! t1)
    (let ([echo ((layout-split:display-at-side (layout:direction down) 90 'content) (named "*echo*"))])
      (layout:select! echo)
      (layout-split:split-view! echo (layout-split:direction row))
      (check-equal? '(layout:level (layout-split:container (layout:level "notes.org") (layout-split:container "*echo*" "*echo*"))) (shape))
      (let ([shown (layout:use-other-view (named "mail"))])
        (check-equal? "mail" (layout-split-test/parts:name-of shown))
        (check (not (eq? shown echo)))
        (check-equal? '("notes.org" "*echo*" "mail") (map layout-split-test/parts:name-of (layout:views)))))))

(test "a plugin removes its part with delete-part!, as the page's on-unload example does, and the layout is what it was before the part came"
  (start!)
  (let ([before (layout-split-test/parts:tree)] [echo-buffer (named " *Echo Area*")])
    (layout:display-buffer echo-buffer (layout-split:display-at-side (layout:direction down) 90 'content '((locked . #t))))
    (let ([x (layout:display-buffer (named "*explorer*") (layout-split:display-at-side (layout:direction left) 50 '(columns 30)))])
      (layout:delete-part! (layout:view-node x)))
    (let ([v (layout:find-view echo-buffer)])
      (when v (layout:delete-part! (layout:view-node v))))
    (check-equal? before (layout-split-test/parts:tree))))

(define (explorer? b) (string=? (buffers:name b) "*explorer*"))

(test "a display rule sends a part elsewhere; find-view finds a view shown or hidden, which the action reuses, where reuse-view sees only those shown"
  (start!)
  (tables:set! layout:display-rules explorer? (layout-split:display-at-side (layout:direction right) 50 '(columns 30)))
  (let ([x (layout:display-buffer (named "*explorer*") (layout-split:display-at-side (layout:direction left) 50 '(columns 30)))])
    (check-equal? '(layout:level (layout-split:container (layout:level (layout-split:container "notes.org" "*pi*")) "*explorer*")) (shape))
    (test-user:press! "C-u C-x 1")
    (check-equal? '("notes.org") (map layout-split-test/parts:name-of (layout:views)))
    (check (eq? x (layout:find-view (views:buffer x))))
    (check-equal? #f (layout:reuse-view (views:buffer x)))
    (check (eq? x ((layout-split:display-at-side (layout:direction left) 50 '(columns 30)) (views:buffer x))))
    (test-user:press! "C-x 1")
    (check-equal? #f (layout:find-view (named "nowhere"))))
  (tables:remove! layout:display-rules explorer?))

(test "display-at-side checks its arguments"
  (check-raises (raised-with 'layout-split:display-at-side "not a direction") (layout-split:display-at-side 'north 50 'content))
  (check-raises (raised-with 'layout-split:display-at-side "not a real number") (layout-split:display-at-side (layout:direction left) 'deep 'content))
  (check-raises (raised-with 'layout-split:display-at-side "not a fraction, (columns n), (lines n) or content")
                (layout-split:display-at-side (layout:direction left) 50 'big))
  (check-raises (raised-with 'layout-split:display-at-side "an attribute the action sets itself")
                (layout-split:display-at-side (layout:direction left) 50 'content '((depth . 3))))
  (check-raises (raised-with 'layout-split:display-at-side "not an association list of attributes")
                (layout-split:display-at-side (layout:direction left) 50 'content '(locked)))
  (check-raises (raised-with 'layout-split:display-at-side "not a buffer")
                ((layout-split:display-at-side (layout:direction left) 50 'content) "mail")))

(test "the action runs on the main thread only"
  (let ([result #f])
    (join-task
      (fork-task
        (lambda (restore)
          (set! result (guard (c [(who-condition? c) (list (condition-who c) (condition-message c))]) ((cdar placements) (named "*echo*")))))))
    (check-equal? '(layout:find-view "not on the main thread") result)))

(import (tuna) (test) (test-runner) (test-user) (layout) (layout-split) (views) (buffers) (commands)
        (layout-test parts))

(define atom layout-test/parts:atom)
(define name-of layout-test/parts:name-of)
(define selected-name layout-test/parts:selected-name)

(define (named name) (buffers:make (buffers:free-name name) (string-append name "\n")))

(define (names vs) (map name-of vs))

(define (place-prompt! b)
  (layout:display-buffer b
    (layout-split:display-at-side (layout:direction down) 100 'content '((locked . #t) (other-view . #t)))))

(define one #f)
(define two #f)
(define three #f)

(define (start-row!)
  (set! one (views:make (named "one")))
  (set! two (views:make (named "two")))
  (set! three (views:make (named "three")))
  (layout-test/parts:set-parts! (layout-split:container '((direction . row)) (atom one) (atom two) (atom three))))

(test "other-views gives the level's views after the selected one, then the parts that set other-view, then the level's views before"
  (start-row!)
  (layout:select! one)
  (check-equal? (list two three) (layout:other-views))
  (let ([prompt (place-prompt! (named "*prompt*"))])
    (layout:select! two)
    (check-equal? (list three prompt one) (layout:other-views))
    (layout:delete-part! (layout:view-node prompt))))

(test "C-x o takes a count, back for a negative one, and C-x O goes back"
  (start-row!)
  (let ([prompt (place-prompt! (named "*prompt*"))])
    (layout:select! two)
    (test-user:press! "C-u 2 C-x o")
    (check (eq? prompt (layout:selected-view)))
    (test-user:press! "C-x O")
    (check (eq? three (layout:selected-view)))
    (test-user:press! "C-u - C-x o")
    (check (eq? two (layout:selected-view)))
    (layout:delete-part! (layout:view-node prompt))))

(test "a part outside the level that sets other-view joins C-x o's cycle, locked or not, and from it C-x o goes back into the level"
  (start-row!)
  (layout:delete-part! (layout:view-node three))
  (layout:select! one)
  (let ([prompt (place-prompt! (named "*prompt*"))] [seen '()])
    (do ([k 0 (+ k 1)]) ((= k 4))
      (test-user:press! "C-x o")
      (set! seen (cons (layout:selected-view) seen)))
    (check-equal? (list two prompt one two) (reverse seen))
    (layout:delete-part! (layout:view-node prompt))
    (test-user:press! "C-x o")
    (check (eq? one (layout:selected-view)))))

(test "from a waiting prompt the other views are the level's from the first, a nested level counting as its view selected last"
  (start-row!)
  (let ([prompt (place-prompt! (named "*prompt*"))])
    (layout:select! prompt)
    (check-equal? (list one two three) (layout:other-views)))
  (let ([inner-a (views:make (named "inner-a"))] [inner-b (views:make (named "inner-b"))] [prompt (views:make (named "*prompt-2*"))])
    (layout-test/parts:set-parts!
      (layout-split:container '((direction . column))
        (layout:level '()
          (layout-split:container '((direction . row))
            (atom one)
            (layout:level '() (layout-split:container '((direction . column)) (atom inner-a) (atom inner-b)))))
        (atom prompt '(depth . 100) '(locked . #t) '(other-view . #t))))
    (layout:select! inner-b)
    (layout:select! one)
    (check-equal? (list inner-b prompt) (layout:other-views))
    (layout:select! prompt)
    (check-equal? (list one inner-b) (layout:other-views))
    (check (eq? one (layout:other-view-for-scrolling)))
    (layout:select! inner-b)
    (check (eq? prompt (layout:other-view-for-scrolling)))))

(test "the view C-M-v scrolls is the first other view showing a buffer that is not internal, so never a waiting prompt"
  (start-row!)
  (let ([prompt (views:make (named " *Minibuf-test*"))])
    (layout-test/parts:set-parts!
      (layout-split:container '((direction . column))
        (layout:level '() (atom one))
        (atom prompt '(depth . 100) '(locked . #t) '(other-view . #t))))
    (layout:select! one)
    (check-equal? (list prompt) (layout:other-views))
    (check-raises (test-runner:raised-with 'layout:other-view-for-scrolling "no other view")
                  (layout:other-view-for-scrolling))))

(define scrolled '())

(define (note-scroll scroll . args)
  (set! scrolled (cons (views:current) scrolled))
  (apply scroll args))

(test "C-M-v, C-M-V and C-M-L run views' scroll and recenter commands in the other view, and the selection stays"
  (start-row!)
  (layout:select! one)
  (for-each (lambda (command) (advice-add! command note-scroll))
            (list views:scroll-up views:scroll-down views:recenter-top-bottom))
  (set! scrolled '())
  (test-user:press! "C-M-v")
  (test-user:press! "C-M-V")
  (test-user:press! "C-M-L")
  (for-each (lambda (command) (advice-remove! command note-scroll))
            (list views:scroll-up views:scroll-down views:recenter-top-bottom))
  (check-equal? (list two two two) scrolled)
  (check (eq? one (layout:selected-view))))

(import (tuna) (test) (test-user) (layout) (layout-split) (views) (buffers) (commands) (options)
        (layout-split-test parts))

(define atom layout-split-test/parts:atom)
(define outline layout-split-test/parts:outline)
(define set-parts! layout-split-test/parts:set-parts!)

(define (named name) (buffers:make (buffers:free-name name) (string-append name "\n")))

(define (name-of v) (layout-split-test/parts:name-of v))

(define size (cons 100 30))

(define (sized body-size view client) (values (car size) (cdr size)))

(advice-add! views:body-size sized)

(define text (views:make (named "text")))

(define (alone!)
  (set-parts! (atom text))
  (layout:select! text))

(test "layout-split makes display-pop-up the display action when it loads"
  (check (eq? layout-split:display-pop-up (layout:display-action))))

(test "too small either way, a view alone in its level splits below; the new view's history is empty, and displaying again reuses it"
  (alone!)
  (set! size (cons 100 30))
  (let* ([b (named "*Help*")] [help (layout:display-buffer b)])
    (check-equal? (list 'layout:level (list 'column (name-of text) (buffers:name b))) (outline))
    (check-equal? '() (views:previous-buffers help))
    (check (eq? help (layout:display-buffer b)))
    (check (eq? text (layout:selected-view)))
    (let ([other (named "*Other*")])
      (check (eq? help (layout:display-buffer other)))
      (check-equal? (list 'layout:level (list 'column (name-of text) (buffers:name other))) (outline)))))

(test "a view wide enough splits beside, one tall enough below first, by the thresholds"
  (for-each
    (lambda (width height direction)
      (alone!)
      (set! size (cons width height))
      (let ([b (named "*Shown*")])
        (layout:display-buffer b)
        (check-equal? (list 'layout:level (list direction (name-of text) (buffers:name b))) (outline))))
    '(170 170) '(30 90) '(row column))
  (options:set! layout-split:split-width-threshold 80 layout-split:split-height-threshold #f)
  (alone!)
  (set! size (cons 90 90))
  (let ([b (named "*Side*")])
    (layout:display-buffer b)
    (check-equal? (list 'layout:level (list 'row (name-of text) (buffers:name b))) (outline)))
  (options:unset! layout-split:split-width-threshold layout-split:split-height-threshold))

(test "a locked view is never split, nor counted, so the only other view of the level splits"
  (let ([locked (views:make (named "*Locked*"))])
    (set-parts! (layout-split:container '((direction . row)) (atom text) (atom locked '(locked . #t))))
    (layout:select! text)
    (set! size (cons 90 30))
    (let ([b (named "*Beside locked*")])
      (layout:display-buffer b)
      (check-equal? (list 'layout:level (list 'row (list 'column (name-of text) (buffers:name b)) (name-of locked))) (outline)))))

(test "with no view to split, it takes the view of the level whose previous buffers hold the buffer, before the view selected least recently"
  (let* ([tall (named "*Tall*")] [b (views:make (named "b"))] [c (views:make (named "c"))])
    (views:set-buffer! b tall)
    (views:set-buffer! b (named "b2"))
    (set-parts! (layout-split:container '((direction . row)) (atom text) (atom b) (atom c)))
    (layout:select! c)
    (layout:select! b)
    (layout:select! text)
    (set! size (cons 90 30))
    (check (eq? b (layout:display-buffer tall)))))

(test "a part placed at a side is never split: from it, the buffer goes to the user's windows"
  (alone!)
  (let ([explorer (layout:display-buffer (named "*explorer*") (layout-split:display-at-side (layout:direction left) 50 '(columns 30)))])
    (layout:select! explorer)
    (let ([b (named "*From explorer*")])
      (check (eq? text (layout:display-buffer b)))
      (check-equal? (list 'layout:level (list 'row (name-of explorer) (list 'layout:level (buffers:name b)))) (outline)))
    (layout:select! text)
    (set! size (cons 90 30))
    (let ([made (layout:display-buffer (named "*Made*"))])
      (layout:select! made)
      (commands:run layout:quit-view)
      (check-equal? (list 'layout:level (list 'row (name-of explorer) (list 'layout:level (name-of text)))) (outline)))))

(test "while inhibit-same-view? holds, a second view of the selected view's buffer is split off"
  (alone!)
  (set! size (cons 100 30))
  (let ([v (parameterize ([layout:inhibit-same-view? #t]) (layout:display-buffer (views:buffer text)))])
    (check (not (eq? v text)))
    (check-equal? (list 'layout:level (list 'column (name-of text) (name-of text))) (outline))))

(test "without a client's measurement no threshold holds, and only a view alone in its level splits"
  (advice-remove! views:body-size sized)
  (set-parts! (layout-split:container '((direction . row)) (atom text) (atom (views:make (named "two")))))
  (layout:select! text)
  (let ([b (named "*Unmeasured*")])
    (layout:display-buffer b)
    (check-equal? (list 'layout:level (list 'row (name-of text) (buffers:name b))) (outline)))
  (alone!)
  (let ([b (named "*Unmeasured*")])
    (layout:display-buffer b)
    (check-equal? (list 'layout:level (list 'column (name-of text) (buffers:name b))) (outline))))

(test "a configuration's own display action wins, and unloading layout-split takes its setting back"
  (options:set! layout:display-action layout-split:display-right)
  (check (eq? layout-split:display-right (layout:display-action)))
  (options:unset! layout:display-action)
  (check (eq? layout-split:display-pop-up (layout:display-action)))
  (unload-owner! (module-owner '(layout-split)))
  (check (eq? layout:use-other-view (layout:display-action))))

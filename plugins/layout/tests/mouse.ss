(import (tuna) (test) (test-runner) (test-user) (layout) (layout-split) (views) (buffers) (document) (keys) (commands)
        (layout-test parts) (layout-test boxes))

(define atom layout-test/parts:atom)

(define notes (buffers:make "notes" "one\ntwo\n"))
(define a (views:make (buffers:make "first" "")))
(define b (views:make notes))
(define c (views:make notes))

(layout-test/parts:set-parts!
  (layout-split:container '((direction . row)) (layout-test/boxes:box '() (atom b) (atom c)) (atom a)))
(layout:select! a)

(define echo (layout-test/parts:place-echo! (buffers:make "*Echo*" "")))

(define (start-of v) (document:node-start (layout:view-node v)))

(define (box-start) (- (start-of b) 1))

(define (click! class at) (test-user:click-element! (layout-test/parts:marked-element class at)))

(define pressed 0)

(commands:define-command (count-press) "Counts presses that reach the global keymap." (set! pressed (+ pressed 1)))

(keys:bind! keys:global "<down-mouse-1>" count-press)

(test "the screen's element names the layout's own view, and each view atom's element names the atom's range in the layout"
  (test-user:settle)
  (let* ([sxml (test-user:screen)] [screen (car (test-user:elements sxml "layout-screen"))])
    (check-equal? (number->string (views:id layout:screen-view)) (test-user:element-attribute screen "data-view"))
    (check-equal? (number->string (buffers:version layout:buffer)) (test-user:element-attribute screen "data-version"))
    (check-equal? (number->string (views:shown-count layout:screen-view)) (test-user:element-attribute screen "data-showing"))
    (check-equal? (map (lambda (v) (list (number->string (start-of v)) (number->string (document:node-end (layout:view-node v)))))
                       (list b c a echo))
                  (map (lambda (e) (list (test-user:element-attribute e "data-at") (test-user:element-attribute e "data-to")))
                       (test-user:elements sxml "layout-view"))))
  (check (eq? layout:buffer (views:buffer layout:screen-view)))
  (check-equal? #f (layout:view-node layout:screen-view)))

(test "the layout's keymap takes the layout's clicks, after the kinds' keymaps"
  (check (eq? layout:keymap (car (layout:container-keymaps (test-user:client) (views:%make-posn layout:screen-view 4))))))

(test "a click on a view atom's element selects its view, on a container's the container's view selected last, and the press reaches nothing"
  (set! pressed 0)
  (test-user:settle)
  (click! "layout-view" (start-of c))
  (check (eq? c (layout:selected-view)))
  (layout:select! a)
  (test-user:settle)
  (click! "box" (box-start))
  (check (eq? c (layout:selected-view)))
  (layout:select! b)
  (layout:select! a)
  (test-user:settle)
  (click! "box" (box-start))
  (check (eq? b (layout:selected-view)))
  (check-equal? 0 pressed))

(test "a click on a locked part selects nothing"
  (layout:select! c)
  (test-user:settle)
  (click! "layout-view" (start-of echo))
  (check (eq? c (layout:selected-view))))

(test "a click on a part closed since its screen was drawn is stale"
  (layout:select! a)
  (test-user:settle)
  (let ([drawn (layout-test/parts:view-element b)])
    (layout:delete-part! (layout:view-node b))
    (check-equal? '((#f "Stale click: what was clicked is gone"))
                  (test-runner:shown-reports-during (lambda () (test-user:click-element! drawn))))
    (check (eq? a (layout:selected-view)))))

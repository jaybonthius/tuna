(import (tuna) (test) (test-runner) (test-user) (layout) (layout-split) (views) (buffers) (document) (web))

(define reply (lambda (question) 'null))

(define page
  (test-user:open-client (lambda (name value) (if (equal? name "drag-edge") (reply value) 'null))))

(define (change index old new) (list (cons "index" index) (cons "old" old) (cons "new" new)))

(define (fields c) (list (layout:drag-change-index c) (layout:drag-change-old c) (layout:drag-change-new c)))

(define (restores) (filter (lambda (call) (equal? (car call) "layout-drag-restore")) (test-user:take-page-calls! page)))

(define (fresh name) (views:make (or (buffers:find name) (buffers:make name (string-append name "\n")))))

(define (atom view . attributes)
  (views:view (cons* (cons 'view (views:id view)) (cons 'buffer (buffers:name (views:buffer view))) attributes)))

(define (set-parts! part)
  (let ([n (document:length (buffers:document layout:buffer))])
    (buffers:replace! layout:buffer 1 (- n 1) (document:from-datum part)))
  (test-user:settle))

(define a (fresh "a"))
(define b (fresh "b"))
(define c (fresh "c"))

(define (split!)
  (set-parts! (layout-split:container '((direction . column)) (atom c)
                (layout-split:container '((direction . row)) (atom a) (atom b))))
  (layout:select! a)
  (document:enclosing (buffers:document layout:buffer) (document:node-start (layout:view-node a))))

(define (split-now) (document:enclosing (buffers:document layout:buffer) (document:node-start (layout:view-node a))))

(define (ask! part answer indexes store!)
  (set! reply (lambda (question) answer))
  (test-user:take-page-calls! page)
  (layout:ask-drag 'drag! page part "drag-edge" '(("at" . 1)) indexes store!))

(test "ask-drag gives store! the part as it is now and the parts the page changed, their lengths exact"
  (let ([stored #f] [part (split!)])
    (ask! part (vector (change 0 300 340.5) (change 1 300 259.5)) '(0 1)
          (lambda (now changes) (set! stored (list (document:node-start now) (map fields changes)))))
    (check-equal? (list (document:node-start (split-now)) '((0 300 681/2) (1 300 519/2))) stored)
    (check-equal? '() (restores))))

(test "an edit beside the part during the drag moves it, and store! is given it where it is now"
  (let ([stored #f] [part (split!)])
    (set! reply (lambda (question)
                  (layout:set-part-attribute! (layout:view-node c) 'weight 3)
                  (vector (change 0 300 340))))
    (layout:ask-drag 'drag! page part "drag-edge" '() '(0) (lambda (now changes) (set! stored (document:node-start now))))
    (check-equal? (document:node-start (split-now)) stored)))

(test "a part edited during the drag is refused: store! is not called, and the page puts its lengths back"
  (let ([called #f] [part (split!)])
    (set! reply (lambda (question)
                  (layout:set-part-attribute! (layout:view-node b) 'weight 3)
                  (vector (change 0 300 340))))
    (test-user:take-page-calls! page)
    (check-raises (lambda (e) (and (error? e) (eq? 'drag! (condition-who e))
                                   (equal? "the layout changed during the drag" (condition-message e))))
                  (layout:ask-drag 'drag! page part "drag-edge" '() '(0) (lambda (now changes) (set! called #t))))
    (check (not called))
    (check-equal? 1 (length (restores)))))

(test "a page that answers nothing or no parts stores nothing, and is not told to restore"
  (let ([called #f] [part (split!)])
    (ask! part 'null '(0) (lambda (now changes) (set! called #t)))
    (check-equal? '() (restores))
    (ask! part (vector) '(0) (lambda (now changes) (set! called #t)))
    (check-equal? '() (restores))
    (check (not called))))

(test "a malformed answer raises not a drag answer under the caller's name, and the page puts its lengths back"
  (let ([part (split!)])
    (for-each
      (lambda (answer)
        (check-raises (lambda (e) (and (error? e) (eq? 'drag! (condition-who e)) (equal? "not a drag answer" (condition-message e))))
                      (ask! part answer '(0 1) (lambda (now changes) (void))))
        (check-equal? 1 (length (restores))))
      (list "parts" (vector "part") (vector (change 0 -1 100)) (vector (change 0 100 0)) (vector (change 5 100 200))
            (vector (change 0 100 200) (change 0 100 150))))))

(test "a raise from store! has the page put its lengths back, and goes on"
  (let ([part (split!)])
    (check-raises (lambda (e) (equal? "refused" (condition-message e)))
                  (ask! part (vector (change 0 100 200)) '(0) (lambda (now changes) (error 'store! "refused"))))
    (check-equal? 1 (length (restores)))))

;; A stop passes every handler, so only a winder tells the page.
(test "a drag whose task is stopped has the page put its lengths back, and a pause on the way tells it nothing"
  (let* ([part (split!)] [paused #f]
         [t (begin
              (set! reply (lambda (question) (vector (change 0 300 340))))
              (test-user:take-page-calls! page)
              (spawn-task
                (lambda (restore)
                  (layout:ask-drag 'drag! page part "drag-edge" '() '(0)
                    (lambda (now changes)
                      (set! paused #t)
                      (suspend (lambda (resume) (void))))))))])
    (test-runner:wait-until (lambda () (and paused (eq? 'paused (task-state t)))))
    (test-user:settle)
    (check-equal? '() (restores))
    (stop-task t)
    (test-runner:wait-until (lambda () (eq? 'done (task-state t))))
    (test-user:settle)
    (check-equal? 1 (length (restores)))))

(test "ask-drag checks its caller's name, client, part, indexes and store!"
  (let ([part (split!)])
    (check-raises assertion-violation? (layout:ask-drag "drag!" page part "drag-edge" '() '(0) void))
    (check-raises assertion-violation? (layout:ask-drag 'drag! 'page part "drag-edge" '() '(0) void))
    (check-raises assertion-violation? (layout:ask-drag 'drag! page 'part "drag-edge" '() '(0) void))
    (check-raises assertion-violation? (layout:ask-drag 'drag! page part "drag-edge" '() '(a) void))
    (check-raises assertion-violation? (layout:ask-drag 'drag! page part "drag-edge" '() '(0) 'store))))

(test "pressed-part raises for a procedure that is no container kind, whatever the press names"
  (for-each
    (lambda (container)
      (check-raises (lambda (e) (and (assertion-violation? e) (eq? 'layout:pressed-part (condition-who e))))
                    (layout:pressed-part (list "<mouse-1>" #t) container)))
    (list car views:view 'split)))

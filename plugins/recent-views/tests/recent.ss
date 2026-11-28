(import (tuna) (test) (test-user) (test-runner) (layout) (layout-split) (recent-views) (views) (buffers) (document)
        (keys) (options) (timers) (editing))

(options:set! recent-views:delay 1)
(keys:bind! keys:global "s-o" recent-views:select-recent-view)

(define (atom view)
  (views:view (list (cons 'view (views:id view)) (cons 'buffer (buffers:name (views:buffer view))))))

(define (named name) (views:make (buffers:make (buffers:free-name name) (string-append name "\n"))))

(define (selected) (substring (buffers:name (views:buffer (layout:selected-view))) 0 1))

;; The selected view gets its tick when recent-views' timer fires, which
;; is the only timer started after the plugins loaded.
(define loaded-timers (timers:live))

(define (pause!) (test-runner:wait-until (lambda () (for-all (lambda (t) (memq t loaded-timers)) (timers:live)))))

(define (start!)
  (let ([a (named "a")] [b (named "b")] [c (named "c")])
    (let ([n (document:length (buffers:document layout:buffer))])
      (buffers:replace! layout:buffer 1 (- n 1)
        (document:from-datum (layout-split:container '((direction . row)) (atom a) (atom b) (atom c)))))
    (layout:select! a)
    (test-user:press! "C-x o")
    (pause!)
    (test-user:press! "C-x o")
    (pause!)
    (list a b c)))

(test "s-o goes back to the view selected before; after the delay ended the cycle, it goes back again, so it toggles two views"
  (start!)
  (check-equal? "c" (selected))
  (test-user:press! "s-o")
  (check-equal? "b" (selected))
  (pause!)
  (test-user:press! "s-o")
  (check-equal? "c" (selected)))

(test "pressed again within the delay it goes on through the cycle, each view once, then starts a new one"
  (start!)
  (let* ([x (begin (test-user:press! "s-o") (selected))]
         [y (begin (test-user:press! "s-o") (selected))]
         [z (begin (test-user:press! "s-o") (selected))])
    (check-equal? '("b" "a" "c") (list x y z))))

(test "the views a quick run of C-x o passes get no tick: only where it stops does"
  (start!)
  (test-user:press! "C-x o C-x o")
  (check-equal? "b" (selected))
  (pause!)
  (test-user:press! "s-o")
  (check-equal? "c" (selected)))

(test "with a prefix argument, the view selected least recently"
  (start!)
  (test-user:press! "C-x o C-x o")
  (pause!)
  (test-user:press! "s-o")
  (pause!)
  (test-user:press! "C-u s-o")
  (check-equal? "a" (selected)))

(test "another command between two presses ends the cycle and ticks the view selected then"
  (start!)
  (test-user:press! "s-o")
  (check-equal? "b" (selected))
  (test-user:press! "C-x o")
  (check-equal? "c" (selected))
  (test-user:press! "s-o")
  (check-equal? "b" (selected)))

(test "each view s-o passes is recorded in the buffer order"
  (start!)
  (let ([order (lambda () (map (lambda (b) (substring (buffers:name b) 0 1))
                               (filter (lambda (b) (memv (string-ref (buffers:name b) 0) '(#\a #\b #\c))) (buffers:all))))])
    (test-user:press! "s-o")
    (check-equal? "b" (car (order)))
    (test-user:press! "s-o")
    (check-equal? '("a" "b") (list-head (order) 2))))

(test "a view selected by code gets no tick until a command ends and the delay passes after it"
  (let ([a (car (start!))])
    (layout:select! a)
    (pause!)
    (test-user:press! "C-x o")
    (test-user:press! "s-o")
    (check-equal? "c" (selected))
    (layout:select! a)
    (test-user:press! "C-a")
    (pause!)
    (test-user:press! "C-x o")
    (test-user:press! "s-o")
    (check-equal? "a" (selected))))

(test "a view selected by a click gets its tick once the delay passes, as one selected by a key"
  (let ([c (caddr (start!))])
    (test-user:press! "C-x o")
    (pause!)
    (test-user:click! c 0)
    (check-equal? "c" (selected))
    (pause!)
    (test-user:press! "C-x o")
    (test-user:press! "s-o")
    (check-equal? "c" (selected))))

(test "with no other view, s-o does nothing"
  (let ([a (named "a")])
    (let ([n (document:length (buffers:document layout:buffer))])
      (buffers:replace! layout:buffer 1 (- n 1) (document:from-datum (atom a))))
    (layout:select! a)
    (test-user:press! "s-o")
    (check (eq? a (layout:selected-view)))))

(test "the delay is a finite number of seconds, not below 0"
  (for-each
    (lambda (v) (check-raises (lambda (e) (message-condition? e)) (options:set! recent-views:delay v)))
    (list +inf.0 -1 'soon))
  (check-equal? 1 (recent-views:delay)))

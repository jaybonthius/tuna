(import (tuna) (test) (test-user) (test-runner) (options) (hooks) (commands) (web) (keys) (views) (buffers) (kill-ring) (undo)
        (editing) (scene) (quits)
        (rename (only (chezscheme) sleep) (sleep chez:sleep)))

(define refusals
  '("end of buffer" "beginning of buffer" "the previous command was not a yank" "no two characters to transpose"
    "the mark is not set, so there is no region"))

;; A user's C-g reaches Tuna on the server's thread while keys run, so a
;; quit lands inside whatever key's command is running then.
(define (storm! quit! thunk)
  (let* ([quitting #t] [stopped #f] [others '()]
         [note-report (lambda (next c) (unless (cancelled? c) (set! others (cons (scene:condition-text c) others))))]
         [until (+ (real-time) 1500)]
         [rounds 0])
    (advice-add! report note-report)
    (fork-task
      (lambda (restore)
        (let loop ()
          (if quitting
              (begin
                (quit!)
                (chez:sleep (make-time 'time-duration 500000 0))
                (loop))
              (set! stopped #t)))))
    (let loop ()
      (when (< (real-time) until)
        (thunk)
        (set! rounds (+ rounds 1))
        (loop)))
    (set! quitting #f)
    (test-runner:wait-until (lambda () stopped))
    (test-user:settle)
    (advice-remove! report note-report)
    (values rounds others)))

;; A command a quit stops never gets to after-command.
(define (stopped-during thunk)
  (let* ([begun 0] [ended 0]
         [note-begun (lambda (command) (set! begun (+ begun 1)))]
         [note-ended (lambda (command) (set! ended (+ ended 1)))])
    (hooks:add! commands:before-command note-begun)
    (hooks:add! commands:after-command note-ended)
    (call-with-values thunk
      (lambda results
        (hooks:remove! commands:after-command note-ended)
        (hooks:remove! commands:before-command note-begun)
        (apply values (- begun ended) results)))))

(define (press-quit!) (web:post-input! (test-user:client) '(("type" . "key") ("name" . "C-g") ("quit" . #t))))

(define (on-stops? b)
  (for-all (lambda (c) (eqv? (buffers:stop b (views:cursor-point c)) (views:cursor-point c))) (views:cursors (scene:view))))

(test "reloading the plugin keeps its commands and bindings and starts its passing state afresh"
  (scene:show! "alpha beta gamma" 1)
  (test-user:press! "M-d")
  (reload-modules! '((editing)))
  (test-user:press! "M-d")
  (check-equal? '((" gamma" ((1 #f))) (" beta")) (list (scene:state) (scene:kills 1)))
  (test-user:press! "C-y")
  (reload-modules! '((editing)))
  (check-equal? '((editing:yank-pop "the previous command was not a yank")) (scene:press-reports! "M-y"))
  (test-user:press! "M-f x")
  (check-equal? '(" beta gammax" ((13 #f))) (scene:state)))

(test "quits landing in typing, killing and yanking at three cursors leave every cursor on a stop, an edit still clearing every view's marks, and the history whole"
  (scene:with-setting editing:delete-selection #t
    (lambda ()
      (let ([storm (scene:show! "alpha beta\ngamma delta\nepsilon zeta\n" 1 12 24)])
        ;; The yanks grow the text with every round, and how many rounds run
        ;; depends on the machine, so the history is unbounded to keep the
        ;; first state.
        (buffers:with-buffer storm (options:set-local! undo:limit (greatest-fixnum)))
        (let-values ([(stopped rounds others)
                      (stopped-during
                        (lambda ()
                          (storm! press-quit!
                            (lambda ()
                              (for-each test-user:press!
                                '("a" "S-<left>" "b" "C-SPC" "M-b" "M-w" "C-y" "M-y" "C-k" "C-y" "DEL" "M-f" "C-t" "M-u" "C-n" "C-a"))))))])
          (check (> rounds 10))
          (check (> stopped 10))
          (check-equal? '() (remp (lambda (m) (member m refusals)) others)))
        (check (on-stops? storm))
        (let ([other (views:make storm)])
          (views:set-mark! other 2)
          (test-user:press! "C-SPC x")
          (check-equal? '(#f #f) (list (views:mark (scene:view)) (views:mark other)))
          (views:drop! other))
        (undo:go-to! storm 0)
        (check-equal? "alpha beta\ngamma delta\nepsilon zeta\n" (scene:text))
        (check (for-all string? (map kill-ring:text (kill-ring:entries)))))))
  (scene:take-said!))

(test "reloading the plugin in the middle of a drag ends the drag, and the next press starts afresh"
  (scene:show! "alpha beta gamma\ndelta epsilon\n" 1)
  (scene:mouse! "down" 2)
  (scene:mouse! "move" 5)
  (reload-modules! '((editing)))
  (scene:mouse! "move" 9)
  (check-equal? '((5 2)) (scene:cursors))
  (scene:mouse! "down" 7)
  (scene:mouse! "move" 11)
  (scene:mouse! "drag" 11)
  (check-equal? '((11 7)) (scene:cursors)))

(test "quits landing in presses, moves, drags and clicks leave one cursor on a stop, at most one drag keymap, and clicks working"
  (let ([b (scene:show! "alpha beta gamma\ndelta epsilon\n" 1)])
    (buffers:with-buffer b
      (options:set-local! undo:limit (greatest-fixnum))
      (options:set-local! editing:delete-active-region #f))
    (let ([requests (quits:requests)])
      (let-values ([(rounds others)
                    (storm! (let ([test-task (current-task)]) (lambda () (quits:request-quit! test-task)))
                            (lambda ()
                              (scene:mouse! "down" 3) (scene:mouse! "move" 9) (scene:mouse! "drag" 12)
                              (scene:mouse! "down" 4 '("clicks" . 2)) (scene:mouse! "click" 4 '("clicks" . 2))
                              (scene:mouse! "down" 20 '("clicks" . 3)) (scene:mouse! "move" 2) (scene:mouse! "drag" #f '("clicks" . 3))
                              (scene:mouse! "down" 6 '("modifiers" . #("shift"))) (scene:mouse! "click" 6 '("modifiers" . #("shift")))
                              (test-user:press! "x DEL")
                              (scene:mouse! "down" 2) (test-user:press! "C-g") (scene:mouse! "move" 8) (scene:mouse! "click" 8)))])
        (check (> rounds 10))
        (check (> (- (quits:requests) requests) 30))
        (check-equal? '() (remp (lambda (m) (equal? m "Stale click: what was clicked is gone")) others))))
    (check-equal? 1 (length (views:cursors (scene:view))))
    (check (on-stops? b))
    (check (<= (length (keys:active-keymaps (test-user:client))) 3))
    (undo:go-to! b 0)
    (check-equal? "alpha beta gamma\ndelta epsilon\n" (scene:text))
    (scene:mouse! "down" 8)
    (scene:mouse! "click" 8)
    (check-equal? '((8 #f)) (scene:cursors))))

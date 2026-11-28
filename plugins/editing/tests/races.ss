(import (tuna) (test) (test-user) (test-runner) (options) (web) (keys) (views) (buffers) (kill-ring) (undo)
        (editing) (editing-test scene)
        (rename (only (chezscheme) sleep) (sleep chez:sleep)))

(define request-quit! (test-runner:running-task-canceller))

(define refusals
  '("end of buffer" "beginning of buffer" "no reader is loaded" "no two characters to transpose"
    "the mark is not set, so there is no region"))

;; A user's C-g reaches Tuna on the server's thread while keys run, so a
;; quit lands inside whatever key's command is running then, which reports
;; it. How many land in a given time depends on the machine's load, so the
;; storm goes on until enough? of the number reported says enough have.
(define (storm! quit! enough? thunk)
  (let* ([quitting #t] [stopped #f] [quits 0] [others '()]
         [note-report (lambda (next c)
                        (cond
                          [(not (cancelled? c)) (set! others (cons (editing-test/scene:condition-text c) others))]
                          [(eq? 'quit (cancelled-reason c)) (set! quits (+ quits 1))]))])
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
    (let loop ([rounds 0])
      (unless (and (> rounds 10) (enough? quits))
        (thunk)
        (loop (+ rounds 1))))
    (set! quitting #f)
    (test-runner:wait-until (lambda () stopped))
    (test-user:settle)
    (advice-remove! report note-report)
    others))

(define (press-quit!) (web:post-input! (test-user:client) '(("type" . "key") ("name" . "C-g") ("quit" . #t))))

(define (on-stops? b)
  (for-all (lambda (c) (eqv? (buffers:stop b (views:cursor-point c)) (views:cursor-point c))) (views:cursors (editing-test/scene:view))))

(test "reloading the plugin keeps its commands and bindings and starts its passing state afresh"
  (editing-test/scene:show! "alpha beta gamma" 1)
  (test-user:press! "M-d")
  (reload-modules! '((editing)))
  (test-user:press! "M-d")
  (check-equal? '((" gamma" ((1 #f))) (" beta")) (list (editing-test/scene:state) (editing-test/scene:kills 1)))
  (test-user:press! "C-y")
  (reload-modules! '((editing)))
  (check-equal? '((ask:choice-reader "no reader is loaded")) (editing-test/scene:press-reports! "M-y"))
  (test-user:press! "M-f x")
  (check-equal? '(" beta gammax" ((13 #f))) (editing-test/scene:state)))

(test "quits landing in typing, killing and yanking at three cursors leave every cursor on a stop, an edit still clearing every view's marks, and the history whole"
  (editing-test/scene:with-setting editing:delete-selection #t
    (lambda ()
      (let ([storm (editing-test/scene:show! "alpha beta\ngamma delta\nepsilon zeta\n" 1 12 24)])
        ;; The yanks grow the text with every round, and how many rounds run
        ;; depends on the machine, so the history is unbounded to keep the
        ;; first state.
        (buffers:with-buffer storm (options:set-local! undo:limit (greatest-fixnum)))
        (check-equal? '()
          (remp (lambda (m) (member m refusals))
                (storm! press-quit! (lambda (quits) (> quits 10))
                  (lambda ()
                    (for-each test-user:press!
                      '("a" "S-<left>" "b" "C-SPC" "M-b" "M-w" "C-y" "M-y" "C-k" "C-y" "DEL" "M-f" "C-t" "M-u" "C-n" "C-a"))))))
        (check (on-stops? storm))
        (let ([other (views:make storm)])
          (views:set-mark! other 2)
          (test-user:press! "C-SPC x")
          (check-equal? '(#f #f) (list (views:mark (editing-test/scene:view)) (views:mark other)))
          (views:drop! other))
        (undo:go-to! storm 0)
        (check-equal? "alpha beta\ngamma delta\nepsilon zeta\n" (editing-test/scene:text))
        (check (for-all string? (map kill-ring:text (kill-ring:entries)))))))
  (editing-test/scene:take-said!))

(test "reloading the plugin in the middle of a drag ends the drag, and the next press starts afresh"
  (editing-test/scene:show! "alpha beta gamma\ndelta epsilon\n" 1)
  (test-user:press-button! (editing-test/scene:view) 2)
  (test-user:move-pointer! 5)
  (reload-modules! '((editing)))
  (test-user:move-pointer! 9)
  (check-equal? '((5 2)) (editing-test/scene:cursors))
  (test-user:release-button! 9)
  (test-user:drag! (editing-test/scene:view) 7 11)
  (check-equal? '((11 7)) (editing-test/scene:cursors)))

(test "quits landing in presses, moves, drags and clicks leave one cursor on a stop, at most one drag keymap, and clicks working"
  (let ([b (editing-test/scene:show! "alpha beta gamma\ndelta epsilon\n" 1)])
    (buffers:with-buffer b
      (options:set-local! undo:limit (greatest-fixnum))
      (options:set-local! editing:delete-active-region #f))
    (let ([requests 0])
      (check-equal? '()
        (remp (lambda (m) (equal? m "Stale click: what was clicked is gone"))
              (storm! (let ([test-task (current-task)]) (lambda () (when (request-quit! test-task) (set! requests (+ requests 1)))))
                      (lambda (quits) (> requests 30))
                      (lambda ()
                        (let ([v (editing-test/scene:view)])
                          (test-user:press-button! v 3) (test-user:move-pointer! 9) (test-user:release-button! 12)
                          (test-user:click! v 4 "<double-mouse-1>")
                          (test-user:press-button! v 20 "<triple-down-mouse-1>") (test-user:move-pointer! 2) (test-user:release-button! #f)
                          (test-user:click! v 6 "S-<mouse-1>")
                          (test-user:press! "x DEL")
                          (test-user:press-button! v 2) (test-user:press! "C-g") (test-user:move-pointer! 8) (test-user:release-button! 8)))))))
    (check-equal? 1 (length (views:cursors (editing-test/scene:view))))
    (check (on-stops? b))
    (check (<= (length (keys:active-keymaps (test-user:client))) 3))
    (undo:go-to! b 0)
    (check-equal? "alpha beta gamma\ndelta epsilon\n" (editing-test/scene:text))
    ;; A click names a place on the client's last screen. The storm can
    ;; leave an edit before 8, and a click on the screen drawn before the
    ;; undo would follow the undo's edits to another place.
    (test-user:settle)
    (test-user:click! (editing-test/scene:view) 8)
    (check-equal? '((8 #f)) (editing-test/scene:cursors))))

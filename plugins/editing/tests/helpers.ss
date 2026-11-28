(import (tuna) (test) (test-user) (commands) (keys) (views) (buffers) (document) (kill-ring) (editing)
        (editing-test scene))

(define (view) (editing-test/scene:view))

(commands:define-command (to-start-or-say)
  "Moves each cursor to the buffer's first stop, saying nowhere to go when the primary cannot move."
  (editing:move-cursors! 'to-start-or-say (view) 1 (lambda (c doc lo hi) (values lo #f)) "nowhere to go"))

(commands:define-command (to-start-or-count)
  "As to-start-or-say, with the message made from the count."
  (editing:move-cursors! 'to-start-or-count (view) 3 (lambda (c doc lo hi) (values lo #f))
    (lambda (n) (format "~a steps blocked" n))))

(keys:bind! keys:global "C-c s" to-start-or-say)
(keys:bind! keys:global "C-c n" to-start-or-count)

(commands:define-command (kill-first-word)
  "Kills from point to the end of the word after it, skipping one blank first."
  (editing:kill-ranges! (view)
    (lambda (buffer point)
      (let* ([doc (buffers:document buffer)]
             [from (if (eqv? (document:token doc point) #\space) (+ point 1) point)])
        (values point (editing:forward-word-position buffer from 1))))))

(commands:define-command (kill-word-before)
  "Kills back to the start of the word before point."
  (editing:kill-ranges! (view)
    (lambda (buffer point) (values point (editing:forward-word-position buffer point -1)))))

(test "move-cursors! raises the message it is given, or one made from the count, when the primary cursor cannot move"
  (editing-test/scene:show! "abc" 3)
  (check-equal? '() (editing-test/scene:press-reports! "C-c s"))
  (check-equal? '((to-start-or-say "nowhere to go")) (editing-test/scene:press-reports! "C-c s"))
  (check-equal? '((to-start-or-count "3 steps blocked")) (editing-test/scene:press-reports! "C-c n"))
  (check-raises (editing-test/scene:raised? 'editing:move-cursors! "not a string or a procedure")
    (editing:move-cursors! 'x (view) 1 (lambda (c doc lo hi) (values lo #f)) 'oops)))

(test "set-marks! sets each cursor's mark from the buffer, its point and its mark, and #f clears it"
  (let ([b (editing-test/scene:show! "abcdef" 2 4)])
    (editing:set-marks! (view) (lambda (buffer point mark) (and (eq? buffer b) (+ point 1))))
    (check-equal? '((2 3) (4 5)) (editing-test/scene:cursors))
    (editing:set-marks! (view) (lambda (buffer point mark) (and (= point 2) (+ mark 1))))
    (check-equal? '((2 4) (4 #f)) (editing-test/scene:cursors))
    (check-raises (editing-test/scene:raised? 'editing:set-marks! "not a procedure") (editing:set-marks! (view) 3))))

(test "kill-ranges! kills each cursor's range as one entry, and a kill right after adds to it"
  (editing-test/scene:show! "one two three" 1)
  (editing-test/scene:run kill-first-word)
  (check-equal? '(" two three" ((1 #f))) (editing-test/scene:state))
  (editing-test/scene:run kill-first-word)
  (check-equal? '("one two") (editing-test/scene:kills 1))
  (check-raises (editing-test/scene:raised? 'editing:kill-ranges! "not two positions in the buffer")
    (editing:kill-ranges! (view) (lambda (buffer point) (values point 99)))))

(test "a backward range is a backward kill, so it goes before the entry it joins"
  (editing-test/scene:show! "one two" 8)
  (editing-test/scene:run kill-word-before)
  (editing-test/scene:run kill-word-before)
  (check-equal? '("one two") (editing-test/scene:kills 1)))

(test "lines-bounds gives a cursor's lines: its own, or those its region touches, less a last one the region ends at the start of"
  (let ([b (editing-test/scene:show! "ab\ncd\nef\n" 1)])
    (check-equal? '(4 6) (call-with-values (lambda () (editing:lines-bounds b 5 #f)) list))
    (check-equal? '(1 6) (call-with-values (lambda () (editing:lines-bounds b 2 5)) list))
    (check-equal? '(1 3) (call-with-values (lambda () (editing:lines-bounds b 2 4)) list))
    (check-raises (editing-test/scene:raised? 'editing:lines-bounds "not a position in the buffer") (editing:lines-bounds b 99 #f))))

(test "forward-symbol moves to the end of the next symbol, or back to the start of one"
  (editing-test/scene:show! "(a b-c d)" 3)
  (editing-test/scene:run editing:forward-symbol 1)
  (check-equal? 7 (views:point (view)))
  (editing-test/scene:run editing:forward-symbol -2)
  (check-equal? 2 (views:point (view)))
  (editing-test/scene:run editing:forward-symbol -1)
  (check-equal? 1 (views:point (view)))
  (check-equal? '((editing:forward-symbol "beginning of buffer"))
                (editing-test/scene:reports-during (lambda () (editing-test/scene:run editing:forward-symbol -1)))))

(define (keep-regions replace-selection? view cursor) #f)

(define (refuse-regions replace-selection? view cursor) (error 'refuse-regions "kept"))

(test "replace-selection? decides whether typing, a line break and a yank replace the region; advice that answers #f keeps it, advice that raises refuses the command"
  (editing-test/scene:with-setting editing:delete-selection #t
    (lambda ()
      (editing-test/scene:show! "one two" 1)
      (test-user:press! "C-SPC M-f x")
      (check-equal? " two" (substring (editing-test/scene:text) 1 5))
      (advice-add! editing:replace-selection? keep-regions)
      (editing-test/scene:show! "one two" 1)
      (test-user:press! "C-SPC M-f x")
      (check-equal? "onex two" (editing-test/scene:text))
      (advice-remove! editing:replace-selection? keep-regions)
      (advice-add! editing:replace-selection? refuse-regions)
      (editing-test/scene:show! "one two" 1)
      (check-equal? '((refuse-regions "kept")) (editing-test/scene:press-reports! "C-SPC M-f RET"))
      (check-equal? '(4 1) (car (editing-test/scene:cursors)))
      (advice-remove! editing:replace-selection? refuse-regions))))

(test "join-ranges gives the ranges delete-indentation deletes, the last line's first"
  (let ([b (editing-test/scene:show! "a  \n  b\n c" 9)])
    (check-equal? '((8 . 10)) (editing:join-ranges (editing-test/scene:view) 9 #f #f))
    (check-equal? '((8 . 10) (2 . 7)) (editing:join-ranges (editing-test/scene:view) 1 11 #f))
    (check-equal? '((8 . 10)) (editing:join-ranges (editing-test/scene:view) 5 #f '(4)))
    (test-user:press! "M-^")
    (check-equal? "a  \n  b c" (editing-test/scene:text))))

(import (tuna) (test) (test-user) (options) (tables) (commands) (keys) (modes) (syntax) (layout) (layout-split)
        (views) (buffers) (document) (editing) (scene) (md))

(define (on-thread thunk)
  (let ([result #f])
    (join-task (fork-task (lambda (restore) (set! result (guard (c [(assertion-violation? c) (condition-message c)]) (thunk))))))
    result))

(define (lines-of n)
  (apply string-append (map (lambda (i) "abcdefghi\n") (iota n))))

(test "a word is a run of letters, digits and the mode's word characters; other characters, such as an em dash, end it"
  (scene:show! "foo-bar, naïve—café 中文 $5%" 1)
  (check-equal? '(4 8 15 20 23 27) (scene:points-after! "M-f" "M-f" "M-f" "M-f" "M-f" "M-f"))
  (check-equal? '((editing:forward-word "end of buffer")) (scene:press-reports! "M-f"))
  (check-equal? '(24 21 16 10 5 1) (scene:points-after! "M-b" "C-<left>" "M-<left>" "M-b" "M-b" "M-b"))
  (check-equal? '((editing:backward-word "beginning of buffer")) (scene:press-reports! "M-b"))
  (check-equal? '(4 8) (scene:points-after! "C-<right>" "M-<right>")))

(test "a word's characters are those of the buffer's major mode"
  (let ([kept (tables:ref syntax:word-characters modes:fundamental)])
    (scene:show! "foo-bar, x" 8)
    (tables:set! syntax:word-characters modes:fundamental "-")
    (check-equal? '(1 8) (scene:points-after! "M-b" "M-f"))
    (tables:set! syntax:word-characters modes:fundamental kept)))

(options:define-option superword #f boolean? "Whether symbols are words.")

(define (superword-characters word-characters buffer)
  (if (buffers:with-buffer buffer (superword))
      (string-append (word-characters buffer) (syntax:buffer-symbol-characters buffer))
      (word-characters buffer)))

(test "a minor mode that advises syntax:buffer-word-characters changes one buffer's words, as superword-mode does"
  (advice-add! syntax:buffer-word-characters superword-characters)
  (let ([b (scene:show! "foo_bar baz" 1)])
    (check-equal? '(4) (scene:points-after! "M-f"))
    (buffers:with-buffer b (options:set-local! superword #t))
    (views:set-point! (scene:view) 1)
    (check-equal? '(8 12) (scene:points-after! "M-f" "M-f")))
  (advice-remove! syntax:buffer-word-characters superword-characters))

(test "M-f and M-b move by words, a negative count the other way"
  (test-user:show! "one two| three")
  (test-user:press! "M-f")
  (check-equal? "one two three|" (test-user:text))
  (test-user:press! "M-b")
  (check-equal? "one two |three" (test-user:text))
  (test-user:press! "M-- M-f")
  (check-equal? "one |two three" (test-user:text)))

(test "a motion moves as far as it can and says the buffer's edge only when the primary cursor did not move"
  (test-user:show! "one two|")
  (check-equal? '() (scene:press-reports! "C-u 3 M-b"))
  (check-equal? "|one two" (test-user:text))
  (test-user:show! "a|bc")
  (check-equal? '() (scene:press-reports! "C-u 2 C-b"))
  (check-equal? "|abc" (test-user:text))
  (check-equal? '() (scene:press-reports! "C-u 5 C-f"))
  (check-equal? "abc|" (test-user:text))
  (check-equal? '((editing:forward-char "end of buffer")) (scene:press-reports! "C-f"))
  (check-equal? "abc|" (test-user:text)))

(test "C-n on the last line goes to its end, and only the next C-n says the end; C-p on the first line goes to its start"
  (test-user:show! "one\nt|wo")
  (check-equal? '() (scene:press-reports! "C-n"))
  (check-equal? "one\ntwo|" (test-user:text))
  (check-equal? '((editing:next-line "end of buffer")) (scene:press-reports! "C-n"))
  (test-user:show! "o|ne\ntwo")
  (check-equal? '() (scene:press-reports! "C-p"))
  (check-equal? "|one\ntwo" (test-user:text)))

(test "line motions keep the column the run of line motions began at"
  (scene:show! "abcdef\nab\n\nabcdefgh\nxyz" 5)
  (check-equal? '(10 11 16 24 16 11) (scene:points-after! "C-n" "C-n" "C-n" "C-n" "C-p" "C-p"))
  (scene:press-reports! "C-n C-n")
  (check-equal? '((editing:next-line "end of buffer")) (scene:press-reports! "C-n"))
  (check-equal? '("abcdef\nab\n\nabcdefgh\nxyz" ((24 #f))) (scene:state))
  (check-equal? '(16) (scene:points-after! "C-p")))

(test "C-a, C-e, M-< and M-> go to the line's and the buffer's ends; counts move as far as they can"
  (scene:show! "abcdef\nab\n\nabcdefgh\nxyz" 24)
  (check-equal? '(21 12 20 1 24) (scene:points-after! "C-a" "C-p" "C-e" "M-<" "M->"))
  (test-user:press! "C-u 3 C-b")
  (check-equal? '(21 20) (scene:points-after! "M--" "C-f"))
  (check-equal? '(20 1) (scene:points-after! "M-5" "C-p"))
  (check-equal? '((editing:previous-line "beginning of buffer")) (scene:press-reports! "C-p"))
  (check-equal? '((editing:backward-char "beginning of buffer")) (scene:press-reports! "C-b"))
  (check-raises (scene:raised? 'editing:forward-char "not an exact integer") (editing:forward-char 1.5)))

(test "<home> and <end> go to the line's ends"
  (test-user:show! "x\n  ab|c\ny")
  (test-user:press! "<home>")
  (check-equal? "x\n|  abc\ny" (test-user:text))
  (test-user:press! "<end>")
  (check-equal? "x\n  abc|\ny" (test-user:text)))

(test "M-> and M-< set no mark, and record the place point left in jump-history, so M-, returns"
  (scene:show! (lines-of 100) 25)
  (test-user:press! "M->")
  (check-equal? '(1001 #f) (car (scene:cursors)))
  (check-equal? '((editing:exchange-point-and-mark "the mark is not set")) (scene:press-reports! "C-x C-x"))
  (test-user:press! "M-<")
  (check-equal? '((1 #f)) (scene:cursors))
  (test-user:press! "M-,")
  (check-equal? 1001 (views:point (scene:view)))
  (test-user:press! "M-,")
  (check-equal? 25 (views:point (scene:view))))

(test "M-> and M-< with a count go to the start of the line after that many tenths of the buffer from its end or start"
  (scene:show! (lines-of 100) 25)
  (test-user:press! "C-u 3 M->")
  (check-equal? '((711 #f)) (scene:cursors))
  (test-user:press! "C-u 3 M-<")
  (check-equal? '((311 #f)) (scene:cursors))
  (test-user:press! "C-u M->")
  (check-equal? '((1001 #f)) (scene:cursors))
  (test-user:press! "M-,")
  (check-equal? '((311 #f)) (scene:cursors)))

(test "M-<home> and M-<end> go to the ends of the view C-M-v scrolls"
  (let ([first (begin (scene:show! "one\ntwo\nthree" 5) (scene:view))])
    (test-user:press! "C-x 2")
    (let ([second (find (lambda (v) (not (eq? v first))) (layout:views))])
      (views:set-point! second 5)
      (test-user:press! "M-<end>")
      (check-equal? '(14 5) (list (views:point second) (views:point first)))
      (test-user:press! "M-<home>")
      (check-equal? '(1 5) (list (views:point second) (views:point first)))
      (test-user:press! "C-x 1"))))

(test "< and > go to the start and end in a Special mode buffer, where a printing key is undefined"
  (let ([b (scene:show! "one\ntwo" 6)])
    (modes:set-major-mode modes:special b)
    (test-user:press! "<")
    (check-equal? '((1 #f)) (scene:cursors))
    (test-user:press! ">")
    (check-equal? '((8 #f)) (scene:cursors))
    (scene:press-reports! "x")
    (check-equal? "one\ntwo" (scene:text))))

(test "every cursor acts, and cursors a motion brings together merge"
  (scene:show! "one\ntwo\nthree\n" 1 5 9)
  (test-user:press! "C-e")
  (check-equal? '("one\ntwo\nthree\n" ((4 #f) (8 #f) (14 #f))) (scene:state))
  (scene:show! "ab cd" 2 5)
  (test-user:press! "M-b")
  (check-equal? '("ab cd" ((1 #f) (4 #f))) (scene:state))
  (test-user:press! "C-a")
  (check-equal? '("ab cd" ((1 #f))) (scene:state)))

(test "M-< and M-> remove the other cursors"
  (scene:show! "one\ntwo\nthree" 2 6)
  (test-user:press! "M->")
  (check-equal? '((14 #f)) (scene:cursors))
  (views:add-cursor! (scene:view) 2)
  (test-user:press! "M-<")
  (check-equal? '((1 #f)) (scene:cursors)))

(test "a narrowed view moves only within its bounds"
  (scene:show! "one\ntwo\nthree\n" 6)
  (views:narrow! (scene:view) 5 8)
  (check-equal? '(5 8 5 8) (scene:points-after! "C-a" "C-e" "M-<" "M->"))
  (check-equal? '((editing:forward-word "end of buffer")) (scene:press-reports! "M-f"))
  (test-user:press! "C-p")
  (check-equal? '((editing:previous-line "beginning of buffer")) (scene:press-reports! "C-p"))
  (views:widen! (scene:view)))

(test "a prefix command leaves the last command as it was, so C-n after M-1 keeps its goal column"
  (scene:show! "abcdef\nab\nabcdef" 5)
  (test-user:press! "C-n M-1 C-n")
  (check-equal? 15 (views:point (scene:view))))

(test "next-line keeps the column as the page draws it, a tab reaching the next multiple of 8"
  (scene:show! "\tx\nabcdefghijk\n\ty" 3)
  (check-equal? '(13 18 13 3) (scene:points-after! "C-n" "C-n" "C-p" "C-p"))
  (scene:show! "abcdefghijk\n\tx" 5)
  (check-equal? '(13) (scene:points-after! "C-n")))

(define (para . lines) (md:para '() (apply string-append lines)))

(define (fold-child! i)
  (let* ([doc (buffers:document (views:buffer (scene:view)))]
         [children (let ([acc '()])
                     (document:for-each-child (document:token doc 0) 1 (- (document:length doc) 1)
                       (lambda (c at) (set! acc (cons c acc))))
                     (reverse acc))]
         [n (list-ref children i)])
    (views:fold! (scene:view) (+ (document:node-start n) 7) (- (document:node-end n) 1))))

(define (line-of p) (document:line (buffers:document (views:buffer (scene:view))) p))

(test "C-n and C-p step over what a fold hides, and a fold that ends at a node's closing ends its line"
  (scene:show! (md:doc '() (para "head a\n" "body\n" "body\n") (para "head b\n" "body\n") (para "head c\n")) 2)
  (fold-child! 0)
  (fold-child! 1)
  (check-equal? '(4 6 4 1) (map line-of (scene:points-after! "C-n" "C-n" "C-p" "C-p")))
  (views:set-point! (scene:view) 5)
  (check-equal? '(24 38) (scene:points-after! "C-n" "C-n"))
  (views:set-point! (scene:view) 2)
  (test-user:press! "C-u 2 C-n")
  (check-equal? 6 (line-of (views:point (scene:view)))))

(test "a fold inside text joins the lines around it into one"
  (scene:show! "one\ntwo\nthree\nfour\n" 1)
  (views:fold! (scene:view) 3 7)
  (check-equal? '(9 1) (scene:points-after! "C-n" "C-p")))

(commands:define-command (down-two)
  "Moves each cursor two lines down."
  (editing:move-cursors! 'down-two (views:current) 2 (editing:line-motion-target (views:current) 2)))

(keys:bind! keys:global "C-c d" down-two)

(test "another plugin's motion through editing:move-cursors! and the line target is a line motion, and raises at the edge"
  (scene:show! "abcdef\nab\n\nabcdefgh\nxyz" 5)
  (test-user:press! "C-c d")
  (check-equal? 11 (views:point (scene:view)))
  (check-equal? '(16) (scene:points-after! "C-n"))
  (test-user:press! "C-c d")
  (check-equal? 24 (views:point (scene:view)))
  (check-equal? '((down-two "end of buffer")) (scene:press-reports! "C-c d")))

(test "move-cursors! and line-motion-target check their arguments"
  (scene:show! "ab" 1)
  (check-raises (scene:raised? 'editing:move-cursors! "not a symbol")
    (editing:move-cursors! "down" (scene:view) 1 (editing:line-motion-target (scene:view) 1)))
  (check-raises (scene:raised? 'editing:move-cursors! "not a procedure") (editing:move-cursors! 'down (scene:view) 1 'up))
  (check-raises (scene:raised? 'editing:line-motion-target "not an exact integer") (editing:line-motion-target (scene:view) 1.5)))

(test "forward-word-position gives where moving words ends, and checks its arguments"
  (let ([b (scene:show! "one two three" 1)])
    (check-equal? 8 (editing:forward-word-position b 1 2))
    (check-raises (scene:raised? 'editing:forward-word-position "not a position in the buffer") (editing:forward-word-position b 99 1))
    (check-raises (scene:raised? 'editing:forward-word-position "not a buffer") (editing:forward-word-position "t1" 1 1))))

(commands:define-command (forward-word-on-position [n (commands:prefix-number)])
  "Moves point forward N words."
  (let ([view (views:current)])
    (views:set-point! view (editing:forward-word-position (views:buffer view) (views:point view) n))))

(test "a command written on forward-word-position, run by code with its count"
  (scene:show! "one two three" 1)
  (views:with-view (scene:view) (commands:run editing:forward-char 3))
  (check-equal? (list 4 editing:forward-char) (list (views:point (scene:view)) (commands:last-command)))
  (views:with-view (scene:view) (commands:run forward-word-on-position 1))
  (check-equal? 8 (views:point (scene:view))))

(test "line-position gives where a line starts: line 1 for a smaller number, the end for a line past the last"
  (let ([b (scene:show! "one\ntwo\nthree" 1)])
    (check-equal? '(1 5 9 14) (map (lambda (line) (editing:line-position b line)) '(0 2 3 4)))
    (check-raises (scene:raised? 'editing:line-position "not an exact integer") (editing:line-position b 1.5))
    (check-raises (scene:raised? 'editing:line-position "not a buffer") (editing:line-position "n" 1))))

(test "in nodes an edge or an atom ends a word, a line starts at its node's first stop, and the content ends at the last stop"
  (let ([n (scene:show! (md:doc '() (md:para '() "one two\n") (md:para '() "three\n")
                          (md:para '() "four " (md:image '((src . "x"))) "five\n"))
                        2)])
    (check-equal? '(5 9 17 24 30) (scene:points-after! "M-f" "M-f" "M-f" "M-f" "M-f"))
    (check-equal? '((editing:forward-word "end of buffer")) (scene:press-reports! "M-f"))
    (check-equal? '(20 12 17 7 2 12 20) (scene:points-after! "C-a" "C-p" "C-e" "C-p" "C-a" "C-n" "C-n"))
    (check-equal? 17 (editing:forward-word-position n 2 3))
    (check-equal? '(2 2 12 20 30 30) (map (lambda (line) (editing:line-position n line)) '(-1 1 2 3 4 9)))
    (check-equal? '(6 14 17 26 30)
      (map (lambda (at) (editing:line-position n (car at) (cdr at))) '((1 . 4) (2 . 2) (2 . 40) (3 . 6) (9 . 3))))))

(test "the plugin's helpers and commands refuse other threads"
  (let ([b (scene:show! "one two" 1)])
    (check-equal? "not on the main thread" (on-thread (lambda () (editing:forward-word-position b 1 1))))
    (check-equal? "not on the main thread" (on-thread (lambda () (editing:line-position b 1))))
    (check-equal? "not on the main thread" (on-thread (lambda () (commands:run editing:forward-char 1))))))

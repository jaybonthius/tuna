(import (tuna) (test) (tables) (document) (buffers) (kill-ring-test md) (kill-ring-test blocks) (kill-ring))

(define (raised? who message)
  (lambda (c)
    (and (who-condition? c) (eq? who (condition-who c))
         (message-condition? c) (string=? message (condition-message c)))))

(define (contents b) (document:text (buffers:document b)))

(define (root b) (car (document:datums (buffers:document b))))

(define (spans-of b layer)
  (map (lambda (s) (list (document:text (buffers:document b) (car s) (cadr s)) (caddr s)))
       (buffers:spans (buffers:layer b layer) 0 (document:length (buffers:document b)))))

(buffers:define-layer responses (travels) (sticky after))
(buffers:define-layer marks)
(buffers:define-layer guarded (read-only))

(test "insert! takes a buffer, a position in it, and a string, a piece or a kill"
  (let* ([b (buffers:make "arguments" "Hello world\n")] [p (buffers:piece b 1 6)])
    (check-raises (raised? 'kill-ring:insert! "not a buffer") (kill-ring:insert! "b" 1 p))
    (check-raises (raised? 'kill-ring:insert! "not a position") (kill-ring:insert! b -1 p))
    (check-raises (raised? 'kill-ring:insert! "not a string, a piece or a kill") (kill-ring:insert! b 1 5))
    (check-raises (raised? 'kill-ring:insert! "not a string, a piece or a kill") (kill-ring:insert! b 1 (list p)))
    (check-raises (raised? 'kill-ring:insert! "not a position in the buffer") (kill-ring:insert! b 99 "x"))
    (check-equal? "Hello world\n" (contents b))
    (buffers:kill! b)))

(test "insert! yanks a string or a piece and returns the range it inserted"
  (let* ([b (buffers:make "plain" "Hello world\n")] [p (buffers:piece b 1 6)])
    (check-equal? '((12 . 17)) (kill-ring:insert! b 12 p))
    (check-equal? "Hello worldHello\n" (contents b))
    (check-equal? '((1 . 5)) (kill-ring:insert! b 1 "Oh, "))
    (check-equal? "Oh, Hello worldHello\n" (contents b))
    (buffers:kill! b)))

(test "a kill across paragraphs yanks back as it was killed"
  (let* ([m (buffers:make "across" (kill-ring-test/md:doc '() (kill-ring-test/md:para '() "Alpha " (kill-ring-test/md:link '() "beta") " gamma.\n") (kill-ring-test/md:para '() "Two three.\n")))]
         [across (buffers:piece m 4 26)]
         [before (root m)])
    (check-equal? "pha beta gamma.\nTw" (buffers:piece-text across))
    (buffers:replace! m 4 26 "")
    (check-equal? '(kill-ring-test/md:doc () (kill-ring-test/md:para () "Alo three.\n")) (root m))
    (check-equal? '((4 . 26)) (kill-ring:insert! m 4 across))
    (check-equal? before (root m))
    (check-equal? '((8 . 30)) (kill-ring:insert! m 8 across))
    (check-equal? '(kill-ring-test/md:doc () (kill-ring-test/md:para () "Alpha pha " (kill-ring-test/md:link () "beta") " gamma.\n")
                    (kill-ring-test/md:para () "Tw" (kill-ring-test/md:link () "beta") " gamma.\n") (kill-ring-test/md:para () "Two three.\n"))
                  (root m))
    (check-equal? "pha beta gamma.\nTw" (document:text (buffers:document m) 8 30))
    (buffers:kill! m)))

(test "a whole paragraph yanked inside another splits it, the first half keeping a line break"
  (let* ([m (buffers:make "source" (kill-ring-test/md:doc '() (kill-ring-test/md:para '() "Two three.\n")))]
         [para (buffers:piece m 1 14)]
         [n (buffers:make "split" (kill-ring-test/md:doc '() (kill-ring-test/md:para '() "abcd\n")))])
    (check-equal? "Two three.\n" (buffers:piece-text para))
    (let ([after (cdar (kill-ring:insert! n 4 para))])
      (check-equal? '(kill-ring-test/md:doc () (kill-ring-test/md:para () "ab\n") (kill-ring-test/md:para () "Two three.\n") (kill-ring-test/md:para () "cd\n")) (root n))
      (check-equal? "ab\nTwo three.\n" (document:text (buffers:document n) 0 after)))
    (buffers:kill! m)
    (buffers:kill! n)))

(test "yanked back, atoms come back as they were"
  (let* ([b (buffers:make "atoms" (kill-ring-test/md:doc '() (kill-ring-test/md:para '() "a " (kill-ring-test/md:badge '((label . "NEW"))) " b " (kill-ring-test/md:image '()) "c\n")))]
         [p (buffers:piece b 2 10)])
    (check-equal? '((2 . 10)) (kill-ring:insert! b 2 p))
    (check-equal? '(kill-ring-test/md:doc () (kill-ring-test/md:para () "a " #(kill-ring-test/md:badge ((label . "NEW"))) " b " #(kill-ring-test/md:image ()) "ca "
                              #(kill-ring-test/md:badge ((label . "NEW"))) " b " #(kill-ring-test/md:image ()) "c\n"))
                  (root b))
    (buffers:kill! b)))

(test "a travelling span survives a kill and a yank elsewhere, another layer's stays behind, and a string yanked at its end joins it"
  (let* ([t (buffers:make "spans" "Ask. Answer here. End.\n")])
    (buffers:add-span! (buffers:layer t responses) 6 18 'gpt)
    (buffers:add-span! (buffers:layer t marks) 6 18 'mark)
    (let ([answer (buffers:piece t 6 18)])
      (buffers:replace! t 6 18 "")
      (check-equal? "Ask.  End.\n" (contents t))
      (check-equal? '() (spans-of t responses))
      (check-equal? '(("" mark)) (spans-of t marks))
      (check-equal? '((11 . 23)) (kill-ring:insert! t 11 answer))
      (check-equal? "Ask.  End.Answer here.\n" (contents t))
      (check-equal? '(("Answer here." gpt)) (spans-of t responses))
      (check-equal? '(("" mark)) (spans-of t marks))
      (check-equal? '((23 . 24)) (kill-ring:insert! t 23 "!"))
      (check-equal? '(("Answer here.!" gpt)) (spans-of t responses)))
    (buffers:kill! t)))

(test "a kill appended to a kill keeps both parts, and a yank puts each back in turn with its spans"
  (let ([t (buffers:make "answer" "Ask. Answer here.\n")]
        [w (buffers:make "paragraphs" (kill-ring-test/md:doc '() (kill-ring-test/md:para '() "One two.\n") (kill-ring-test/md:para '() "Three four.\n")))]
        [u (buffers:make "target" (kill-ring-test/md:doc '() (kill-ring-test/md:para '() "xy\n")))])
    (buffers:add-span! (buffers:layer t responses) 6 18 'gpt)
    (kill-ring:push! (list (buffers:piece w 6 17)))
    (kill-ring:append! (list "+"))
    (kill-ring:append! (list (buffers:piece t 6 18)))
    (kill-ring:prepend! (list "<"))
    (check-equal? "<two.\nThre+Answer here." (kill-ring:text (kill-ring:current)))
    (check-equal? '((3 . 28)) (kill-ring:insert! u 3 (car (kill-ring:current))))
    (check-equal? '(kill-ring-test/md:doc () (kill-ring-test/md:para () "x<two.\n") (kill-ring-test/md:para () "Thre+Answer here.y\n")) (root u))
    (check-equal? '(("Answer here." gpt)) (spans-of u responses))
    (kill-ring:append! (list "!"))
    (check-equal? "<two.\nThre+Answer here.!" (kill-ring:text (kill-ring:current)))
    (for-each buffers:kill! (list t w u))))

(test "a part refused after others went in takes them back out, leaving the buffer and its spans as they were"
  (let ([t (buffers:make "answer" "Ask. Answer here.\n")]
        [w (buffers:make "paragraphs" (kill-ring-test/md:doc '() (kill-ring-test/md:para '() "One two.\n") (kill-ring-test/md:para '() "Three four.\n")))]
        [f (buffers:make "form" '(kill-ring-test/md:form () (kill-ring-test/md:field () "xy")))])
    (buffers:add-span! (buffers:layer t responses) 6 18 'gpt)
    (buffers:add-span! (buffers:layer f responses) 3 4 'gpt)
    (let ([version (buffers:version f)])
      (kill-ring:push! (list "abc"))
      (kill-ring:append! (list (buffers:piece t 6 18)))
      (kill-ring:append! (list (buffers:piece w 6 17)))
      (check-raises (raised? 'buffers:insert! "the node refuses the edit") (kill-ring:insert! f 3 (car (kill-ring:current))))
      (check-equal? '(kill-ring-test/md:form () (kill-ring-test/md:field () "xy")) (root f))
      (check-equal? '(("y" gpt)) (spans-of f responses))
      (check (> (buffers:version f) version)))
    (kill-ring:push! (list "abc"))
    (kill-ring:append! (list (buffers:piece t 6 18)))
    (check-equal? '((3 . 18)) (kill-ring:insert! f 3 (car (kill-ring:current))))
    (check-equal? '(kill-ring-test/md:form () (kill-ring-test/md:field () "xabcAnswer here.y")) (root f))
    (check-equal? '(("Answer here.y" gpt)) (spans-of f responses))
    (check-raises (raised? 'buffers:insert! "the node refuses the edit") (kill-ring:insert! f 3 (kill-ring:join "a" (buffers:piece w 6 17))))
    (check-equal? '(kill-ring-test/md:form () (kill-ring-test/md:field () "xabcAnswer here.y")) (root f))
    (for-each buffers:kill! (list t w f))))

(test "a joined kill yanks its parts in turn"
  (let ([w (buffers:make "cells" (kill-ring-test/md:doc '() (kill-ring-test/md:para '() "One two.\n") (kill-ring-test/md:para '() "Three four.\n")))]
        [z (buffers:make "row" (kill-ring-test/md:doc '() (kill-ring-test/md:para '() "ab\n")))])
    (check-equal? '((3 . 12)) (kill-ring:insert! z 3 (kill-ring:join (buffers:piece w 2 5) "|" (buffers:piece w 13 18))))
    (check-equal? '(kill-ring-test/md:doc () (kill-ring-test/md:para () "aOne|Threeb\n")) (root z))
    (for-each buffers:kill! (list w z)))
  (let* ([w (buffers:make "plain-text" "one two\n")] [joined (kill-ring:join (buffers:piece w 1 4) "\n" "two")])
    (check-equal? "one\ntwo" (kill-ring:text (list joined)))
    (check-equal? '((1 . 8)) (kill-ring:insert! w 1 joined))
    (check-equal? "one\ntwoone two\n" (contents w))
    (buffers:kill! w)))

(test "a piece whose top node, or atom, has a kind in kill-ring:yankers goes to its procedure; otherwise to the buffer"
  (let* ([calls '()]
         [note-yank (lambda (buffer position piece)
                      (set! calls (cons (list (buffers:name buffer) position (buffers:piece-text piece)) calls))
                      42)]
         [v (buffers:make "v" (kill-ring-test/md:doc '() (kill-ring-test/md:para '() "Pic " (kill-ring-test/md:image '((src . "a.png"))) ".\n") (kill-ring-test/md:para '() "Last.\n")))]
         [u (buffers:make "u" (kill-ring-test/md:doc '() (kill-ring-test/md:para '() "xy\n")))]
         [yank-range! (lambda (start end) (kill-ring:insert! u 2 (buffers:piece v start end)))])
    (tables:set! kill-ring:yankers 'kill-ring-test/md:image note-yank)
    (tables:set! kill-ring:yankers 'kill-ring-test/md:para note-yank)
    (let* ([a (yank-range! 6 7)] [b (yank-range! 1 10)] [c (yank-range! 1 5)] [d (yank-range! 10 18)])
      (check-equal? '(() () () ()) (list a b c d)))
    (check-equal? '(("u" 2 "") ("u" 2 "Pic .\n") ("u" 2 "Pic") ("u" 2 "Last.\n")) (reverse calls))
    (check-equal? '(kill-ring-test/md:doc () (kill-ring-test/md:para () "xy\n")) (root u))
    (check-equal? '((2 . 13)) (yank-range! 2 13))
    (check-equal? '(kill-ring-test/md:doc () (kill-ring-test/md:para () "Pic " #(kill-ring-test/md:image ((src . "a.png"))) ".\n") (kill-ring-test/md:para () "Laxy\n")) (root u))
    (tables:remove! kill-ring:yankers 'kill-ring-test/md:para)
    (tables:remove! kill-ring:yankers 'kill-ring-test/md:image)
    (check-equal? '((2 . 10)) (yank-range! 10 18))
    (check-raises (raised? 'kill-ring:insert! "not a position in the buffer") (kill-ring:insert! u 999 (buffers:piece v 1 10)))
    (check-equal? 4 (length calls))
    (for-each buffers:kill! (list u v))))

(test "a yanker inserts and returns the position after; insert! reports what it inserted"
  (tables:set! kill-ring:yankers 'kill-ring-test/blocks:block kill-ring-test/blocks:yank-block)
  (let ([grid (buffers:make "grid" (kill-ring-test/md:doc '() (kill-ring-test/blocks:block '() "ab\ncd\n") (kill-ring-test/md:para '() "end\n")))])
    (kill-ring:push! (list (buffers:piece grid 1 9)))
    (check-equal? '((10 . 16)) (kill-ring:insert! grid 10 (car (kill-ring:current))))
    (check-equal? '(10) (kill-ring-test/blocks:yanks))
    (check-equal? '(kill-ring-test/md:doc () (kill-ring-test/blocks:block () "ab\ncd\n") (kill-ring-test/md:para () "ab\ncd\nend\n")) (root grid))
    (buffers:kill! grid))
  (tables:remove! kill-ring:yankers 'kill-ring-test/blocks:block))

(test "a kill made with its own procedure yanks by calling it, and insert! reports every insertion it made"
  (let ([w (buffers:make "handled" "one two\n")]
        [handled (kill-ring:make-kill (list "ab" "cd")
                   (lambda (buffer position)
                     (let ([middle (buffers:insert! buffer position "[ab|")])
                       (buffers:insert! buffer (+ middle 3) "cd]"))))])
    (check-equal? "abcd" (kill-ring:text (list handled)))
    (check-equal? '((1 . 5) (8 . 11)) (kill-ring:insert! w 1 handled))
    (check-equal? "[ab|onecd] two\n" (contents w))
    (buffers:kill! w)))

(test "insertions before, inside or next to earlier ones move or join them, read in one pass"
  (let ([d (buffers:make "digits" "0123456789\n")]
        [scattered (kill-ring:make-kill (list "x")
                     (lambda (buffer position)
                       (buffers:insert! buffer 8 "B") (buffers:insert! buffer 3 "A")
                       (buffers:insert! buffer 4 "xy") (buffers:insert! buffer 5 "z")))])
    (check-equal? '((3 . 7) (12 . 13)) (kill-ring:insert! d 1 scattered))
    (check-equal? "01Axzy23456B789\n" (contents d))
    (buffers:kill! d)))

(test "a procedure's insertions go in whole or not at all"
  (let ([g (buffers:make "guarded" "aaa\nbbb\nccc\n")]
        [two-places (kill-ring:make-kill (list "x")
                      (lambda (buffer position) (buffers:insert! buffer position "x") (buffers:insert! buffer 7 "x")))])
    (buffers:add-span! (buffers:layer g guarded) 5 8 'locked)
    (check-raises (raised? 'buffers:insert! "the text of guarded is read-only") (kill-ring:insert! g 2 two-places))
    (check-equal? "aaa\nbbb\nccc\n" (contents g))
    (buffers:kill! g)))

(test "a kill with its own procedure is never joined to another, nor another to it"
  (let ([handled (kill-ring:make-kill (list "ab" "cd") (lambda (buffer position) position))])
    (kill-ring:push! (list "plain"))
    (kill-ring:append! (list handled))
    (kill-ring:append! (list "more"))
    (check-equal? '("more" "abcd" "plain") (map kill-ring:text (list-head (kill-ring:entries) 3)))
    (kill-ring:prepend! (list handled))
    (kill-ring:prepend! (list "less"))
    (check-equal? '("less" "abcd" "more") (map kill-ring:text (list-head (kill-ring:entries) 3)))))

(test "make-kill takes a non-empty list of strings, pieces and kills, and a procedure"
  (check-raises (raised? 'kill-ring:make-kill "not a non-empty list of strings, pieces and kills") (kill-ring:make-kill '() values))
  (check-raises (raised? 'kill-ring:make-kill "not a procedure") (kill-ring:make-kill (list "a") "yank")))

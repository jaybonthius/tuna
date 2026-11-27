(import (tuna) (test) (test-user) (options) (tables) (commands) (keys) (layout) (layout-split) (views)
        (buffers) (document) (kill-ring) (editing) (scene) (md) (typed))

(test "typing inserts at point, a count repeats the character, and the buffer becomes modified"
  (let ([b (begin (test-user:show! "ab|c") (views:buffer (scene:view)))])
    (check-equal? #f (buffers:modified? b))
    (test-user:press! "x")
    (check-equal? "abx|c" (test-user:text))
    (test-user:press! "C-u 3 y")
    (check-equal? "abxyyy|c" (test-user:text))
    (test-user:press! "SPC")
    (check-equal? "abxyyy |c" (test-user:text))
    (check (buffers:modified? b))))

(test "a count goes in at each cursor; a negative count raises"
  (scene:show! "ab" 2)
  (test-user:press! "C-o")
  (check-equal? '("a\nb" ((2 #f))) (scene:state))
  (test-user:press! "M-3 x RET SPC")
  (check-equal? '("axxx\n \nb" ((7 #f))) (scene:state))
  (check-equal? '((editing:self-insert "not a non-negative count")) (scene:press-reports! "M-- x"))
  (scene:show! "abc" 2 4)
  (views:with-view (scene:view) (commands:run editing:self-insert 2 #\é))
  (check-equal? '("aéébcéé" ((4 #f) (8 #f))) (scene:state)))

(test "self-insert raises without a character, and for a value that is not one"
  (test-user:show! "|")
  (check-raises (lambda (c) (and (who-condition? c) (eq? 'editing:self-insert (condition-who c))
                                 (string=? "no character was typed" (condition-message c))))
    (views:with-view (scene:view) (editing:self-insert 1 #f)))
  (check-raises (lambda (c) (and (who-condition? c) (eq? 'editing:self-insert (condition-who c))
                                 (string=? "not a character" (condition-message c))))
    (views:with-view (scene:view) (editing:self-insert 1 "x"))))

(test "RET breaks the line with no indentation where the mode has no indenter, and C-o leaves point before the break"
  (test-user:show! "  one|")
  (test-user:press! "RET")
  (check-equal? "  one\n|" (test-user:text))
  (test-user:show! "ab|c")
  (test-user:press! "C-o")
  (check-equal? "ab|\nc" (test-user:text)))

(test "DEL and C-d delete counts of characters, and say the buffer's edge when nothing is deleted"
  (scene:show! "axxx\n \nb" 7)
  (test-user:press! "M-2 C-d")
  (check-equal? '("axxx\n " ((7 #f))) (scene:state))
  (test-user:press! "M-9 DEL")
  (check-equal? '("" ((1 #f))) (scene:state))
  (check-equal? '((editing:delete-backward-char "beginning of buffer")) (scene:press-reports! "DEL"))
  (check-equal? '((editing:delete-char "beginning of buffer")) (scene:press-reports! "M-- C-d"))
  (test-user:show! "ab|")
  (check-equal? '((editing:delete-char "end of buffer")) (scene:press-reports! "C-d"))
  (check-equal? '((editing:delete-forward-char "end of buffer")) (scene:press-reports! "<delete>"))
  (check-equal? "ab|" (test-user:text))
  (test-user:show! "abcd|")
  (test-user:press! "C-u 2 DEL")
  (check-equal? "ab|" (test-user:text)))

(test "deleting a count of characters kills nothing"
  (kill-ring:push! (list "kept"))
  (test-user:show! "abcd|")
  (test-user:press! "C-u 2 DEL")
  (check-equal? '("kept") (scene:kills 1)))

(test "point stops between grapheme clusters; DEL deletes the code point before point and C-d the cluster after it"
  (scene:show! (string #\a #\e #\x301 #\x1F1EB #\x1F1F7 #\b) 1)
  (check-equal? '(2 4 6) (scene:points-after! "C-f" "C-f" "C-f"))
  (test-user:press! "C-b DEL")
  (check-equal? (list (string #\a #\e #\x1F1EB #\x1F1F7 #\b) '((3 #f))) (scene:state))
  (test-user:press! "C-d")
  (check-equal? '("aeb" ((3 #f))) (scene:state)))

(test "with buffers:stop-inside-clusters, point also stops between a cluster's code points"
  (let ([b (scene:show! (string #\e #\x301 #\x302 #\x) 1)])
    (buffers:with-buffer b (options:set-local! buffers:stop-inside-clusters #t))
    (check-equal? '(2) (scene:points-after! "C-f"))
    (buffers:with-buffer b (options:unset-local! buffers:stop-inside-clusters))
    (check-equal? '(4) (scene:points-after! "C-f"))
    (test-user:press! "M-2 DEL")
    (check-equal? '("ex" ((2 #f))) (scene:state))))

(test "each command's edits to a buffer are one undo group, and typing and deleting join up to 20 runs"
  (scene:show! "\n" 1)
  (test-user:type! "abcdefghijklmnopqrstuvwxy")
  (test-user:press! "C-/")
  (check-equal? '("abcdefghijklmnopqrst\n" ((21 #f))) (scene:state))
  (test-user:press! "C-/")
  (check-equal? '("\n" ((1 #f))) (scene:state))
  (test-user:press! "C-? C-? DEL DEL DEL C-d C-/")
  (check-equal? '("abcdefghijklmnopqrstuv\n" ((23 #f))) (scene:state))
  (test-user:press! "C-/")
  (check-equal? '("abcdefghijklmnopqrstuvwxy\n" ((26 #f))) (scene:state))
  (scene:show! "one\ntwo\n" 4 8)
  (test-user:press! "x C-n y")
  (check-equal? '("onex\ntwoxy\ny" ((11 #f) (13 #f))) (scene:state))
  (test-user:press! "C-/")
  (check-equal? '("onex\ntwox\n" ((10 #f) (11 #f))) (scene:state)))

(test "cursors that meet during a command's edits merge, and every cursor still acts where it was"
  (for-each
    (lambda (points keys after)
      (apply scene:show! "abcd" points)
      (test-user:press! keys)
      (check-equal? after (scene:state)))
    '((2 3) (2 3) (1 2))
    '("DEL" "C-d" "C-d")
    '(("cd" ((1 #f))) ("ad" ((2 #f))) ("cd" ((1 #f))))))

(test "with delete-selection, typing, yanking, pasting and RET replace an active region, and C-d and DEL delete it"
  (scene:with-setting editing:delete-selection #t
    (lambda ()
      (scene:show! "abcd" 1)
      (test-user:press! "S-<right> S-<right> x")
      (check-equal? '("xcd" ((2 #f))) (scene:state))
      (test-user:press! "S-<right> DEL")
      (check-equal? '("xd" ((2 #f))) (scene:state))
      (scene:show! "abcd" 2)
      (kill-ring:push! (list "XY"))
      (test-user:press! "S-<right> C-y")
      (check-equal? '("aXYcd" ((4 #f))) (scene:state))
      (test-user:press! "S-<left> S-<left>")
      (views:with-view (scene:view) (commands:run editing:paste "P"))
      (check-equal? '("aPcd" ((3 #f))) (scene:state))
      (test-user:press! "C-SPC C-b RET")
      (check-equal? '("a\ncd" ((3 #f))) (scene:state))
      (test-user:press! "C-SPC C-b C-d")
      (check-equal? '("acd" ((2 #f))) (scene:state)))))

(test "with delete-selection, an empty region is left alone"
  (scene:with-setting editing:delete-selection #t
    (lambda ()
      (scene:show! "xd" 2)
      (test-user:press! "C-SPC DEL")
      (check-equal? '("d" ((1 #f))) (scene:state)))))

(test "with delete-selection, each cursor's region is replaced, and a yank and a yank-pop put the kill at each"
  (scene:with-setting editing:delete-selection #t
    (lambda ()
      (let ([two-regions! (lambda ()
                            (scene:show! "abcdef" 2 4)
                            (views:set-cursor! (car (views:cursors (scene:view))) 2 4)
                            (views:set-cursor! (cadr (views:cursors (scene:view))) 4 6))])
        (two-regions!)
        (test-user:press! "x")
        (check-equal? '("axxf" ((3 #f))) (scene:state))
        (two-regions!)
        (test-user:press! "DEL")
        (check-equal? '("af" ((2 #f))) (scene:state))
        (two-regions!)
        (kill-ring:push! (list "P"))
        (kill-ring:push! (list "Q"))
        (test-user:press! "C-y")
        (check-equal? '("aQQf" ((3 #f))) (scene:state))
        (test-user:press! "M-y")
        (check-equal? '("aPPf" ((3 #f))) (scene:state))))))

(test "without delete-selection, typing inserts and the region goes"
  (check-equal? #f (editing:delete-selection))
  (scene:show! "acd" 2)
  (test-user:press! "S-<right> x")
  (check-equal? '("acxd" ((4 #f))) (scene:state))
  (scene:show! "abc" 2)
  (views:set-mark! (scene:view) 1)
  (test-user:press! "x")
  (check-equal? '("axbc" ((3 #f))) (scene:state)))

(test "DEL and <delete> delete an active region and kill nothing, but not with a count; C-d deletes a character"
  (check-equal? 'editing:delete-forward-char (commands:command-name (tables:ref keys:global "<delete>")))
  (kill-ring:push! (list "kept"))
  (scene:show! "one two three" 5)
  (test-user:press! "C-SPC M-f DEL")
  (check-equal? '("one  three" ((5 #f))) (scene:state))
  (test-user:press! "C-SPC C-e <delete>")
  (check-equal? '("one " ((5 #f))) (scene:state))
  (check-equal? '("kept") (scene:kills 1))
  (scene:show! "one two" 3)
  (test-user:press! "C-SPC C-f C-f C-d")
  (check-equal? '("one wo" ((5 #f))) (scene:state))
  (scene:show! "abcdef" 1)
  (test-user:press! "C-SPC C-f C-f C-f C-u 2 DEL")
  (check-equal? '("adef" ((2 #f))) (scene:state)))

(test "with delete-active-region off, DEL deletes one character and the region goes"
  (scene:with-setting editing:delete-active-region #f
    (lambda ()
      (scene:show! "abc" 1)
      (test-user:press! "C-SPC C-f C-f DEL")
      (check-equal? '("ac" ((2 #f))) (scene:state)))))

(test "C-g clears the region"
  (scene:show! "abcd" 1)
  (test-user:press! "C-SPC C-f C-f")
  (check-equal? '("abcd" ((3 1))) (scene:state))
  (test-user:press! "C-g")
  (check-equal? '("abcd" ((3 #f))) (scene:state)))

(test "an edit in read-only text is refused, leaving the text, and the command's earlier edits stay"
  (let ([b (scene:show! "one two three" 2 10)])
    (buffers:add-span! (buffers:layer b md:locked) 9 14 'locked)
    (let ([reports (scene:press-reports! "x")])
      (check-equal? 1 (length reports))
      (check (scene:refused? (car reports))))
    (check-equal? '("oxne two three" ((3 #f) (11 #f))) (scene:state))
    (scene:show! "one two" 4)
    (buffers:add-span! (buffers:layer (views:buffer (scene:view)) md:locked) 1 8 'locked)
    (check (scene:refused? (car (scene:press-reports! "x"))))
    (check (scene:refused? (car (scene:press-reports! "DEL"))))
    (check-equal? '("one two" ((4 #f))) (scene:state))))

(test "editing:insert! inserts a text at each cursor of a view, with each point after it, and checks its arguments"
  (scene:show! "ab" 1 2)
  (editing:insert! (scene:view) "xy")
  (check-equal? '("xyaxyb" ((3 #f) (6 #f))) (scene:state))
  (check-raises (lambda (c) (equal? "not a view" (condition-message c))) (editing:insert! 'v "x"))
  (check-raises (lambda (c) (equal? "not a string" (condition-message c))) (editing:insert! (scene:view) 'x)))

(test "editing:insert! replaces a selection while delete-selection is on"
  (scene:with-setting editing:delete-selection #t
    (lambda ()
      (scene:show! "abcd" 2)
      (views:set-mark! (scene:view) 4)
      (editing:insert! (scene:view) "x")
      (check-equal? '("axd" ((3 #f))) (scene:state)))))

(test "paste puts its text on the kill ring and yanks it; it takes a string"
  (scene:show! "ab" 2)
  (views:set-mark! (scene:view) 1)
  (test-user:press! "M-w")
  (views:with-view (scene:view) (commands:run editing:paste "XY"))
  (check-equal? '(("aXYb" ((4 #f))) ("XY" "a")) (list (scene:state) (scene:kills 2)))
  (check-raises (lambda (c) (and (eq? 'editing:paste (condition-who c)) (equal? "not a string" (condition-message c))))
    (editing:paste 'x)))

(test "C-q inserts the next key's character, whatever the key is bound to, and a quit key read so quits nothing"
  (test-user:show! "a|b")
  (test-user:press! "C-q")
  (check-equal? "C-q" (keys:reading (test-user:client)))
  (test-user:press! "TAB")
  (check-equal? '("a\t|b" #f) (list (test-user:text) (keys:reading (test-user:client))))
  (test-user:press! "C-q C-g")
  (check-equal? "a\t\x7;|b" (test-user:text))
  (test-user:press! "C-q C-l C-q a")
  (check-equal? "a\t\x7;\xC;a|b" (test-user:text)))

(test "C-q gives each key its character: itself, the five named keys, and C- with a letter or one of @ [ \\ ] ^ _ SPC ?"
  (check-equal?
    '("x" "é" " " "\t" "\r" "\x1B;" "\x7F;" "\x1;" "\x1;" "\x1A;" "\x0;" "\x0;" "\x1B;" "\x1C;" "\x1D;" "\x1E;" "\x1F;" "\x7F;")
    (map (lambda (key)
           (test-user:show! "|")
           (test-user:press! "C-q")
           (test-user:press! key)
           (scene:text))
         '("x" "é" "SPC" "TAB" "RET" "ESC" "DEL" "C-a" "C-A" "C-z" "C-@" "C-SPC" "C-[" "C-\\" "C-]" "C-^" "C-_" "C-?"))))

(test "C-q raises for any other key and inserts nothing"
  (test-user:show! "a|b")
  (for-each
    (lambda (key)
      (test-user:press! "C-q")
      (check-equal? (list (list 'editing:quoted-insert (string-append key " is not a character")))
        (scene:press-reports! key)))
    '("<f5>" "M-a" "C-ı"))
  (test-user:press! "C-q")
  (check-equal? '((editing:quoted-insert "<mouse-1> is not a character"))
    (scene:reports-during (lambda () (scene:mouse! "click" 2))))
  (check-equal? "a|b" (test-user:text)))

(test "C-q's prefix argument is a count at each cursor, and C-q replaces an active region under delete-selection"
  (scene:show! "ab" 1 2)
  (test-user:press! "C-u 3 C-q x")
  (check-equal? '("xxxaxxxb" ((4 #f) (8 #f))) (scene:state))
  (scene:with-setting editing:delete-selection #t
    (lambda ()
      (scene:show! "abc" 1)
      (test-user:press! "C-SPC C-f C-f C-q TAB")
      (check-equal? '("\tc" ((2 #f))) (scene:state)))))

(test "quoted-insert takes a non-negative count, and with no view current raises before it reads"
  (check-equal? '((editing:quoted-insert "not a non-negative count"))
    (scene:reports-during (lambda () (commands:run editing:quoted-insert -1))))
  (check-equal? '((editing:quoted-insert "no view is current"))
    (scene:reports-during (lambda () (commands:run editing:quoted-insert 1)))))

(test "C-q's character goes to the view selected when the key arrives"
  (test-user:show! "a|b")
  (let ([first (scene:view)])
    (test-user:press! "C-x 2")
    (let ([second (find (lambda (v) (not (eq? v first))) (layout:views))])
      (views:set-buffer! second (buffers:make (buffers:free-name "second") ""))
      (test-user:press! "C-q")
      (layout:select! second)
      (test-user:press! "y")
      (check-equal? '("ab" "y")
        (map (lambda (v) (document:text (buffers:document (views:buffer v)))) (list first second)))
      (layout:select! first)
      (test-user:press! "C-x 1"))))

(commands:define-command (insert-key-name)
  "Inserts the name of the next key typed, such as C-x."
  (let* ([key (keys:read-key)]
         [name (if (keys:event? key) (keys:event-key key) key)]
         [view (views:current)])
    (buffers:replace! (views:buffer view) (views:point view) (views:point view) name)))

(keys:bind! keys:global "C-c n" insert-key-name)

(test "the keys page's example reads the next key, as C-q does"
  (test-user:show! "|")
  (test-user:press! "C-c n C-x")
  (check-equal? "C-x" (scene:text)))

(test "advice on self-insert receives the count and character of each insertion"
  (test-user:show! "one two| three")
  (let ([before (typed:typed)])
    (test-user:press! "a M-3 b SPC")
    (check-equal? 5 (- (typed:typed) before))
    (check-equal? "one twoabbb | three" (test-user:text))))

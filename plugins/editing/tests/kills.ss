(import (tuna) (test) (test-user) (buffers) (views) (kill-ring) (editing) (scene) (md))

(scene:take-said!)

(test "C-k kills to the end of the line, then the line break; kills in a row make one entry"
  (scene:show-marked! "one| two\nthree")
  (test-user:press! "C-k")
  (check-equal? "one|\nthree" (test-user:text))
  (test-user:press! "C-k")
  (check-equal? "one|three" (test-user:text))
  (test-user:press! "C-k")
  (check-equal? "one|" (test-user:text))
  (check-equal? '(" two\nthree") (scene:kills 1))
  (check-equal? '((editing:kill-line "end of buffer")) (scene:press-reports! "C-k")))

(test "C-k kills the line break as well when only spaces and tabs are left"
  (scene:show! "one\n  \nthree" 1)
  (test-user:press! "C-k")
  (check-equal? '(("\n  \nthree" ((1 #f))) ("one")) (list (scene:state) (scene:kills 1)))
  (test-user:press! "C-k")
  (check-equal? '(("  \nthree" ((1 #f))) ("one\n")) (list (scene:state) (scene:kills 1)))
  (test-user:press! "C-f C-k")
  (check-equal? '((" three" ((2 #f))) (" \n")) (list (scene:state) (scene:kills 1)))
  (check-equal? '((editing:kill-line "end of buffer")) (scene:press-reports! "C-e C-k")))

(test "C-k with a count kills whole lines: forward, back to the line's start for 0, back over lines for a negative count"
  (scene:show! "a\nb\nc\nd\n" 5)
  (test-user:press! "C-u C-k")
  (check-equal? '(("a\nb\n" ((5 #f))) ("c\nd\n")) (list (scene:state) (scene:kills 1)))
  (test-user:press! "C-y C-p M-2 C-k")
  (check-equal? '(("a\nb\nc\n" ((7 #f))) ("d\n")) (list (scene:state) (scene:kills 1)))
  (test-user:press! "C-p M-- C-k")
  (check-equal? '(("a\nc\n" ((3 #f))) ("b\n")) (list (scene:state) (scene:kills 1)))
  (test-user:press! "M-0 C-k")
  (check-equal? '(("a\nc\n" ((3 #f))) ("b\n")) (list (scene:state) (scene:kills 1)))
  (check-equal? '((editing:kill-line "end of buffer")) (scene:press-reports! "M-> M-2 C-k"))
  (scene:show! "one two" 5)
  (test-user:press! "C-u 0 C-k")
  (check-equal? '(("two" ((1 #f))) ("one ")) (list (scene:state) (scene:kills 1))))

(test "word kills in a row make one entry, a backward kill before it, and a yank puts it back"
  (scene:show! "one two three four" 19)
  (test-user:press! "M-DEL C-DEL")
  (check-equal? '(("one two " ((9 #f))) ("three four")) (list (scene:state) (scene:kills 1)))
  (test-user:press! "C-y")
  (check-equal? '("one two three four" ((19 #f))) (scene:state))
  (views:set-point! (scene:view) 1)
  (test-user:press! "M-d C-<delete>")
  (check-equal? '((" three four" ((1 #f))) ("one two" "three four")) (list (scene:state) (scene:kills 2)))
  (test-user:press! "C-f M-d")
  (check-equal? '(("  four" ((2 #f))) ("three" "one two" "three four")) (list (scene:state) (scene:kills 3)))
  (scene:show! "word  " 5)
  (test-user:press! "M-d")
  (check-equal? '("word" ((5 #f))) (scene:state)))

(test "M-d twice grows one kill forward; M-DEL twice after another command starts a new kill growing backward"
  (scene:show-marked! "|one two three four")
  (test-user:press! "M-d M-d")
  (check-equal? '("one two") (scene:kills 1))
  (test-user:press! "C-e M-DEL M-DEL")
  (check-equal? " |" (test-user:text))
  (check-equal? '("three four" "one two") (scene:kills 2)))

(test "M-DEL after spaces and line breaks kills them and the word before"
  (scene:show! "one   two" 7)
  (test-user:press! "M-DEL")
  (check-equal? '(("two" ((1 #f))) ("one   ")) (list (scene:state) (scene:kills 1)))
  (scene:show! "one two  \n" 11)
  (test-user:press! "M-DEL")
  (check-equal? '(("one " ((5 #f))) ("two  \n")) (list (scene:state) (scene:kills 1))))

(test "with backward-kill-word-stops-at-whitespace?, M-DEL after whitespace at the primary cursor deletes only it, at each cursor, killing nothing; a count kills words"
  (scene:with-setting editing:backward-kill-word-stops-at-whitespace? #t
    (lambda ()
      (kill-ring:push! (list "two  \n"))
      (scene:show! "one two  \nthree \n" 11 18)
      (test-user:press! "M-DEL")
      (check-equal? '(("one twothree" ((8 #f) (13 #f))) ("two  \n")) (list (scene:state) (scene:kills 1)))
      (test-user:press! "M-DEL")
      (check-equal? '(("one " ((5 #f))) ("two\nthree")) (list (scene:state) (scene:kills 1)))
      (scene:show! "zero one  two" 11)
      (test-user:press! "C-u 2 M-DEL")
      (check-equal? '(("two" ((1 #f))) ("zero one  ")) (list (scene:state) (scene:kills 1))))))

(test "C-w and M-w without a mark say there is no region"
  (scene:show! "one two" 4)
  (check-equal? '((editing:kill-region "the mark is not set, so there is no region")) (scene:press-reports! "C-w"))
  (check-equal? '((editing:kill-ring-save "the mark is not set, so there is no region")) (scene:press-reports! "M-w")))

(test "C-w kills the region; C-y yanks it with point after it, and its mark goes when the command ends"
  (scene:show! "one two three" 4)
  (views:set-mark! (scene:view) 1)
  (test-user:press! "C-w")
  (check-equal? '(" two three" ((1 #f))) (scene:state))
  (views:set-point! (scene:view) 11)
  (test-user:press! "C-y")
  (check-equal? '(" two threeone" ((14 #f))) (scene:state))
  (check-equal? '((editing:exchange-point-and-mark "the mark is not set")) (scene:press-reports! "C-x C-x"))
  (check-equal? '() (scene:take-said!)))

(test "M-w copies the region, leaves the text and ends the region, saying nothing"
  (scene:show! "ab" 1)
  (views:set-mark! (scene:view) 2)
  (test-user:press! "M-w")
  (check-equal? '(("ab" ((1 #f))) ("a")) (list (scene:state) (scene:kills 1)))
  (check-equal? '() (scene:take-said!)))

(test "M-y right after a yank replaces it with the next older kill, a count further; after anything else it raises"
  (scene:show! "ab" 3)
  (kill-ring:push! (list "P"))
  (kill-ring:push! (list "a"))
  (views:set-mark! (scene:view) 2)
  (test-user:press! "M-w C-y")
  (check-equal? '("abb" ((4 #f))) (scene:state))
  (test-user:press! "M-y")
  (check-equal? '("aba" ((4 #f))) (scene:state))
  (test-user:press! "M-y")
  (check-equal? '(("abP" ((4 #f))) ("b")) (list (scene:state) (scene:kills 1)))
  (check-equal? '((editing:yank-pop "the previous command was not a yank")) (scene:press-reports! "C-g M-y")))

(test "C-u 2 M-y goes two kills further, and C-y after M-y yanks the kill M-y left current"
  (kill-ring:push! (list "one"))
  (kill-ring:push! (list "two"))
  (kill-ring:push! (list "three"))
  (scene:show-marked! "x|y")
  (test-user:press! "C-y C-u 2 M-y")
  (check-equal? "xone|y" (test-user:text))
  (test-user:press! "C-y")
  (check-equal? "xoneone|y" (test-user:text)))

(test "C-u C-y leaves point before the yanked text"
  (kill-ring:push! (list "two"))
  (scene:show-marked! "x|y")
  (test-user:press! "C-u C-y")
  (check-equal? "x|twoy" (test-user:text)))

(test "C-u N C-y yanks the kill N - 1 older than the current one, which then is current"
  (kill-ring:push! (list "one"))
  (kill-ring:push! (list "two"))
  (kill-ring:push! (list "three"))
  (scene:show-marked! "x|y")
  (test-user:press! "C-u 2 C-y")
  (check-equal? "xtwo|y" (test-user:text))
  (check-equal? '("two") (kill-ring:current))
  (test-user:press! "M-y")
  (check-equal? "xone|y" (test-user:text)))

(test "M-w after a kill adds to it, as C-w does"
  (scene:show! "one two" 4)
  (test-user:press! "C-k")
  (views:set-mark! (scene:view) 1)
  (test-user:press! "M-w")
  (check-equal? '(" twoone") (scene:kills 1)))

(test "a kill joins the previous command's only when that command killed"
  (scene:show! "ab\ncd" 1)
  (test-user:press! "C-k")
  (scene:press-reports! "C-w")
  (test-user:press! "C-k")
  (check-equal? '("\n" "ab") (scene:kills 2)))

(test "a prefix command leaves the last command, so a kill after C-u joins the kill before it, and M-y after M-2 follows the yank"
  (scene:show! "a\nb\nc\nd\n" 1)
  (test-user:press! "C-k C-u C-k")
  (check-equal? '("a\nb\nc\nd\n") (scene:kills 1))
  (kill-ring:push! (list "older"))
  (kill-ring:push! (list "newer"))
  (scene:show! "x" 1)
  (test-user:press! "C-y M-2 M-y")
  (check-equal? "a\nb\nc\nd\nx" (scene:text)))

(test "a kill at each cursor makes one entry with a kill per cursor, which a yank at as many cursors gives back one each"
  (scene:show! "one!\ntwo!\nthree!\n" 5 10 17)
  (test-user:press! "C-a C-k")
  (check-equal? '(("\n\n\n" ((1 #f) (2 #f) (3 #f))) ("one!\ntwo!\nthree!") 3)
    (list (scene:state) (scene:kills 1) (length (kill-ring:current))))
  (test-user:press! "C-y")
  (check-equal? '("one!\ntwo!\nthree!\n" ((5 #f) (10 #f) (17 #f))) (scene:state))
  (test-user:press! "M->")
  (views:add-cursor! (scene:view) 1)
  (test-user:press! "C-y")
  (check-equal? '("one!\ntwo!\nthree!one!\ntwo!\nthree!\none!\ntwo!\nthree!" ((50 #f) (17 #f))) (scene:state)))

(test "kills that overlap put each text on the ring once, one piece per cursor"
  (scene:show! "one two\nx" 1 5)
  (test-user:press! "C-k")
  (check-equal? '(("\nx" ((1 #f))) ("one two" "")) (list (scene:state) (scene:current-kills)))
  (scene:show! "abcdefgh" 3 5)
  (test-user:press! "C-f")
  (views:set-cursor! (car (views:cursors (scene:view))) 3 7)
  (views:set-cursor! (cadr (views:cursors (scene:view))) 5 1)
  (test-user:press! "C-w")
  (check-equal? '(("gh" ((1 #f))) ("ef" "abcd")) (list (scene:state) (scene:current-kills))))

(test "a duplicate kill is another entry, or with kill-ring:skip-duplicates none"
  (scene:show! "one two" 4)
  (test-user:press! "M-d C-g")
  (scene:show! "one two" 4)
  (test-user:press! "M-d C-g")
  (check-equal? '(" two" " two") (scene:kills 2))
  (scene:with-setting kill-ring:skip-duplicates #t
    (lambda ()
      (let ([entries (length (kill-ring:entries))])
        (scene:show! "one two" 4)
        (test-user:press! "M-d")
        (check-equal? entries (length (kill-ring:entries)))))))

(test "C-k and M-d in read-only text copy without deleting, moving point across what each copied, so repeated kills copy on"
  (scene:show-marked! "one| two\nthree\nfour")
  (scene:lock! 1 19)
  (check (scene:refused? (car (scene:press-reports! "C-k"))))
  (check-equal? '("one two|\nthree\nfour" (" two")) (list (test-user:text) (scene:kills 1)))
  (check (scene:refused? (car (scene:press-reports! "C-k"))))
  (check-equal? "one two\n|three\nfour" (test-user:text))
  (check (scene:refused? (car (scene:press-reports! "C-k"))))
  (check-equal? "one two\nthree|\nfour" (test-user:text))
  (check (scene:refused? (car (scene:press-reports! "M-d"))))
  (check-equal? "one two\nthree\nfour|" (test-user:text))
  (check-equal? '(" two\nthree\nfour") (scene:kills 1)))

(test "C-w in read-only text copies the region and leaves point and the region"
  (scene:show-marked! "one two three|")
  (scene:lock! 1 14)
  (views:set-mark! (scene:view) 4)
  (check (scene:refused? (car (scene:press-reports! "C-w"))))
  (check-equal? '(("one two three" ((14 4))) (" two three")) (list (scene:state) (scene:kills 1))))

(test "a kill puts its text on the ring before an edit the buffer refuses, and at several cursors each copies on"
  (scene:show! "one two three" 1 10)
  (scene:lock! 9 14)
  (check (scene:refused? (car (scene:press-reports! "C-k"))))
  (check-equal? '(("one two three" ((14 #f))) ("one two three\n")) (list (scene:state) (scene:kills 1))))

(test "a kill that removes nothing adds no entry"
  (kill-ring:push! (list "newest"))
  (scene:show! (md:doc '() (md:para '() "Last.\n")) 7)
  (test-user:press! "M-d")
  (check-equal? '("newest") (scene:kills 1)))

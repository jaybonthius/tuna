(import (tuna) (test) (test-user) (tables) (commands) (keys) (views) (buffers) (kill-ring) (editing) (scene))

(scene:take-said!)

(test "C-SPC sets the mark and says so; again at once it clears it, and a third time sets a new one"
  (scene:show! "one two" 4)
  (test-user:press! "C-SPC")
  (check-equal? '((4 4)) (scene:cursors))
  (test-user:press! "C-SPC")
  (check-equal? '((4 #f)) (scene:cursors))
  (test-user:press! "C-SPC")
  (check-equal? '((4 4)) (scene:cursors))
  (check-equal? '("Mark set" "Mark deactivated" "Mark set") (scene:take-said!)))

(test "C-x C-x swaps point and mark, keeping the region, and raises with no mark"
  (scene:show! "abcd" 2)
  (test-user:press! "C-SPC <right> <right>")
  (check-equal? '((4 2)) (scene:cursors))
  (test-user:press! "C-x C-x")
  (check-equal? '((2 4)) (scene:cursors))
  (test-user:press! "C-g")
  (check-equal? '((2 #f)) (scene:cursors))
  (check-equal? '((editing:exchange-point-and-mark "the mark is not set")) (scene:press-reports! "C-x C-x"))
  (test-user:press! "C-SPC C-f C-x C-x")
  (check-equal? '((2 3)) (scene:cursors))
  (scene:take-said!))

(test "after M-w or C-g there is no region for C-x C-x to bring back"
  (scene:show! "one two" 1)
  (test-user:press! "C-SPC M-f M-w")
  (check-equal? '((editing:exchange-point-and-mark "the mark is not set")) (scene:press-reports! "C-x C-x"))
  (test-user:press! "C-SPC M-b C-g")
  (check-equal? '((editing:exchange-point-and-mark "the mark is not set")) (scene:press-reports! "C-x C-x"))
  (scene:take-said!))

(test "C-u C-SPC moves point to the mark and ends the region, and raises with no mark"
  (scene:show! "one two" 4)
  (test-user:press! "C-SPC M-f")
  (check-equal? '((8 4)) (scene:cursors))
  (test-user:press! "C-u C-SPC")
  (check-equal? '((4 #f)) (scene:cursors))
  (check-equal? '((editing:set-mark-command "the mark is not set")) (scene:press-reports! "C-u C-SPC"))
  (check-equal? '((4 #f)) (scene:cursors))
  (check-equal? '("Mark set") (scene:take-said!)))

(test "M-@ marks the end of a word and says so, and again moves the mark a word further, silently"
  (scene:show! "ab cd ef" 1)
  (test-user:press! "M-@")
  (check-equal? '((1 3)) (scene:cursors))
  (test-user:press! "M-@")
  (check-equal? '((1 6)) (scene:cursors))
  (check-equal? '("Mark set") (scene:take-said!))
  (test-user:press! "C-w")
  (check-equal? '(" ef" ((1 #f))) (scene:state)))

(test "C-x h puts point at the start and the mark at the end, removes the other cursors, and says so"
  (scene:show! "one two" 1 5)
  (test-user:press! "C-x h")
  (check-equal? '("one two" ((1 8))) (scene:state))
  (check-equal? '("Mark set") (scene:take-said!))
  (test-user:press! "C-x C-x")
  (check-equal? '((8 1)) (scene:cursors))
  (test-user:press! "C-w")
  (check-equal? '(("" ((1 #f))) ("one two")) (list (scene:state) (scene:kills 1)))
  (check-equal? '((editing:kill-region "the mark is not set, so there is no region")) (scene:press-reports! "C-w")))

(test "an edit clears the marks when its command ends, and C-SPC C-SPC leaves none"
  (scene:show! "abcd" 2)
  (test-user:press! "C-SPC C-f x")
  (check-equal? '("abxcd" ((4 #f))) (scene:state))
  (test-user:press! "C-SPC C-SPC")
  (check-equal? '((4 #f)) (scene:cursors))
  (scene:take-said!))

(commands:define-command (stamp-silently)
  "Writes a stamp silently at the buffer's start."
  (let ([b (views:buffer (views:current))])
    (buffers:with-silent-edits b (buffers:replace! b 1 1 "#"))))

(test "a silent edit is a plugin's own text, not the command's change: the marks stay"
  (scene:show! "axbcd" 3)
  (test-user:press! "C-SPC")
  (views:with-view (scene:view) (commands:run stamp-silently))
  (check-equal? '("#axbcd" ((4 4))) (scene:state))
  (scene:take-said!))

(test "an edit outside a command, as from a job's result, leaves the marks"
  (let ([b (scene:show! "one two" 1)])
    (test-user:press! "C-SPC C-e")
    (buffers:replace! b 1 1 ">")
    (check-equal? '(">one two" ((9 1))) (scene:state))
    (scene:take-said!)))

(test "an edit clears the marks in every view of the buffer; C-g clears only the current view's"
  (scene:show! "one two" 1 5)
  (let ([other (views:make (views:buffer (scene:view)))])
    (views:set-mark! other 3)
    (test-user:press! "C-SPC C-f")
    (check-equal? '("one two" ((2 1) (6 5))) (scene:state))
    (test-user:press! "C-g")
    (check-equal? '(("one two" ((2 #f) (6 #f))) 3) (list (scene:state) (views:mark other)))
    (test-user:press! "C-SPC C-f z")
    (check-equal? '(("onze twzo" ((4 #f) (9 #f))) #f) (list (scene:state) (views:mark other)))
    (views:drop! other))
  (scene:take-said!))

(test "a shifted motion sets a temporary mark, which the next unshifted motion clears"
  (scene:show! "abc def ghi" 1)
  (test-user:press! "M-F")
  (check-equal? '((4 1)) (scene:cursors))
  (test-user:press! "C-S-<right>")
  (check-equal? '((8 1)) (scene:cursors))
  (test-user:press! "C-S-<left>")
  (check-equal? '((5 1)) (scene:cursors))
  (test-user:press! "M-f")
  (check-equal? '((8 #f)) (scene:cursors)))

(test "shift selection says nothing, and an unshifted motion after it ends the region"
  (scene:show! "abcd" 2)
  (test-user:press! "S-<right> S-<right>")
  (check-equal? '((4 2)) (scene:cursors))
  (test-user:press! "C-f")
  (check-equal? '((5 #f)) (scene:cursors))
  (check-equal? '() (scene:take-said!)))

(test "a mark set-mark-command set stays through shifted and unshifted motions, and shift-translated? holds only for the shifted key"
  (scene:show! "abcd" 1)
  (test-user:press! "S-<right> C-F")
  (check-equal? '(((3 1)) #f) (list (scene:cursors) (keys:shift-translated?)))
  (test-user:press! "<right>")
  (check-equal? '((4 #f)) (scene:cursors))
  (test-user:press! "C-SPC <right>")
  (check-equal? '((5 4)) (scene:cursors))
  (test-user:press! "S-<left> <left>")
  (check-equal? '((3 4)) (scene:cursors))
  (test-user:press! "C-g S-<home>")
  (check-equal? '((1 3)) (scene:cursors))
  (test-user:press! "S-<end> C-e")
  (check-equal? '((5 #f)) (scene:cursors))
  (scene:take-said!))

(test "only the mark shift selection set is temporary: one that code set stays, and a swapped temporary region stays temporary"
  (scene:show! "abcdef" 1)
  (test-user:press! "S-<right>")
  (views:set-mark! (scene:view) 4)
  (test-user:press! "C-f")
  (check-equal? '((3 4)) (scene:cursors))
  (scene:show! "abcdef" 1)
  (test-user:press! "S-<right> C-x C-x C-f")
  (check-equal? '((2 #f)) (scene:cursors)))

(test "the mark commands say nothing in a prompt's buffer, nor does C-y, whose mark lasts only the command"
  (scene:show! "one two three" 1)
  (kill-ring:push! (list "y"))
  (test-user:press! "C-SPC C-SPC M-@ M-@ C-x h C-g C-y")
  (check-equal? '("Mark set" "Mark deactivated" "Mark set" "Mark set") (scene:take-said!))
  (views:set-buffer! (scene:view) (buffers:make (buffers:free-name " *prompt*") "abc"))
  (test-user:press! "C-SPC C-SPC C-x h")
  (check-equal? '() (scene:take-said!)))

(test "check-regions raises when a cursor has no mark"
  (scene:show! "one two" 1 5)
  (views:set-cursor! (car (views:cursors (scene:view))) 1 3)
  (check-raises (scene:raised? 'shell "the mark is not set, so there is no region") (editing:check-regions 'shell (scene:view)))
  (views:set-cursor! (cadr (views:cursors (scene:view))) 5 7)
  (check-equal? (void) (editing:check-regions 'shell (scene:view))))

(test "for-each-cursor gives each cursor with its point and mark as they were before the first edit, and place-cursor! places it"
  (scene:show! "ab cd" 2 5)
  (editing:for-each-cursor (scene:view)
    (lambda (c p m)
      (buffers:insert! (views:buffer (scene:view)) p "xy")
      (editing:place-cursor! (scene:view) c p #f)))
  (check-equal? '("axyb cxyd" ((2 #f) (7 #f))) (scene:state)))

(test "place-cursor! does nothing to a cursor no longer the view's"
  (scene:show! "abc" 1 3)
  (let ([gone (cadr (views:cursors (scene:view)))])
    (views:remove-cursor! (scene:view) gone)
    (editing:place-cursor! (scene:view) gone 2 #f)
    (check-equal? '((1 #f)) (scene:cursors))))

(test "the commands that act on a cursor's region when there is one are marked as region commands"
  (check-equal? '(#t #t #t #t #t #t #t #t #t #t #t #t #t)
    (map (lambda (command) (tables:ref commands:region-commands command #f))
         (list editing:kill-region editing:kill-ring-save editing:upcase-region editing:downcase-region
               editing:capitalize-region editing:sort-lines editing:duplicate-dwim editing:move-line-down
               editing:move-line-up editing:delete-trailing-whitespace editing:delete-backward-char
               editing:delete-forward-char editing:indent-for-tab-command))))

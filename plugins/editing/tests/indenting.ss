(import (tuna) (test) (test-user) (options) (hooks) (tables) (commands) (modes) (views) (buffers) (indentation)
        (editing) (scene) (nesting))

(define (nested! text)
  (test-user:show! text)
  (let ([b (views:buffer (scene:view))])
    (modes:set-major-mode nesting:mode b)
    b))

(define (failing-indenter buffer position) (error 'failing-indenter "no rule"))

(commands:define-command (break-line)
  "Calls editing:newline from a command's code."
  (editing:newline 1))

(test "RET in a mode with an indenter indents the new line inside its own command"
  (let* ([ended '()] [note (lambda (command) (set! ended (cons (test-user:text) ended)))])
    (nested! "(a|")
    (hooks:add! commands:after-command note)
    (test-user:press! "RET")
    (hooks:remove! commands:after-command note)
    (check-equal? '("(a\n  |") ended)))

(test "RET reindents the line it ends and deletes the blanks before the break; one undo takes it all back"
  (nested! "(a\n      b  |")
  (test-user:press! "RET")
  (check-equal? "(a\n  b\n  |" (test-user:text))
  (test-user:press! "C-/")
  (check-equal? "(a\n      b  |" (test-user:text))
  (scene:take-said!))

(test "M-2 RET inserts two breaks and indents the last line"
  (nested! "(a|")
  (test-user:press! "M-2 RET")
  (check-equal? "(a\n\n  |" (test-user:text)))

(test "RET indents each cursor's line"
  (nested! "(a|")
  (views:add-cursor! (scene:view) 1)
  (test-user:press! "RET")
  (check-equal? '("\n(a\n  " ((7 #f) (2 #f))) (scene:state)))

(test "with electric-indent off in a buffer, RET only inserts a line break"
  (let ([b (nested! "(a|")])
    (buffers:with-buffer b (options:set-local! editing:electric-indent #f))
    (test-user:press! "RET")
    (check-equal? "(a\n|" (test-user:text))))

(test "with electric-reindent off, RET leaves the indentation of the line it ends, and still deletes the blanks before the break"
  (let ([b (nested! "(a\n      b  |")])
    (buffers:with-buffer b (options:set-local! editing:electric-reindent #f))
    (test-user:press! "RET")
    (check-equal? "(a\n      b\n  |" (test-user:text))))

(test "with a region and delete-selection off, RET breaks the line at point and indents"
  (nested! "(a |b")
  (test-user:press! "C-SPC C-e RET")
  (check-equal? "(a b\n  |" (test-user:text))
  (scene:take-said!))

(test "editing:newline called from a command's code inserts a break alone; run as the command, it indents"
  (nested! "(a|")
  (views:with-view (scene:view) (commands:run break-line))
  (check-equal? "(a\n|" (test-user:text))
  (nested! "(a|")
  (views:with-view (scene:view) (commands:run editing:newline 1))
  (check-equal? "(a\n  |" (test-user:text)))

(test "in a mode with no indenter, RET only breaks the line, and TAB gives a line the indentation of the nearest line above with more than blanks"
  (test-user:show! "    foo bar|")
  (test-user:press! "RET")
  (check-equal? "    foo bar\n|" (test-user:text))
  (test-user:press! "TAB")
  (check-equal? "    foo bar\n    |" (test-user:text))
  (test-user:show! "  a\n\n    \nb|")
  (test-user:press! "TAB")
  (check-equal? "  a\n\n    \n  b|" (test-user:text))
  (test-user:show! "  one\ntw|o")
  (test-user:press! "TAB TAB")
  (check-equal? "  one\n  tw|o" (test-user:text))
  (test-user:show! "   a|")
  (test-user:press! "TAB")
  (check-equal? "a|" (test-user:text)))

(test "TAB indents each cursor's line: a cursor in the indentation ends after it, one in the text keeps its place"
  (scene:show! "(a\nb\n   (c d)" 4 10)
  (modes:set-major-mode nesting:mode (views:buffer (scene:view)))
  (test-user:press! "TAB")
  (check-equal? '("(a\n  b\n  (c d)" ((6 #f) (11 #f))) (scene:state)))

(test "TAB with a region indents the lines it holds, less a last line it ends at the start of, and keeps the cursor's place"
  (nested! "(a\n|b\nc\nd")
  (test-user:press! "C-SPC C-n C-n TAB")
  (check-equal? "(a\n  b\n  c\n|d" (test-user:text))
  (scene:show! "(a\nb\n      c" 4)
  (modes:set-major-mode nesting:mode (views:buffer (scene:view)))
  (views:set-mark! (scene:view) 14)
  (test-user:press! "TAB")
  (check-equal? '("(a\n  b\n  c" ((4 #f))) (scene:state))
  (scene:take-said!))

(test "RET whose indenter raises keeps its line break and indents nothing, without a word; TAB reports the error"
  (nested! "  x|")
  (tables:set! indentation:indenters nesting:mode failing-indenter)
  (check-equal? '() (scene:press-reports! "RET"))
  (check-equal? "  x\n|" (test-user:text))
  (check-equal? '(indentation:line!) (map car (scene:press-reports! "TAB")))
  (tables:set! indentation:indenters nesting:mode nesting:indenter))

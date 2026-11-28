(import (tuna) (test) (test-runner) (test-user) (buffers) (views) (layout) (editing) (processes) (runs)
        (tables) (keys) (commands) (completion) (shell-commands) (shell-commands-test) (editing-test column-region))

(define run shell-commands-test:run)

(define text shell-commands-test:text)

(test "M-| runs the line with the region as input and shows the output as M-! does; with a prefix argument it replaces the region"
  (let ([notes (buffers:make "notes" "c\nb\na\n")])
    (layout:switch-to-buffer notes)
    (views:set-point! (shell-commands-test:view) 1)
    (test-user:press! "C-SPC M->")
    (run shell-commands:shell-command-on-region "sort" #f)
    (check-equal? "a\nb\nc\n" (shell-commands-test:output-text))
    (check-equal? "c\nb\na\n" (text notes))
    (views:set-point! (shell-commands-test:view) 1)
    (test-user:press! "C-SPC M->")
    (run shell-commands:shell-command-on-region "sort" '(4))
    (check-equal? "a\nb\nc\n" (text notes))))

(test "with a prefix argument point is at the start of the replaced text, as C-u M-! leaves it before its output"
  (let ([b (buffers:make "alpha" "alphaINS\n beta")])
    (shell-commands-test:regions! b '(1 9))
    (run shell-commands:shell-command-on-region "tr a A" '(4))
    (check-equal? '("AlphAINS\n beta" ((#f 1))) (list (text b) (shell-commands-test:regions)))))

(test "M-| runs once per cursor's region; with a prefix argument each region gets its own output, point before it and no mark, in one undo group"
  (let ([words (buffers:make "words" "one two three\n")])
    (check-equal? '((1 4) (5 8) (9 14)) (shell-commands-test:regions! words '(1 4) '(5 8) '(9 14)))
    (run shell-commands:shell-command-on-region "tr a-z A-Z" '(4))
    (check-equal? '("ONE TWO THREE\n" ((#f 1) (#f 5) (#f 9))) (list (text words) (shell-commands-test:regions)))
    (test-user:press! "C-/")
    (check-equal? "one two three\n" (text words))))

(test "without a prefix argument the outputs show joined in the cursors' order"
  (let ([words (buffers:make "joined" "one two\n")])
    (shell-commands-test:regions! words '(1 4) '(5 8))
    (run shell-commands:shell-command-on-region "tr a-z A-Z" #f)
    (check-equal? "ONETWO" (shell-commands-test:message))))

(test "a cursor with no mark stops the command before any program runs"
  (layout:switch-to-buffer (buffers:make "unmarked" "text\n"))
  (check-equal? '((shell-commands:shell-command-on-region "the mark is not set, so there is no region"))
                (test-runner:shown-reports-during (lambda () (run shell-commands:shell-command-on-region "touch ran" #f))))
  (check-equal? #f (file-exists? (shell-commands-test:home-path "ran"))))

(test "with a prefix argument every region is asked first whether it takes text, so in a buffer that refuses the programs never run"
  (let ([ended-run (runs:start-for-user "*ended*" "echo some output")])
    (shell-commands-test:ended ended-run)
    (check-equal? '((1 5)) (shell-commands-test:regions! ended-run '(1 5)))
    (check-equal? '((buffers:check-writable "*ended* is read-only"))
                  (test-runner:shown-reports-during
                    (lambda () (run shell-commands:shell-command-on-region "touch $HOME/ran; tr a-z A-Z" '(4)))))
    (check-equal? #f (file-exists? (shell-commands-test:home-path "ran")))))

(test "the regions follow text typed before them while the programs run"
  (let ([typed (buffers:make "typed" "xx aaa bbb\n")])
    (shell-commands-test:regions! typed '(4 7) '(8 11))
    (test-user:press! "C-u M-|")
    (test-user:type! "until [ -e go ]; do sleep 0.05; done; tr a-z A-Z")
    (test-user:press! "RET")
    (buffers:insert! typed 1 "zz")
    (shell-commands-test:touch! "go")
    (test-runner:wait-until (lambda () (string=? (text typed) "zzxx AAA BBB\n")))))

(test "C-g during the second of three runs stops it and replaces nothing"
  (let ([three (buffers:make "three" "aa bb cc\n")])
    (shell-commands-test:regions! three '(1 3) '(4 6) '(7 9))
    (test-user:press! "C-u M-|")
    (test-user:type! "if [ -e seen ]; then sleep 30; else touch seen; fi; tr a-z A-Z")
    (test-user:press! "RET")
    (test-runner:wait-until
      (lambda () (exists (lambda (p) (exists (lambda (a) (string=? a "if [ -e seen ]; then sleep 30; else touch seen; fi; tr a-z A-Z"))
                                             (processes:command-line p)))
                         (processes:all))))
    (test-runner:wait-until (lambda () (file-exists? (shell-commands-test:home-path "seen"))))
    (check (for-all cancelled? (test-runner:reports-during (lambda () (test-user:press! "C-g")))))
    (check-equal? "aa bb cc\n" (text three))
    (test-runner:wait-until (lambda () (null? (processes:all))))))

(test "with the region a rectangle, M-| takes each cursor's input from editing:extract-region, a line break after the last line, and puts the output's lines back through editing:insert-region!"
  (advice-add! views:region-ranges editing-test/column-region:ranges)
  (advice-add! editing:extract-region editing-test/column-region:kill)
  (advice-add! editing:insert-region! editing-test/column-region:insert-region)
  (let ([column (buffers:make "column" "xa1\nxb2\nxc3\n")])
    (shell-commands-test:regions! column '(2 11))
    (check-equal? '((2 . 3) (6 . 7) (10 . 11)) (views:region-bounds (shell-commands-test:view)))
    (run shell-commands:shell-command-on-region "sort -r" #f)
    (check-equal? "c\nb\na\n" (shell-commands-test:output-text))
    (shell-commands-test:regions! column '(2 11))
    (run shell-commands:shell-command-on-region "sort -r" '(4))
    (check-equal? '("xc1\nxb2\nxa3\n" ((#f 2))) (list (text column) (shell-commands-test:regions)))
    (test-user:press! "C-/")
    (check-equal? "xa1\nxb2\nxc3\n" (text column)))
  (advice-remove! views:region-ranges editing-test/column-region:ranges)
  (advice-remove! editing:extract-region editing-test/column-region:kill)
  (advice-remove! editing:insert-region! editing-test/column-region:insert-region))

(test "| in completion's region action keymap pipes the region, and the command is a region command"
  (check-equal? shell-commands:shell-command-on-region (keys:lookup-in (list completion:region-action-keymap) "|"))
  (check-equal? #t (tables:ref commands:region-commands shell-commands:shell-command-on-region #f))
  (check-equal? (list shell-commands:shell-command shell-commands:shell-command-on-region shell-commands:async-shell-command)
                (map (lambda (k) (keys:lookup-in (list keys:global) k)) '("M-!" "M-|" "M-&"))))

(import (tuna) (test) (test-runner) (hooks) (options) (buffers) (document) (views) (layout) (modes) (files)
        (processes) (runs) (test-user) (runs-test))

(define home runs-test:home)

(define ends '())

(hooks:add! runs:ended (lambda (b end) (set! ends (cons (list (buffers:name b) end (runs:status b)) ends))))

(define (taken-ends) (let ([e (reverse ends)]) (set! ends '()) e))

(define (view-element v)
  (let ([id (number->string (views:id v))])
    (find (lambda (e) (equal? id (test-user:element-attribute e "data-view")))
          (test-user:elements-with (test-user:screen) "data-view"))))

(define (faced b)
  (let ([v (layout:selected-view)])
    (views:set-buffer! v b)
    (test-user:settle)
    (map (lambda (e) (list (test-user:element-attribute e "data-face") (test-user:element-text e)))
         (test-user:elements-with (view-element v) "data-face"))))

(test "a run writes a header, the output and a footer into a buffer of its own, in runs:mode, silent and unmodified"
  (let ([b (runs:start-for-user "*run*" "printf 'one\\ntwo\\n'" home)])
    (check-equal? #f (runs:status b))
    (check-equal? 0 (runs-test:ended b))
    (check-equal? '("Run started at TIME in ~/" "" "printf 'one\\ntwo\\n'" "one" "two" "" "Run finished at TIME, after S s")
                  (runs-test:lines b))
    (check-equal? '(runs:mode #t #f #t "printf 'one\\ntwo\\n'")
                  (list (modes:major-mode b) (buffers:silent? b) (buffers:modified? b) (runs:run-buffer? b) (runs:command b)))
    (check-equal? '(("*run*" 0 0)) (taken-ends))
    (check-equal? '("*run* finished") (runs-test:take-said!))))

(test "runs:shell is the program SHELL names, else /bin/sh, then -c"
  (check-equal? (list (or (getenv "SHELL") "/bin/sh") "-c") (options:default runs:shell)))

(test "a list command runs with no shell, and the header shows its words quoted"
  (let ([b (runs:start-for-user "*list*" '("printf" "%s\\n" "it's") home)])
    (check-equal? 0 (runs-test:ended b))
    (check-equal? '("Run started at TIME in ~/" "" "printf '%s\\n' 'it'\\''s'" "it's" "" "Run finished at TIME, after S s")
                  (runs-test:lines b))
    (check-equal? '("printf" "%s\\n" "it's") (runs:command b))
    (check-equal? (string-append (getenv "HOME") "/") (files:directory b))
    (taken-ends)
    (runs-test:take-said!)))

(test "shell-quote-argument leaves a plain word alone and quotes the rest; command-text joins a list's words"
  (check-equal? '("a-b_c.d/e=f:g,h+i@j%k" "'it'\\''s here.py'" "''")
                (map runs:shell-quote-argument '("a-b_c.d/e=f:g,h+i@j%k" "it's here.py" "")))
  (check-equal? "python3 'it'\\''s here.py'" (runs:command-text '("python3" "it's here.py")))
  (check-equal? "ls | wc" (runs:command-text "ls | wc")))

(test "output is decoded across pieces, a carriage return before a line feed goes, text after one replaces its line, and a backspace deletes"
  (let ([run! (lambda (name line)
                (let ([b (runs:start-for-user name line home)])
                  (runs-test:ended b)
                  (runs-test:output b)))])
    (check-equal? "b\nc" (run! "*carriage-a*" "printf 'a\\rb\\r\\nc\\n'"))
    (check-equal? "X" (run! "*carriage-b*" "printf 'abc\\r'; sleep 0.2; printf 'X\\n'"))
    (check-equal? "done" (run! "*carriage-c*" "printf '50%%\\r'; sleep 0.1; printf '60%%\\r'; sleep 0.1; printf 'done\\n'"))
    (check-equal? "ac\nd" (run! "*carriage-d*" "printf 'ab\\bc\\n\\bd\\n'"))
    (check-equal? "€ \xFFFD;!" (run! "*carriage-e*" "printf '\\342'; sleep 0.2; printf '\\202\\254 \\377!\\n'"))
    (check-equal? "a\x7;b" (run! "*carriage-f*" "printf 'a\\007b\\n'")))
  (taken-ends)
  (runs-test:take-said!))

(test "SGR sequences style the output and other control sequences go; with runs:colors? false the text stays plain"
  (let ([colored (runs:start-for-user "*colors*" "printf '\\033[1;31mred\\033[0m \\033[2Kplain\\n'" home)])
    (runs-test:ended colored)
    (check-equal? "red plain" (runs-test:output colored))
    (check (member '("ansi-colors.red" "red") (faced colored)))
    (check-equal? '(("success" "finished")) (filter (lambda (f) (string=? (cadr f) "finished")) (faced colored))))
  (options:set! runs:colors? #f)
  (let ([bare (runs:start-for-user "*bare*" "printf '\\033[1;31mred\\033[0m\\n'" home)])
    (runs-test:ended bare)
    (check-equal? "red" (runs-test:output bare))
    (check-equal? '() (filter (lambda (f) (string=? (cadr f) "red")) (faced bare))))
  (options:unset! runs:colors?)
  (taken-ends)
  (runs-test:take-said!))

(test "a failed run's end is its exit code or signal, its footer in faces:error, said in the echo area"
  (let ([end-of (lambda (line)
                  (let ([b (runs:start-for-user "*end*" line home)])
                    (list (runs-test:ended b) (runs-test:take-said!))))])
    (check-equal? '(2 ("*end* exited with code 2")) (end-of "exit 2"))
    (check-equal? '(-9 ("*end* ended by signal 9")) (end-of "kill -9 $$")))
  (let ([b (buffers:find "*end*")])
    (check-equal? '("Run started at TIME in ~/" "" "kill -9 $$" "" "Run ended by signal 9 at TIME") (runs-test:lines b))
    (check-equal? '(("error" "ended by signal 9")) (faced b)))
  (check-equal? '(("*end*" 2 2) ("*end*" -9 -9)) (taken-ends)))

(test "a program that cannot start is reported, and its end is that condition"
  (let* ([missing #f]
         [reports (test-runner:reports-during
                    (lambda ()
                      (set! missing (runs:start-for-user "*end*" '("no-such-program-at-all" "it's") home))
                      (runs-test:ended missing)))])
    (check-equal? '(spawn-process) (map condition-who reports))
    (check (condition? (runs:status missing)))
    (check-equal? '("Run started at TIME in ~/" "" "no-such-program-at-all 'it'\\''s'" ""
                    "Run could not start: cannot run no-such-program-at-all: No such file or directory")
                  (runs-test:lines missing))
    (check-equal? '("*end* could not start") (runs-test:take-said!))
    (check (for-all (lambda (e) (condition? (cadr e))) (taken-ends)))))

(test "runs:stop ends a run at once, stopped, with its footer, its entries and its message; a second stop raises"
  (let ([long (runs:start-for-user "*long*" "echo going; sleep 30" home)])
    (test-runner:wait-until (lambda () (string=? (runs-test:output long) "going\n")))
    (check-equal? #f (runs:status long))
    (check-equal? (string-append (getenv "HOME") "/") (files:directory long))
    (runs:stop long)
    (check-equal? '(stopped (("*long*" stopped stopped)) ("*long* stopped")) (list (runs:status long) (taken-ends) (runs-test:take-said!)))
    (check-equal? '("Run started at TIME in ~/" "" "echo going; sleep 30" "going" "" "Run stopped at TIME") (runs-test:lines long))
    (check-equal? '(("warning" "stopped")) (faced long))
    (check-equal? '(runs:stop "the run has ended" ("*long*")) (runs-test:raised (lambda () (runs:stop long))))
    (check-equal? (string-append (getenv "HOME") "/") (files:directory long))))

(test "C-c C-k stops the run of the buffer shown"
  (let ([long (runs:start-for-user "*long*" "echo going; sleep 30" home)])
    (test-runner:wait-until (lambda () (string=? (runs-test:output long) "going\n")))
    (layout:switch-to-buffer long)
    (test-user:press! "C-c C-k")
    (check-equal? 'stopped (runs:status long))
    (taken-ends)
    (runs-test:take-said!)))

(test "a new run in a going run's buffer asks, then stops the old run, whose entries see the buffer still holding it"
  (let ([long (runs:start-for-user "*long*" "echo first; sleep 30" home)] [asked #f] [seen #f])
    (test-runner:wait-until (lambda () (string=? (runs-test:output long) "first\n")))
    (taken-ends)
    (let ([look (lambda (b end) (unless seen (set! seen (list end (runs:status b) (runs-test:output b)))))])
      (hooks:add! runs:ended look)
      (options:set! ask:yes-or-no-reader (lambda (q) (set! asked q) #t))
      (let ([again (runs:start-for-user "*long*" "echo second" home)])
        (check-equal? (list #t "A run is going in *long*; stop it? " '(stopped stopped "first")) (list (eq? again long) asked seen))
        (check-equal? 0 (runs-test:ended again))
        (check-equal? "second" (runs-test:output again)))
      (hooks:remove! runs:ended look)
      (options:unset! ask:yes-or-no-reader))
    (check-equal? '(("*long*" stopped stopped) ("*long*" 0 0)) (taken-ends))
    (runs-test:take-said!)))

(test "answering no keeps the going run and raises; runs:always-stop? stops it without asking"
  (let ([long (runs:start-for-user "*long*" "echo first; sleep 30" home)] [asked #f])
    (test-runner:wait-until (lambda () (string=? (runs-test:output long) "first\n")))
    (options:set! ask:yes-or-no-reader (lambda (q) (set! asked q) #f))
    (check-equal? 'runs:start-for-user (car (runs-test:raised (lambda () (runs:start-for-user "*long*" "echo second" home)))))
    (check-equal? '(#f "first\n") (list (runs:status long) (runs-test:output long)))
    (set! asked #f)
    (options:set! runs:always-stop? #t)
    (let ([again (runs:start-for-user "*long*" "echo third" home)])
      (check-equal? '(#f 0 "third") (list asked (runs-test:ended again) (runs-test:output again))))
    (options:unset! runs:always-stop?)
    (options:unset! ask:yes-or-no-reader)
    (check-equal? '(("*long*" stopped stopped) ("*long*" 0 0)) (taken-ends))
    (runs-test:take-said!)))

(test "killing a going run's buffer stops it without asking; its entries get the end and nothing is said"
  (let ([doomed (runs:start-for-user "*doomed*" "sleep 30" home)] [asked #f])
    (options:set! ask:yes-or-no-reader (lambda (q) (set! asked q) #f))
    (buffers:kill! doomed)
    (options:unset! ask:yes-or-no-reader)
    (check-equal? '(#f #f (("*doomed*" stopped stopped)) ()) (list (buffers:live? doomed) asked (taken-ends) (runs-test:take-said!)))
))

(test "the buffer refuses the user's edits and stays silent and unmodified, an output-written entry's splice included"
  (let ([mark (lambda (b start end) (buffers:splice! b end end (document:from-datum "!")))] [written '()])
    (hooks:add! runs:output-written mark)
    (hooks:add! runs:output-written (lambda (b start end) (set! written (cons (buffers:text-between (buffers:document b) start end) written))))
    (let ([quiet (runs:start-for-user "*quiet*" "echo x" home)])
      (runs-test:ended quiet)
      (hooks:remove! runs:output-written mark)
      (check-equal? '("x\n!" #t #f) (list (runs-test:output quiet) (buffers:silent? quiet) (buffers:modified? quiet)))
      (check (member "x\n" written))
      (check-equal? 'buffers:insert! (car (runs-test:raised (lambda () (buffers:insert! quiet 1 "typed")))))
      (layout:switch-to-buffer quiet)
      (check-equal? '("a is undefined")
                    (map condition-message (test-runner:reports-during (lambda () (test-user:press! "a")))))))
  (taken-ends)
  (runs-test:take-said!))

(test "a buffer that shows no run is never taken, and the arguments are checked"
  (buffers:make "*plain*" "keep\n")
  (check-equal? '(runs:start-for-user "a live buffer that shows no run has the name" ("*plain*"))
                (runs-test:raised (lambda () (runs:start-for-user "*plain*" "true"))))
  (check-equal? '(runs:start "not a non-empty command line or list of strings" (""))
                (runs-test:raised (lambda () (runs:start "*x*" ""))))
  (check-equal? '(runs:start "not a mode derived from runs:mode" (modes:fundamental))
                (runs-test:raised (lambda () (runs:start "*x*" "true" home modes:fundamental))))
  (check-equal? '(runs:status "the buffer shows no run")
                (list-head (runs-test:raised (lambda () (runs:status (buffers:find "*plain*")))) 2))
  (check-equal? '(runs:stop "the buffer shows no run")
                (list-head (runs-test:raised (lambda () (runs:stop (buffers:find "*plain*")))) 2))
  (check-equal? #f (buffers:find "*x*")))

(test "runs:environment takes processes' rule for a variable and reaches the program over Tuna's environment"
  (check-equal? 'options:set! (car (runs-test:raised (lambda () (options:set! runs:environment '(("A=B" . "x")))))))
  (check-equal? 'options:set! (car (runs-test:raised (lambda () (options:set! runs:environment '(("" . "x")))))))
  (let ([b (runs:start-for-user "*env*" "echo \"$TERM,$PAGER,$EXTRA\"" (processes:options [directory "~/"] [environment '(("EXTRA" . "yes"))]))])
    (runs-test:ended b)
    (check-equal? "dumb,,yes" (runs-test:output b)))
  (taken-ends)
  (runs-test:take-said!))

(test "a start processes refuses leaves no buffer, or the run's buffer as it was, and the name free"
  (check-equal? 'processes:start-for-user (car (runs-test:raised (lambda () (runs:start-for-user "*r*" (list "printf" "a\x0;b") home)))))
  (check-equal? #f (buffers:find "*r*"))
  (let ([b (runs:start-for-user "*r*" "echo kept" home)])
    (runs-test:ended b)
    (check-equal? 'processes:start-for-user (car (runs-test:raised (lambda () (runs:start-for-user "*r*" (list "printf" "a\x0;b") home)))))
    (check-equal? '("kept" 0 "echo kept") (list (runs-test:output b) (runs:status b) (runs:command b))))
  (let ([b (runs:start-for-user "*r*" "echo next" home)])
    (runs-test:ended b)
    (check-equal? "next" (runs-test:output b)))
  (taken-ends)
  (runs-test:take-said!))

(test "options other than a directory and an environment are refused, leaving no buffer"
  (check-equal? '(runs:start-for-user "options other than a directory and an environment")
                (list-head (runs-test:raised (lambda () (runs:start-for-user "*c*" "true" (processes:options [separate-stderr #t])))) 2))
  (check-equal? '(runs:start "options other than a directory and an environment")
                (list-head (runs-test:raised (lambda () (runs:start "*c*" "true" (processes:options [terminal (cons 24 80)])))) 2))
  (check-equal? '(runs:start "options other than a directory and an environment")
                (list-head (runs-test:raised (lambda () (runs:start "*c*" "true" (processes:options [full-log (processes:full-log drop)])))) 2))
  (check-equal? #f (buffers:find "*c*")))

(test "a file buffer's folder is its file's: runs' entry in files:directory-finders answers only for a run's buffer"
  (mkdir (runs-test:home-path "src"))
  (let ([file (files:visit "~/src/a.txt")])
    (check-equal? (list (runs-test:home-path "src/") #f) (map (lambda (entry) (entry file)) (hooks:entries files:directory-finders)))
    (check-equal? (runs-test:home-path "src/") (files:directory file))))

(test "under runs:follow-output?, views showing the buffer when the run starts begin at the end and stay after the output"
  (let ([show-run (lambda (b) (layout:switch-to-buffer b))] [v (layout:selected-view)])
    (hooks:add! runs:started show-run)
    (options:set! runs:follow-output? #t)
    (let ([meter (runs:start-for-user "*meter*" "printf 'a\\n10%%'; sleep 0.2; printf '\\r20%%'; sleep 0.2; printf '\\rdone\\n'" home)])
      (check-equal? meter (views:buffer v))
      (runs-test:ended meter)
      (check-equal? "a\ndone" (runs-test:output meter))
      (check-equal? (- (document:length (buffers:document meter)) 1) (views:point v)))
    (options:unset! runs:follow-output?)
    (let ([quiet (runs:start-for-user "*meter*" "printf 'b\\n'; sleep 0.2; printf 'c\\n'" home)])
      (runs-test:ended quiet)
      (check-equal? 1 (views:point v)))
    (hooks:remove! runs:started show-run))
  (taken-ends)
  (runs-test:take-said!))

(test "g in a run's buffer runs its command again as the user's run"
  (let ([b (runs:start-for-user "*again*" "printf 'b\\n'; sleep 0.2; printf 'c\\n'" home)])
    (runs-test:ended b)
    (layout:switch-to-buffer b)
    (taken-ends)
    (test-user:press! "g")
    (check-equal? 0 (runs-test:ended b))
    (check-equal? '("b\nc" #t) (list (runs-test:output b) (eq? (buffers:with-buffer b (buffers:revert-function)) runs:run-again)))
    (check-equal? '(("*again*" 0 0)) (taken-ends))
    (runs-test:take-said!)))

(test "runs:tell-end says nothing once removed from runs:ended"
  (hooks:remove! runs:ended runs:tell-end)
  (runs-test:ended (runs:start-for-user "*told*" "true" home))
  (check-equal? '() (runs-test:take-said!))
  (hooks:add! runs:ended runs:tell-end)
  (taken-ends))

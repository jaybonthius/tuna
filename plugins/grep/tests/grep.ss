(import (tuna) (test) (test-user) (test-runner) (options) (kill-ring) (processes) (buffers) (document) (views) (layout) (files)
        (minibuffer) (completion) (completion-list) (actions) (grep)
        (completion-test sessions) (completion-test picking) (file-picker-test tree) (grep-test programs) (projects-test trees))

(define (view) (layout:selected-view))

(define (visit! name) (layout:switch-to-buffer (files:visit (file-picker-test/tree:path name))))

(define (session) (completion-test/picking:session))

(define (choices) (completion-test/picking:choices))

(define (quit!) (check-equal? '(cancelled) (completion-test/picking:quit!)))

(define (here)
  (let ([b (views:buffer (view))])
    (list (buffers:name b) (document:line (buffers:document b) (views:point (view))))))

(define (count) (completion:matches-count (completion:session-matches (session))))

(define (with-program name thunk)
  (options:set! grep:command-line (list (grep-test/programs:path name)))
  (thunk)
  (options:unset! grep:command-line))

(define (grep-in-view location) (views:call-with-view (view) (lambda () (grep:grep location))))

(test "M-s r searches with rg, which leaves out hidden and binary files and links; the input after # filters the lines found; RET visits the line"
  (visit! "src/text.txt")
  (test-user:press! "M-s r")
  (test-user:type! "ne")
  (check-equal? '() (choices))
  (test-user:type! "edle")
  (check-equal? '("text.txt:1:needle one" "text.txt:3:needle two") (choices))
  (test-user:type! "#two")
  (check-equal? '("text.txt:3:needle two") (choices))
  (completion-test/picking:press-until-ended! "RET" grep:grep)
  (check-equal? '("text.txt" 3) (here)))

(define (clear-input!)
  (unless (string=? "" (completion-test/sessions:input))
    (test-user:press! "C-a C-k")))

(define (search typed)
  (clear-input!)
  (test-user:type! typed)
  (choices))

(test "words match in any order, each a regular expression; the components from one starting with - are rg's options; with -F the words are one fixed string"
  (visit! "src/text.txt")
  (test-user:press! "M-s r")
  (check-equal? '("text.txt:3:needle two") (search "tw.* need"))
  (check-equal? '("text.txt:3:needle two") (search "tw.* need -A1"))
  (check-equal? '("text.txt:3:needle two") (search "needle two -F"))
  (check-equal? '() (search "two needle -F"))
  (check-equal? '("text.txt-1-needle one" "text.txt:2:hay") (search "hay -B1"))
  (quit!))

(define (reports-during thunk) (completion-test/picking:reports-during thunk))


(test "the first line rg writes to its standard error is reported"
  (visit! "src/text.txt")
  (test-user:press! "M-s r")
  (check-equal? '((grep:grep "rg: regex parse error:"))
                (map (lambda (c) (list (condition-who c) (condition-message c)))
                     (reports-during (lambda () (test-user:type! "needle(") (choices)))))
  (quit!))

(define (running name)
  (find (lambda (p) (string=? (grep-test/programs:path name) (car (processes:command-line p)))) (processes:all)))

(test "lines show as rg prints them; a new search stops the running rg at once and keeps the lines found until its own come; a quit stops it too"
  (visit! "src/text.txt")
  (with-program "slow-rg"
    (lambda ()
      (test-user:press! "M-s r")
      (test-user:type! "first")
      (test-runner:wait-until (lambda () (= 1 (count))))
      (let ([slow (running "slow-rg")])
        (check-equal? (list '("a.txt:1:first") #t #f (module-owner '(grep)))
                      (list (completion-test/sessions:texts (session)) (completion:session-busy? (session))
                            (processes:status slow) (processes:owner slow)))
        (test-user:type! "s")
        (test-runner:wait-until (lambda () (processes:status slow)))
        (check-equal? '("a.txt:1:first") (completion-test/sessions:texts (session)))
        (test-runner:wait-until (lambda () (let ([p (running "slow-rg")]) (and p (not (eq? p slow))))))
        (let ([slower (running "slow-rg")])
          (quit!)
          (test-runner:wait-until (lambda () (processes:status slower))))))))

(test "RET chooses the line whose text is the input, among the thousands a broad search found"
  (visit! "src/text.txt")
  (with-program "many-rg"
    (lambda ()
      (test-user:press! "M-s r")
      (test-user:type! "line")
      (check-equal? 5000 (length (choices)))
      (test-user:type! "#many.txt:4321:line 4321")
      (completion-test/picking:press-until-ended! "RET" grep:grep)
      (check-equal? (file-picker-test/tree:path "src/many.txt") (files:path (views:buffer (view)))))))

(test "lines group by file under the path rg printed, each row the line's number and text; a round of lines goes at the end of the same matches"
  (visit! "src/text.txt")
  (with-program "grouped-rg"
    (lambda ()
      (test-user:press! "M-s r")
      (test-user:type! "any")
      (test-runner:wait-until (lambda () (= 1 (count))))
      (let ([first (completion:session-matches (session))])
        (test-runner:wait-until (lambda () (= 3 (count))))
        (check (eq? first (completion:session-matches (session)))))
      (choices)
      (let ([s (session)])
        (check-equal? '(("a.txt" "1:one a") ("a.txt" "2:two a") ("sub/b.txt" "1:one b") ("sub/b.txt" "2:two b"))
                      (map (lambda (m) (list (completion:title s m) (completion:row-text s m))) (completion-test/sessions:matches s))))
      (quit!))))

(test "M-w and the actions take a line's whole text as rg printed it, without the search; the filter matches the path too"
  (visit! "src/text.txt")
  (with-program "grouped-rg"
    (lambda ()
      (test-user:press! "M-s r")
      (test-user:type! "any")
      (choices)
      (test-user:press! "M-w")
      (check-equal? "a.txt:1:one a" (kill-ring:text (kill-ring:current)))
      (test-user:type! "#two")
      (check-equal? "a.txt:2:two a" (completion-test/picking:selected))
      (test-user:press! "M-w")
      (check-equal? "a.txt:2:two a" (kill-ring:text (kill-ring:current)))
      (kill-ring:push! (list "other"))
      (test-user:press! "C-.")
      (check-equal? '(cancelled) (map (lambda (c) (if (cancelled? c) 'cancelled c))
                                      (reports-during (lambda () (test-user:press! "w")))))
      (check-equal? "a.txt:2:two a" (kill-ring:text (kill-ring:current)))
      (test-user:press! "M-s r")
      (test-user:type! "any#b")
      (choices)
      (let ([s (session)])
        (check-equal? '(("sub/b.txt" "1:one b" ((6 7))) ("sub/b.txt" "2:two b" ((6 7))))
                      (map (lambda (m) (list (completion:title s m) (completion:row-text s m)
                                             (map (lambda (span) (list-head span 2)) (completion:spans s m))))
                           (completion-test/sessions:matches s))))
      (quit!))))

(test "lines of a file that come after another file's are matched again with its earlier ones, so a file's lines stay together"
  (visit! "src/text.txt")
  (with-program "interleaved-rg"
    (lambda ()
      (test-user:press! "M-s r")
      (test-user:type! "any")
      (test-runner:wait-until (lambda () (= 3 (count))))
      (check-equal? (list #t '("a.txt:1:one a" "a.txt:2:two a" "b.txt:1:one b"))
                    (list (completion:session-busy? (session)) (completion-test/sessions:texts (session))))
      (quit!))))

(test "without rg each search reports that it cannot run, with the arguments, where a backslash before a word's - keeps it a word"
  (visit! "src/text.txt")
  (options:set! grep:command-line (list "no-such-rg"))
  (test-user:press! "M-s r")
  (let ([reported (lambda (typed)
                    (map (lambda (c) (list (condition-message c) (condition-irritants c)))
                         (reports-during (lambda () (clear-input!) (test-user:type! typed) (choices)))))])
    (check-equal? '(("cannot run no-such-rg: No such file or directory" ("no-such-rg" ("-e" "needle" "."))))
                  (reported "needle"))
    (check-equal? '(("cannot run no-such-rg: No such file or directory" ("no-such-rg" ("-e" "-1" "-F" "."))))
                  (reported "\\-1 -F")))
  (quit!)
  (options:unset! grep:command-line))

(test "the filter after # matches inside a line found with the default styles, and its words in any order with completion:any-order"
  (visit! "src/text.txt")
  (test-user:press! "M-s r")
  (check-equal? '("text.txt:3:needle two") (search "needle#two"))
  (quit!)
  (options:set! completion:styles (list completion:any-order))
  (test-user:press! "M-s r")
  (check-equal? '("text.txt:3:needle two") (search "needle#two text"))
  (check-equal? '("text.txt:3:needle two") (search "needle#text two"))
  (quit!)
  (options:unset! completion:styles))

(test "in a project M-s r searches from its root, and a file in a git submodule searches its parent repository's project"
  (projects-test/trees:run! "code" "git" "init" "-q" "tuna")
  (projects-test/trees:write-file! "code/tuna/lib/sub/.git" "gitdir: ../../.git/modules/lib/sub\n")
  (projects-test/trees:write-file! "code/tuna/lib/sub/deep.sls" "(define needle 1)\n")
  (projects-test/trees:write-file! "code/tuna/top.sls" "(define top 1)\n")
  (visit! "code/tuna/lib/sub/deep.sls")
  (test-user:press! "M-s r")
  (check-equal? '("lib/sub/deep.sls:1:(define needle 1)" "top.sls:1:(define top 1)") (list-sort string<? (search "define")))
  (search "define top")
  (completion-test/picking:press-until-ended! "RET" grep:grep)
  (check-equal? '("top.sls" 1) (here)))

(test "a location past the file's last line goes to its end, and line 0 to its start"
  (let ([deep (file-picker-test/tree:path "code/tuna/lib/sub/deep.sls")])
    (grep-in-view (cons* deep 99 0))
    (check-equal? "(define needle 1)\n|" (test-user:text))
    (grep-in-view (cons* deep 0 0))
    (check-equal? "|(define needle 1)\n" (test-user:text))))

(test "while a prompt waits, its locked view is selected, so the file shows in another view, where point moves"
  (visit! "src/text.txt")
  (let ([r (completion-test/sessions:start! (lambda () (minibuffer:read "Name: ")))])
    (check (minibuffer:buffer? (views:buffer (view))))
    (grep-in-view (cons* (file-picker-test/tree:path "src/text.txt") 3 0))
    (check-equal? '("text.txt" 3) (here))
    (test-user:press! "C-g")
    (check-raises cancelled? (completion-test/sessions:result r))))

(test "a location carries rg's column counted in characters, and grep goes to it; a context line's column is 0, one past the line's end goes to its end"
  (file-picker-test/tree:make-folder! "columns")
  (file-picker-test/tree:write-file! "columns/c.txt" "héllo needle\n  needle\nafter\n")
  (visit! "columns/c.txt")
  (test-user:press! "M-s r")
  (search "needle -A1")
  (let ([s (session)])
    (check-equal? '(("c.txt:1:héllo needle" 1 . 6) ("c.txt:2:  needle" 2 . 2) ("c.txt-3-after" 3 . 0))
                  (map (lambda (m) (cons (completion:text s m) (cdr (completion:value s m)))) (completion-test/sessions:matches s))))
  (completion-test/picking:press-until-ended! "RET" grep:grep)
  (check-equal? "héllo |needle\n  needle\nafter\n" (test-user:text))
  (grep-in-view (cons* (file-picker-test/tree:path "columns/c.txt") 2 2))
  (check-equal? "héllo needle\n  |needle\nafter\n" (test-user:text))
  (grep-in-view (cons* (file-picker-test/tree:path "columns/c.txt") 3 40))
  (check-equal? "héllo needle\n  needle\nafter|\n" (test-user:text)))

(test "several words are one look-ahead at the line's start, so the location's column is the line's start"
  (visit! "columns/c.txt")
  (test-user:press! "M-s r")
  (search "needle h")
  (let ([s (session)])
    (check-equal? '(("c.txt:1:héllo needle" 1 . 0))
                  (map (lambda (m) (cons (completion:text s m) (cdr (completion:value s m)))) (completion-test/sessions:matches s))))
  (completion-test/picking:press-until-ended! "RET" grep:grep)
  (check-equal? "|héllo needle\n  needle\nafter\n" (test-user:text)))

(define (open-files) (list-sort string<? (map buffers:name (files:buffers))))

(test "the selected line is previewed in the view the search started from; a quit puts the view back and kills the buffers the previews opened"
  (visit! "notes/a.txt")
  (let* ([v (view)] [before (open-files)]
         [place (lambda () (let ([b (views:buffer v)]) (list (buffers:name b) (document:line (buffers:document b) (views:point v)))))])
    (test-user:press! "M-s r")
    (check-equal? '("a.txt:2:beta define-record x" "sub/b.sls:1:define-record here") (search "define-record --sort=path"))
    (test-runner:wait-until (lambda () (equal? (place) '("a.txt" 2))))
    (test-user:press! "C-n")
    (test-runner:wait-until (lambda () (equal? (place) '("b.sls" 1))))
    (check (member "b.sls" (open-files)))
    (quit!)
    (check-equal? (list '("a.txt" 1) before) (list (place) (open-files)))))

(test "choosing a line keeps its file's buffer, and records the place left, so M-, returns"
  (visit! "notes/a.txt")
  (test-user:press! "M-s r")
  (search "define-record --sort=path")
  (test-user:press! "C-n")
  (completion-test/picking:press-until-ended! "RET" grep:grep)
  (check-equal? '("b.sls" 1) (here))
  (test-user:press! "M-,")
  (check-equal? '("a.txt" 1) (here))
  (test-user:press! "M-s r")
  (search "define-record --sort=path")
  (test-user:press! "C-n C-p")
  (completion-test/picking:press-until-ended! "RET" grep:grep)
  (check-equal? '("a.txt" 2) (here))
  (test-user:press! "M-,")
  (check-equal? '("a.txt" 1) (here)))

(test "with grep:preview-delay a line is shown once it has stayed selected that long"
  (options:set! grep:preview-delay 0.3)
  (visit! "notes/a.txt")
  (let* ([v (view)] [place (lambda () (let ([b (views:buffer v)]) (list (buffers:name b) (document:line (buffers:document b) (views:point v)))))])
    (test-user:press! "M-s r")
    (search "define-record --sort=path")
    (test-user:press! "C-n")
    (check-equal? '("a.txt" 1) (place))
    (test-runner:wait-until (lambda () (equal? (place) '("b.sls" 1))))
    (quit!))
  (options:unset! grep:preview-delay))

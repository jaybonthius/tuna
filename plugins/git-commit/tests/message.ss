(import (tuna) (test) (test-user) (test-runner) (hooks) (options) (saved) (modes) (buffers) (document) (views) (layout)
        (layout-split) (editing) (files) (ui) (git) (git-mode) (git-status) (with-editor) (git-commit) (git-status-test)
        (git-test repositories))

(define repo (git-status-test:fresh! "repo"))

(define (message!) (let ([m (git-status-test:wait-until-shown "COMMIT_EDITMSG")]) (git-status-test:take-said!) m))

(define (message-lines m)
  (let ([t (document:text (buffers:document m))])
    (let loop ([i 0] [start 0] [acc '()])
      (cond
        [(= i (string-length t)) (reverse acc)]
        [(char=? #\newline (string-ref t i))
         (if (and (< start i) (char=? #\# (string-ref t start)))
             (reverse acc)
             (loop (+ i 1) (+ i 1) (cons (substring t start i) acc)))]
        [else (loop (+ i 1) start acc)]))))

(define (set-message! m text)
  (let* ([t (document:text (buffers:document m))]
         [end (let loop ([i 0]) (if (or (= i (string-length t)) (char=? #\# (string-ref t i))) i (loop (+ i 1))))])
    (buffers:replace! m 1 (+ end 1) text)))

(define (last-canceled?) (git:command-canceled? (car (reverse (git:commands repo)))))

(define (faces)
  (map (lambda (e) (list (test-user:element-attribute e "data-face") (test-user:element-text e)))
       (filter (lambda (e) (let ([f (test-user:element-attribute e "data-face")]) (and f (> (string-length f) 0))))
               (test-user:elements-with (git-status-test:drawn) "data-face"))))

(define press! git-status-test:press-done!)

(define hooked 0)

(hooks:add! git-commit:mode-hook (lambda () (set! hooked (+ hooked 1))))

(test "git-commit:mode-hook runs in each message buffer as it opens; C-c C-k cancels, the view showing the status buffer again, the message saved and the cancel no Git error"
  (press! "c c")
  (let ([m (message!)])
    (check-equal? 1 hooked)
    (buffers:replace! m 1 1 "First draft\n")
    (git-status-test:press! "C-c C-k")
    (check-equal? '("*git: repo*" ("Commit canceled. Message saved") "First draft" #t)
                  (list (git-status-test:shown-buffer) (git-status-test:take-said!) (car (git-commit:messages)) (last-canceled?)))))

(test "M-p brings back older messages and M-n newer ones; past the oldest it raises No previous message"
  (press! "c c")
  (buffers:replace! (message!) 1 1 "Second draft\n")
  (git-status-test:press! "C-c C-k")
  (press! "c c")
  (let ([m (message!)])
    (check-equal? '(("Second draft") ("First draft") ("Second draft"))
                  (map (lambda (keys) (press! keys) (message-lines m)) '("M-p" "M-p" "M-n")))
    (press! "M-p")
    (check-equal? '("No previous message") (git-status-test:press-reporting-messages! "M-p"))
    (check-equal? '("First draft") (message-lines m))))

(test "C-c M-s saves the message without finishing"
  (let ([m (git-status-test:wait-until-shown "COMMIT_EDITMSG")])
    (set-message! m "Saved\n")
    (press! "C-c M-s")
    (check-equal? "Saved" (car (git-commit:messages)))))

(test "the trailer keys insert a trailer with the user's name and email at the end of the message; C-c C-i reads one; C-u reads the value"
  (let ([m (git-status-test:wait-until-shown "COMMIT_EDITMSG")])
    (press! "C-c C-s")
    (check-equal? '("Saved" "" "Signed-off-by: Tuna <tuna@example.org>") (message-lines m))
    (git-status-test:answer! "Reviewed-by" "Ada <ada@example.org>")
    (press! "C-c C-i")
    (git-status-test:answer! "Bob" "bob@example.org")
    (press! "C-u C-c C-a")
    (check-equal? '("Saved" "" "Signed-off-by: Tuna <tuna@example.org>" "Reviewed-by: Ada <ada@example.org>" "Acked-by: Bob <bob@example.org>")
                  (message-lines m))
    (check-equal? '("Trailer: " "Value: " "Name: " "Email: ") (git-status-test:take-asked!))))

(test "the summary, the part past git-commit:summary-max-length, trailer keys and git's comments are drawn in their faces"
  (let ([m (git-status-test:wait-until-shown "COMMIT_EDITMSG")])
    (options:set! git-commit:summary-max-length 4)
    (buffers:replace! m 1 1 "X")
    (let ([drawn (faces)])
      (check-equal? '(("git-commit.summary" "XSav") ("git-commit.overlong-summary" "ed")) (list-head drawn 2))
      (check-equal? '("Signed-off-by:" "Reviewed-by:" "Acked-by:")
                    (map cadr (filter (lambda (f) (equal? "git-commit.trailer-key" (car f))) drawn)))
      (check (exists (lambda (f) (equal? "comment" (car f))) drawn)))
    (views:unfold! (git-status-test:view) (- (document:length (buffers:document m)) 2))
    (check (exists (lambda (f) (equal? "diff.minus" (car f))) (faces)))
    (check (exists (lambda (f) (equal? "diff.plus" (car f))) (faces)))
    (options:unset! git-commit:summary-max-length)
    (buffers:replace! m 1 2 "")))

(test "C-c C-w is undefined"
  (check-equal? '("C-c C-w is undefined") (git-status-test:press-reporting-messages! "C-c C-w")))

(test "C-c C-c with a non-empty second line asks, n keeping the buffer; overlong-summary-line asks of a long summary; C-u C-c C-c skips the checks"
  (let ([m (git-status-test:wait-until-shown "COMMIT_EDITMSG")])
    (set-message! m "Summary\nnot blank\n")
    (git-status-test:answer! #f)
    (press! "C-c C-c")
    (check-equal? '(("Second line is not empty.  Commit anyway? ") "COMMIT_EDITMSG")
                  (list (git-status-test:take-asked!) (git-status-test:shown-buffer)))
    (options:set! git-commit:style-checks (list (git-commit:style-check overlong-summary-line)))
    (set-message! m (string-append (make-string 70 #\s) "\n"))
    (git-status-test:answer! #f)
    (press! "C-c C-c")
    (check-equal? '(("Summary line is too long.  Commit anyway? ") "COMMIT_EDITMSG")
                  (list (git-status-test:take-asked!) (git-status-test:shown-buffer)))
    (options:unset! git-commit:style-checks)
    (set-message! m "Forced\nnot blank\n")
    (git-status-test:press! "C-u C-c C-c")
    (check-equal? '(() "*git: repo*" "Forced")
                  (list (git-status-test:take-asked!) (git-status-test:shown-buffer)
                        (substring (git-status-test:git-out "repo" "log" "-1" "--format=%s") 0 6)))))

(test "a cancel check that returns #f keeps the buffer, and C-u C-c C-k skips it"
  (let ([keep (lambda (b) #f)])
    (press! "c - e c")
    (message!)
    (hooks:add! with-editor:cancel-checks keep)
    (press! "C-c C-k")
    (check-equal? "COMMIT_EDITMSG" (git-status-test:shown-buffer))
    (git-status-test:press! "C-u C-c C-k")
    (check-equal? "*git: repo*" (git-status-test:shown-buffer))
    (hooks:remove! with-editor:cancel-checks keep)))

(test "killing the buffer another way cancels, saving the message"
  (press! "c - e c")
  (let ([m (message!)])
    (buffers:replace! m 1 1 "Killed draft\n")
    (buffers:kill! m)
    (git-status-test:settle!)
    (check-equal? '("Killed draft" #t ("Commit canceled. Message saved"))
                  (list (car (git-commit:messages)) (last-canceled?) (git-status-test:take-said!)))))

(test "finishing with only comments and whitespace is git's abort, said as a cancel"
  (press! "c - e c")
  (message!)
  (git-status-test:press! "C-c C-c")
  (check-equal? '(("Commit canceled") #t) (list (git-status-test:take-said!) (last-canceled?))))

(test "git-commit:messages keeps the newest 32, as saved data"
  (saved:set! git-commit:messages (append (map (lambda (i) (format "m~a" i)) (iota 40)) (git-commit:messages)))
  (press! "c - e c")
  (buffers:replace! (message!) 1 1 "Newest\n")
  (git-status-test:press! "C-c C-k")
  (check-equal? '(32 "Newest") (list (length (git-commit:messages)) (car (git-commit:messages))))
  (test-runner:wait-until (lambda () (file-exists? (git-status-test:path ".local/share/tuna/saved/tuna/git-commit/messages.ss")))))

(test "visiting a message file in a git folder any other way gives it git-commit:major-mode and git-commit:mode; one outside a git folder gets neither"
  (git-test/repositories:write-file! "repo/.git/TAG_EDITMSG" "tag\n")
  (let ([t (files:visit (git-status-test:path "repo/.git/TAG_EDITMSG"))])
    (check-equal? '(modes:fundamental #t) (list (modes:major-mode t) (buffers:with-buffer t (git-commit:mode)))))
  (git-test/repositories:write-file! "repo/TAG_EDITMSG" "not git's\n")
  (check-equal? #f (buffers:with-buffer (files:visit (git-status-test:path "repo/TAG_EDITMSG")) (git-commit:mode))))

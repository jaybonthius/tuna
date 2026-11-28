#!tuna
(import (hooks) (options) (commands) (ask) (modes) (buffers) (document) (views) (layout) (ui) (git) (git-mode) (git-status)
        (test-runner) (test-user) (ui-test) (git-test repositories))

(define (path name) (git-test/repositories:path name))

(define (read-file name) (call-with-input-file (path name) get-string-all))

(define (git-out folder . arguments) (utf8->string (apply git-test/repositories:git! folder arguments)))

(define (short folder . paths) (apply git-out folder "status" "--short" paths))

(define %answers '())

(define %asked '())

(define %said '())

(define (answer! . answers) (set! %answers (append %answers answers)))

(define (%next-answer question)
  (set! %asked (cons question %asked))
  (when (null? %answers)
    (error 'git-status-test:answer "no answer" question))
  (let ([a (car %answers)]) (set! %answers (cdr %answers)) a))

(define (take-asked!) (let ([s (reverse %asked)]) (set! %asked '()) s))

(define (take-said!) (let ([s (reverse %said)]) (set! %said '()) s))

(define (numbers from to)
  (if (> from to) "" (string-append (number->string from) "\n" (numbers (+ from 1) to))))

;; Commits Tuna makes need the repository's own identity, as the test's
;; home has no git configuration.
(define (sample! name)
  (let ([origin (string-append "origin-" name ".git")] [file (lambda (f) (string-append name "/" f))]
        [git! git-test/repositories:git!] [write-file! git-test/repositories:write-file!])
    (git! "" "init" "-q" "--bare" "-b" "main" origin)
    (git! "" "init" "-q" "-b" "main" name)
    (git! name "config" "user.name" "Tuna")
    (git! name "config" "user.email" "tuna@example.org")
    (write-file! (file "a.py") (numbers-text '("one" "two" "three" "four" "five" "six" "seven" "eight" "nine" "ten")))
    (write-file! (file "b.txt") (numbers-text '("alpha" "beta" "gamma" "delta" "epsilon" "zeta" "eta" "theta")))
    (write-file! (file "gone.txt") "bye\n")
    (git! name "add" "-A")
    (git! name "commit" "-qm" "First commit")
    (git! name "remote" "add" "origin" (string-append "../" origin))
    (git! name "push" "-q" "-u" "origin" "main")
    (write-file! (file "a.py") (numbers-text '("one" "two" "three" "four" "five" "six" "seven" "eight" "nine" "ten" "eleven")))
    (git! name "commit" "-qam" "Second commit")
    (write-file! (file "a.py") (numbers-text '("one" "TWO" "three" "four" "five" "six" "seven" "eight" "NINE" "ten" "eleven")))
    (write-file! (file "b.txt") (numbers-text '("alpha" "BETA" "gamma" "delta" "epsilon" "zeta" "eta" "theta")))
    (git! name "add" "b.txt")
    (write-file! (file "b.txt") (numbers-text '("alpha" "BETA" "gamma" "delta" "epsilon" "zeta" "ETA" "theta")))
    (delete-file (path (file "gone.txt")))
    (write-file! (file "new.txt") "fresh\n")
    (git:find-repository (path name))))

(define (numbers-text lines) (apply string-append (map (lambda (l) (string-append l "\n")) lines)))

(define (fresh! name)
  (for-each buffers:kill! (filter git-status:buffer? (buffers:all)))
  (let ([repo (sample! name)])
    (git-test/repositories:write-file! (string-append name "/long.txt") (numbers 1 20))
    (git-test/repositories:git! name "add" "long.txt")
    (git-test/repositories:git! name "commit" "-qm" "long" "--" "long.txt")
    (git-test/repositories:write-file! (string-append name "/long.txt") (string-append "1\nTWO\n" (numbers 3 17) "EIGHTEEN\n19\n20\n"))
    (git-status:show repo)
    (settle!)
    repo))

(define (view) (layout:selected-view))

(define (status-buffer) (find git-status:buffer? (buffers:all)))

(define (git-buffers) (filter (lambda (b) (modes:derived? (modes:major-mode b) git-mode:mode)) (buffers:all)))

(define (shown-buffer) (let ([b (views:buffer (view))]) (and b (buffers:name b))))

;; A message buffer opens when git's editor request arrives, which no
;; event marks, so this waits for it to be shown.
(define (wait-until-shown name)
  (test-runner:wait-until (lambda () (equal? name (shown-buffer))))
  (test-user:settle)
  (views:buffer (view)))

(define (status) (ui-test:visible (view)))

(define (section . identity) (ui:find-section (views:buffer (view)) identity))

(define (go-to-section! . identity)
  (views:set-point! (view) (ui:section-heading-start (apply section identity))))

(define (%go-to-between! text from to)
  (let* ([doc (buffers:document (views:buffer (view)))]
         [chars (let loop ([p from] [acc '()])
                  (cond
                    [(= p to) (reverse acc)]
                    [(char? (document:token doc p)) (loop (+ p 1) (cons (cons p (document:token doc p)) acc))]
                    [else (loop (+ p 1) acc)]))]
         [k (string-length text)])
    (let loop ([cs chars])
      (cond
        [(< (length cs) k) (error 'git-status-test:go-to! "not found" text)]
        [(string=? text (list->string (map cdr (list-head cs k)))) (views:set-point! (view) (caar cs))]
        [else (loop (cdr cs))]))))

(define (go-to-in! text . identity)
  (let ([s (apply section identity)]) (%go-to-between! text (document:node-start s) (document:node-end s))))

(define (go-to! text) (%go-to-between! text 0 (document:length (buffers:document (views:buffer (view))))))

(define (point-line)
  (let* ([v (view)] [doc (buffers:document (views:buffer v))] [start (document:line-start doc (document:line doc (views:point v)))])
    (let loop ([q start] [acc '()])
      (let ([t (and (< q (document:length doc)) (document:token doc q))])
        (cond
          [(or (not t) (eqv? t #\newline)) (list->string (reverse acc))]
          [(char? t) (loop (+ q 1) (cons t acc))]
          [else (loop (+ q 1) acc)])))))

(define (show-files! . lists)
  (for-each
    (lambda (l)
      (ui:show-section! (view) (section l))
      (for-each (lambda (f) (ui:show-section! (view) f)) (ui:section-children (section l))))
    lists))

(define (drawn)
  (test-user:settle)
  (let ([id (number->string (views:id (view)))])
    (find (lambda (e) (equal? id (test-user:element-attribute e "data-view")))
          (test-user:elements-with (test-user:screen) "data-view"))))

(define (contains? s part)
  (let loop ([i 0])
    (and (<= (+ i (string-length part)) (string-length s))
         (or (string=? part (substring s i (+ i (string-length part)))) (loop (+ i 1))))))

(define (row-button list heading title)
  (let* ([list-element (find (lambda (e) (equal? list (test-user:element-attribute e "data-type")))
                             (test-user:elements (drawn) "ui-section"))]
         [heading-element (find (lambda (e) (contains? (test-user:element-text e) heading))
                                (test-user:elements list-element "ui-section-heading"))])
    (find (lambda (b) (equal? title (test-user:element-attribute b "title")))
          (test-user:elements heading-element "git-apply-button"))))

(define (click-button! list heading title)
  (test-user:click-element! (row-button list heading title))
  (settle!))

;; A key's command runs in a task of its own and git in processes, so
;; this waits until every command has ended, no git command of a Git
;; buffer's repository is queued, and those buffers are current.
(define %commands 0)

(define (settle!)
  (test-user:settle)
  (let ([repositories (map (lambda (b) (buffers:with-buffer b (git-mode:repository))) (git-buffers))])
    (test-runner:wait-until (lambda () (and (= %commands 0) (not (exists git:queued? repositories))))))
  (for-each git-mode:wait-until-current (git-buffers))
  (test-user:settle))

(define (press! keys) (test-user:press! keys) (settle!))

;; For keys that leave git running, as in a message buffer git waits
;; for: waits only until their commands have ended.
(define (press-done! keys)
  (test-user:press! keys)
  (test-runner:wait-until (lambda () (= %commands 0)))
  (test-user:settle))

(define (reports-during thunk)
  (map (lambda (c) (if (cancelled? c) 'cancelled (list (condition-who c) (condition-message c)))) (test-runner:reports-during thunk)))

(define (press-reporting! keys) (reports-during (lambda () (press! keys))))

(define (press-reporting-messages! keys)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons (condition-message c) reported)))])
    (advice-add! report keep)
    (press-done! keys)
    (advice-remove! report keep)
    (reverse reported)))

(hooks:add! commands:before-command (lambda (command) (set! %commands (+ %commands 1))))
(hooks:add! commands:after-command (lambda (command) (set! %commands (- %commands 1))))

(options:set! ask:message-writer (lambda (text) (set! %said (cons text %said))))
(options:set! ask:y-or-n-reader %next-answer)
(options:set! ask:line-reader (case-lambda [(q) (%next-answer q)] [(q d) (%next-answer q)]))
(options:set! ask:line-with-candidates-reader (lambda (q candidates default) (%next-answer q)))
(options:set! ask:file-name-reader (case-lambda [(q) (%next-answer q)] [(q f) (%next-answer q)]))

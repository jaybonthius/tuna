(import (tuna) (test) (test-user) (buffers) (document) (views) (layout) (layout-split) (editing) (files) (ui) (git) (git-mode)
        (git-status) (git-status-test) (git-test repositories))

(define repo (git-status-test:fresh! "repo"))

(define status-view (git-status-test:view))

(define (at-line)
  (let* ([v (git-status-test:view)] [doc (buffers:document (views:buffer v))] [p (views:point v)])
    (list (git-status-test:shown-buffer) (document:line doc p) (document:column doc p))))

(define (back!) (layout:select! status-view) (layout:switch-to-buffer (git-status-test:status-buffer)))

(define (visit! keys) (git-status-test:press! keys) (at-line))

(define (visit-from! keys text . identity)
  (back!)
  (apply git-status-test:go-to-in! text identity)
  (visit! keys))

(ui:show-section! status-view (git-status-test:section '(file . "a.py") '(unstaged . #f)))
(ui:show-section! status-view (git-status-test:section '(file . "b.txt") '(staged . #f)))

(test "RET on an unstaged file visits it in the selected view at its first changed line"
  (git-status-test:go-to-section! '(file . "a.py") '(unstaged . #f))
  (check-equal? '("a.py" 2 0) (visit! "RET"))
  (check (eq? status-view (git-status-test:view))))

(test "RET on an added line visits its line at the column after the prefix; on a removed line, the line that follows the removal"
  (back!)
  (git-status-test:go-to-in! "+NINE" '(file . "a.py") '(unstaged . #f))
  (test-user:press! "C-f C-f")
  (check-equal? '("a.py" 9 1) (visit! "RET"))
  (check-equal? '("a.py" 2 0) (visit-from! "RET" "-two" '(file . "a.py") '(unstaged . #f))))

(test "RET, C-j and C-RET on a staged line visit the working tree's file at the line that corresponds"
  (for-each (lambda (keys) (check-equal? '("b.txt" 2 0) (visit-from! keys "+BETA" '(file . "b.txt") '(staged . #f))))
            '("RET" "C-j" "C-RET")))

(test "a staged line past unstaged hunks visits the working tree's line, moved by them"
  (git-test/repositories:write-file! "repo/long.txt" (string-append "0\n" (git-status-test:numbers 1 20)))
  (git-test/repositories:git! "repo" "add" "long.txt")
  (git-test/repositories:write-file! "repo/long.txt" (string-append "a\nb\n0\n" (git-status-test:numbers 1 20)))
  (git-mode:refresh-repository repo)
  (back!)
  (ui:show-section! status-view (git-status-test:section '(file . "long.txt") '(staged . #f)))
  (check-equal? '("long.txt" 3 0) (visit-from! "RET" "+0" '(file . "long.txt") '(staged . #f))))

(test "C-u RET visits in another view and selects it"
  (back!)
  (git-status-test:go-to-section! '(file . "a.py") '(unstaged . #f))
  (check-equal? '("a.py" 2 0) (visit! "C-u RET"))
  (check (not (eq? status-view (git-status-test:view))))
  (check (eq? (git-status-test:status-buffer) (views:buffer status-view))))

(test "RET on a deleted file visits its path, an empty buffer; on an untracked file, the file"
  (back!)
  (git-status-test:go-to-section! '(file . "gone.txt") '(unstaged . #f))
  (git-status-test:press! "RET")
  (check-equal? '("gone.txt" "") (list (git-status-test:shown-buffer) (document:text (buffers:document (views:buffer (git-status-test:view))))))
  (back!)
  (ui:show-section! status-view (git-status-test:section '(untracked . #f)))
  (git-status-test:go-to-section! '(file . "new.txt") '(untracked . #f))
  (git-status-test:press! "RET")
  (check-equal? "new.txt" (git-status-test:shown-buffer)))

(test "RET on a list heading, a header or a commit raises Cannot determine file to visit"
  (back!)
  (let ([refused (lambda () (check-equal? '((git-status:visit "Cannot determine file to visit")) (git-status-test:press-reporting! "RET")))])
    (git-status-test:go-to-section! '(unstaged . #f))
    (refused)
    (git-status-test:press! "M-<")
    (refused)
    (git-status-test:go-to-in! "Second commit" '(unpushed . "@{upstream}"))
    (refused)))

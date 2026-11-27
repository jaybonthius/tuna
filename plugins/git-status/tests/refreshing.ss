(import (tuna) (test) (test-user) (test-runner) (hooks) (buffers) (views) (layout) (layout-split) (editing) (files) (ui) (git)
        (git-mode) (git-status) (git-status-test) (git-test repositories))

(define repo (git-status-test:fresh! "repo"))

(define (listed? name) (and (member name (git-status-test:status)) #t))

(test "saving a file refreshes nothing, unless git-status:refresh-after-save is in files:after-save"
  (ui:show-section! (git-status-test:view) (git-status-test:section '(untracked . #f)))
  (git-test/repositories:write-file! "repo/r4.txt" "r4\n")
  (let ([c (files:visit (git-status-test:path "repo/r4.txt"))])
    (buffers:insert! c 1 "top\n")
    (files:save-buffer c)
    (git-status-test:settle!)
    (check (not (listed? "r4.txt")))
    (hooks:add! files:after-save git-status:refresh-after-save)
    (buffers:insert! c 1 "top\n")
    (files:save-buffer c)
    (test-runner:wait-until (lambda () (listed? "r4.txt")))
    (hooks:remove! files:after-save git-status:refresh-after-save)))

(test "while a refresh runs the buffer keeps its contents and its keys work, until the new contents come in one rewrite"
  (let* ([b (git-status-test:status-buffer)] [edits 0]
         [count! (lambda (edited e) (when (eq? edited b) (set! edits (+ edits 1))))])
    (hooks:add! buffers:after-edit count!)
    (git-test/repositories:write-file! "repo/r8.txt" "r8\n")
    (let* ([before (git-status-test:status)]
           [refreshing (spawn-task (lambda (restore) (git-mode:refresh-repository repo)))])
      (check-equal? (list before 0) (list (git-status-test:status) edits))
      (test-user:press! "n")
      (test-runner:join refreshing)
      (hooks:remove! buffers:after-edit count!)
      (check-equal? '(2 #t) (list edits (listed? "r8.txt"))))))

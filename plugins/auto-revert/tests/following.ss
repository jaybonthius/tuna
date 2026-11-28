(import (tuna) (test) (test-runner) (test-user) (options) (hooks) (tables) (modes) (auto-mode) (document) (buffers)
        (views) (layout) (layout-split) (files) (auto-revert) (files-test) (file-watch-test) (auto-revert-test))

(define (home name) (file-watch-test:home name))

(file-watch-test:write! "a.txt" "a\n")
(file-watch-test:write! "b.txt" "b\n")

(define a (files:visit (home "a.txt")))
(define b (files:visit (home "b.txt")))

(test "auto-revert:mode set to #f in one buffer leaves that buffer alone when its file changes, while other buffers still reload; turning it on again checks the file once"
  (buffers:with-buffer a (options:set-local! auto-revert:mode #f))
  (file-watch-test:write! "a.txt" "a changed\n")
  (file-watch-test:write! "b.txt" "b changed\n")
  (auto-revert-test:wait-for-text b "b changed\n")
  (check-equal? "a\n" (auto-revert-test:text a))
  (buffers:with-buffer a (options:unset-local! auto-revert:mode))
  (auto-revert-test:wait-for-text a "a changed\n"))

(test "a file visited after the plugin loads is watched and checked: a change made on disk at once is reloaded"
  (file-watch-test:write! "c.txt" "c\n")
  (let ([c (files:visit (home "c.txt"))])
    (file-watch-test:write! "c.txt" "c changed\n")
    (auto-revert-test:wait-for-text c "c changed\n")))

(test "a buffer whose file files:rename-file renames is followed at the new path"
  (files:rename-file (home "a.txt") (home "renamed.txt"))
  (file-watch-test:write! "renamed.txt" "renamed changed\n")
  (auto-revert-test:wait-for-text a "renamed changed\n"))

(test "killing a buffer ends its watch, and its folder's inotify watch goes with the last buffer there"
  (file-watch-test:folder! "solo")
  (file-watch-test:write! "solo/s.txt" "s\n")
  (let* ([before (auto-revert-test:inotify-watches)] [s (files:visit (home "solo/s.txt"))])
    (check-equal? (+ before 1) (auto-revert-test:inotify-watches))
    (buffers:kill! s)
    (check-equal? before (auto-revert-test:inotify-watches))))

(hooks:define-hook log-mode-hook "Called in each buffer that turns on the test's log mode.")

(tables:define-table log-mode-keymap "Keys in the test's log mode.")

(modes:define-major-mode log-mode (lighter "Log") (keymap log-mode-keymap) (hook log-mode-hook))

(define (no-auto-revert) (options:set-local! auto-revert:mode #f))

(test "buffers whose major mode's hook sets auto-revert:mode locally to #f are never watched"
  (hooks:add! log-mode-hook no-auto-revert)
  (tables:set! auto-mode:file-names "log" log-mode)
  (file-watch-test:folder! "logs")
  (file-watch-test:write! "logs/x.log" "x\n")
  (let ([before (auto-revert-test:inotify-watches)])
    (check (eq? log-mode (modes:major-mode (files:visit (home "logs/x.log")))))
    (check-equal? before (auto-revert-test:inotify-watches))))

(test "while a task reverts the buffer, a check waits its turn and finds the file as that task read it, so nothing more happens"
  (let ([reverts 0])
    (define (count buffer) (set! reverts (+ reverts 1)))
    (hooks:add! files:after-revert count)
    (files-test:take-said!)
    (file-watch-test:write! "b.txt" "b by task\n")
    (files:revert-from-file b)
    (auto-revert:check b)
    (check-equal? '(1 "b by task\n" ()) (list reverts (auto-revert-test:text b) (files-test:take-said!)))
    (hooks:remove! files:after-revert count)))

(test "two clients both draw a reload, and two views of the buffer each keep their own cursor"
  (let* ([other (test-user:open-client)] [v (auto-revert-test:show! b)])
    (test-user:press! "C-x 2")
    (let ([w (car (remq v (layout:views)))])
      (views:set-point! v 2)
      (views:set-point! w 4)
      (file-watch-test:write! "b.txt" "b by task, again\n")
      (auto-revert-test:wait-for-text b "b by task, again\n")
      (test-user:settle)
      (for-each
        (lambda (client)
          (for-each
            (lambda (view)
              (let ([drawn (find (lambda (e) (equal? (number->string (views:id view)) (test-user:element-attribute e "data-view")))
                                 (test-user:elements-with (test-user:screen client) "data-view"))])
                (check-equal? (number->string (buffers:version b)) (test-user:element-attribute drawn "data-version"))))
            (list v w)))
        (list (test-user:client) other))
      (check-equal? '(2 4) (map views:point (list v w)))
      (test-user:press! "C-x 1"))))

(test "auto-revert:check reloads an unmodified buffer whose file changed, marks a modified one Stale without touching its text, and clears the mark once the file is as read"
  (options:set! auto-revert:use-notify? #f auto-revert:interval 1000)
  (file-watch-test:write! "b.txt" "checked\n")
  (auto-revert:check b)
  (check-equal? "checked\n" (auto-revert-test:text b))
  (buffers:replace! b 1 1 "mine ")
  (file-watch-test:write! "b.txt" "checked again\n")
  (auto-revert:check b)
  (check-equal? '("mine checked\n" #t) (list (auto-revert-test:text b) (auto-revert:stale? b)))
  (file-watch-test:write! "b.txt" "checked\n")
  (auto-revert:check b)
  (check-equal? '("mine checked\n" #f) (list (auto-revert-test:text b) (auto-revert:stale? b)))
  (check-raises assertion-violation? (auto-revert:check 'b))
  (options:unset! auto-revert:use-notify? auto-revert:interval)
  (files:not-modified b))

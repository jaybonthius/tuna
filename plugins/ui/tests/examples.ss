(import (tuna) (test) (test-user) (test-runner) (web) (layout) (views) (buffers) (document) (keys) (commands) (editing) (undo)
        (ui) (ui-test))

(define view ui-test:view)

(call-with-output-file (string-append (getenv "HOME") "/notes.org") (lambda (p) (display "* Notes\n" p)) 'replace)

(import (ui-test files-sidebar))

(test "a sidebar entry is a button: a press leaves point, and the click visits the file it names"
  (ui-test:show! ui-test/files-sidebar:sidebar)
  (check-equal? '("notes.org") (map test-user:element-text (ui-test:elements (view) "ui-button")))
  (views:set-point! (view) 11)
  (ui-test:drawn (view))
  (test-user:press-button! (view) 4)
  (check-equal? 11 (views:point (view)))
  (test-user:release-button! 4)
  (test-runner:wait-until (lambda () (equal? "notes.org" (buffers:name (views:buffer (view))))))
  (check-equal? "notes.org" (buffers:name (views:buffer (view)))))

(test "RET with point in the entry runs the same command"
  (ui-test:show! ui-test/files-sidebar:sidebar)
  (views:set-point! (view) 5)
  (test-user:press! "RET")
  (check-equal? "notes.org" (buffers:name (views:buffer (view)))))

(import (ui-test todo))

(test "a click on a todo's Done button removes its todo from the saved list and the buffer, and so does RET"
  (ui-test:show! ui-test/todo:todo-buffer)
  (check-equal? "Buy milk Done\nWrite the plan Done\n" (ui-test:text ui-test/todo:todo-buffer))
  (ui-test:click-at! (view) 13)
  (check-equal? '(("Write the plan") "Write the plan Done\n") (list (ui-test/todo:todos) (ui-test:text ui-test/todo:todo-buffer)))
  (views:set-point! (view) 18)
  (test-user:press! "RET")
  (check-equal? '(() "") (list (ui-test/todo:todos) (ui-test:text ui-test/todo:todo-buffer))))

(import (ui-test buffer-list))

(test "the buffer list lists the live buffers as rows; RET shows one, and its rows are written silently, so undo records none"
  (define order (buffers:all))
  (views:with-view (view) (commands:run ui-test/buffer-list:list-buffers))
  (check-equal? "*buffer list*" (buffers:name (views:buffer (view))))
  (let ([rows (cddr (car (ui-test:datums ui-test/buffer-list:list-buffer)))])
    (check-equal? (length order) (length rows))
    (check (for-all vector? rows)))
  (test-user:press! "C-n")
  (check-equal? 1 (ui:selected-row (document:token (buffers:document ui-test/buffer-list:list-buffer) 0) (view)))
  (test-user:press! "RET")
  (check (eq? (cadr order) (views:buffer (view))))
  (check (for-all buffers:edit-silent? (buffers:edits-since ui-test/buffer-list:list-buffer 0))))

(commands:define-command (note) "Notes a push." (void))
(ui:define-button go note)
(ui:define-link more note)

(test "buttons and links are clickable, and disabled ones inert"
  (ui-test:show! (buffers:make "*buttons*" (buffers:text '() (go '() "Go") " " (go '((disabled . #t)) "No") " " (more '() "more") " "
                                                (more '((disabled . #t)) "less") "\n")))
  (check-equal? '("clickable" "inert" "clickable" "inert")
    (map (lambda (e) (test-user:element-attribute e "data-click")) (test-user:elements-with (ui-test:drawn (view)) "data-click"))))

(test "a click on a choosing list's heading names the list's own node, so it runs nothing and chooses nothing"
  (let* ([rows (buffers:make "*rows*" (ui:list '()))] [chosen '()])
    (ui-test:show! rows)
    (ui:set-rows! rows (document:token (buffers:document rows) 0) 3 (lambda (i) (ui:label (number->string i)))
                  (lambda (i) (set! chosen (cons i chosen))) (lambda (i) "odd"))
    (views:set-point! (view) 2)
    (test-user:click-element! (car (ui-test:elements (view) "ui-list-heading")))
    (check-equal? (list '() 2 keys:ignore) (list chosen (views:point (view)) (commands:last-command)))))

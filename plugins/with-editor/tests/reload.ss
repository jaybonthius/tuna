(import (tuna) (test) (test-user) (buffers) (git) (with-editor) (with-editor-test))

(define repo (with-editor-test:repository! "repo"))

(define script (with-editor-test:home-path ".cache/tuna/with-editor.sh"))

(test "a reload keeps which buffer a waiting program is answered from: C-c C-c in a message opened before it finishes the commit"
  (let-values ([(commit editing) (with-editor-test:commit! repo)])
    (let ([message (with-editor-test:wait-until-shown "COMMIT_EDITMSG")])
      (reload-modules! '((with-editor)))
      (check (buffers:with-buffer message (with-editor:mode)))
      (buffers:replace! message 1 1 "First commit\n")
      (test-user:press! "C-c C-c")
      (check-equal? 0 (with-editor-test:ended commit))
      (check-equal? '(#f "First commit\n") (list (buffers:live? message) (with-editor-test:subjects repo))))))

(test "after a reload, killing a waiting program's buffer cancels it"
  (with-editor-test:staged! repo "b.txt")
  (let-values ([(commit editing) (with-editor-test:commit! repo)])
    (let ([message (with-editor-test:wait-until-shown "COMMIT_EDITMSG")])
      (reload-modules! '((with-editor)))
      (buffers:kill! message)
      (check-equal? 1 (with-editor-test:ended commit))
      (check-equal? '("First commit\n" ()) (list (with-editor-test:subjects repo) (with-editor-test:request-folders))))))

(test "each load writes the script again, so a cleaned cache is filled"
  (delete-file script)
  (reload-modules! '((with-editor)))
  (check (file-exists? script)))

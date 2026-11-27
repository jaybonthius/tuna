(import (tuna) (test) (test-user) (test-runner) (buffers) (document) (views) (layout) (files) (processes) (with-editor)
        (with-editor-test))

(define script (with-editor-test:home-path ".cache/tuna/with-editor.sh"))

(define (token) (cdr (assoc "TUNA_EDIT_TOKEN" (with-editor:environment "EDITOR"))))

(define (request folder) (string-append "\x1b;]7563;tuna-edit;" (token) ";" folder "\a\n"))

(define (request-folder! name directory file)
  (let ([folder (with-editor-test:home-path name)])
    (unless (file-exists? folder) (mkdir folder))
    (with-editor-test:write-file! (string-append name "/request") (string-append directory "\n" file "\n"))
    folder))

(define (answer folder) (call-with-input-file (string-append folder "/answer") get-line))

(define (text b) (document:text (buffers:document b)))

(test "with-editor:environment names the script, written to Tuna's cache folder as the plugin loads, with this Tuna's token and process"
  (let ([environment (with-editor:environment "GIT_EDITOR")])
    (check-equal? '("GIT_EDITOR" "TUNA_EDIT_TOKEN" "TUNA_PID") (map car environment))
    (check-equal? (string-append "sh '" script "'") (cdr (assoc "GIT_EDITOR" environment)))
    (check (file-exists? script))
    (check-equal? 32 (string-length (cdr (assoc "TUNA_EDIT_TOKEN" environment))))
    (check (file-exists? (string-append "/proc/" (cdr (assoc "TUNA_PID" environment)) "/exe"))))
  (check-raises assertion-violation? (with-editor:environment ""))
  (check-raises assertion-violation? (with-editor:environment 'EDITOR)))

(test "a request split across pieces of output is put together; one with another token, and other escapes, pass through; a relative file is found from the request's folder"
  (mkdir (with-editor-test:home-path "sub"))
  (with-editor-test:write-file! "sub/notes.txt" "old\n")
  (let* ([received '()]
         [filter-output ((with-editor:output-wrapper)
                         (lambda (bytes end) (set! received (cons (if (eof-object? bytes) 'eof (utf8->string bytes)) received))))]
         [folder (request-folder! "request" (with-editor-test:home-path "sub") "notes.txt")]
         [r (request folder)])
    (filter-output (string->utf8 (string-append "before " (substring r 0 9))) 10)
    (filter-output (string->utf8 (string-append (substring r 9 (string-length r)) "after\n")) 20)
    (filter-output (string->utf8 "\x1b;]7563;tuna-edit;other-token;/tmp/x\a\n") 30)
    (filter-output (string->utf8 "\x1b;[1m bold\n") 40)
    (filter-output (eof-object) 40)
    (check-equal? '("before " "after\n" "\x1b;]7563;tuna-edit;other-token;/tmp/x\a\n" "\x1b;[1m bold\n" eof) (reverse received))
    (let ([notes (with-editor-test:wait-until-shown "notes.txt")])
      (check-equal? (with-editor-test:home-path "sub/notes.txt") (files:path notes))
      (test-user:press! "C-c C-c")
      (check-equal? "done" (answer folder)))))

(test "when the program has ended, C-c C-c saves and says so, and the buffer stays; a later request for the file reads it again"
  (let* ([filter-output ((with-editor:output-wrapper) (lambda (bytes end) (void)))]
         [folder (request-folder! "ended" (with-editor-test:home-path "sub") "notes.txt")])
    (with-editor-test:write-file! "sub/notes.txt" "fresh\n")
    (filter-output (string->utf8 (request folder)) 50)
    (let ([notes (with-editor-test:wait-until-shown "notes.txt")])
      (buffers:replace! notes 1 1 "stale ")
      (delete-file (string-append folder "/request"))
      (delete-directory folder)
      (with-editor-test:take-said!)
      (test-user:press! "C-c C-c")
      (check-equal? '("Wrote ~/sub/notes.txt" "The program that asked for this file has ended") (with-editor-test:take-said! 2))
      (check-equal? '(#t "stale fresh\n") (list (buffers:live? notes) (text notes)))
      (request-folder! "ended" (with-editor-test:home-path "sub") "notes.txt")
      (with-editor-test:write-file! "sub/notes.txt" "rewritten\n")
      (filter-output (string->utf8 (request folder)) 60)
      (test-runner:wait-until (lambda () (equal? "rewritten\n" (text notes))))
      (test-user:press! "C-c C-k")
      (check-equal? "cancel" (answer folder)))))

(test "the script serves a file whose name holds spaces and semicolons, and exits 0 on done"
  (with-editor-test:write-file! "sub/a b;c.txt" "odd\n")
  (let* ([status #f]
         [process (processes:start "sh" (list script "a b;c.txt") ((with-editor:output-wrapper) (lambda (bytes end) (void)))
                    (lambda (s) (set! status s))
                    (processes:options [directory (with-editor-test:home-path "sub")] [environment (with-editor:environment "EDITOR")]))])
    (let ([b (with-editor-test:wait-until-shown "a b;c.txt")])
      (check-equal? (with-editor-test:home-path "sub/a b;c.txt") (files:path b))
      (test-user:press! "C-c C-c")
      (test-runner:wait-until (lambda () status))
      (check-equal? 0 status)
      (check-equal? '() (with-editor-test:request-folders)))))

(test "the script gives up, exiting 1 and removing its folder, when Tuna's process is gone"
  (mkdir (with-editor-test:home-path "dead"))
  (let-values ([(status output errors)
                (processes:run "sh" (list script "file.txt") #f
                  (processes:options [directory (with-editor-test:home-path "dead")]
                                     [environment (list (cons "TUNA_PID" "999999999") (cons "TUNA_EDIT_TOKEN" "t")
                                                        (cons "TMPDIR" (with-editor-test:home-path "dead")))]))])
    (check-equal? '(1 ()) (list status (directory-list (with-editor-test:home-path "dead"))))))

(test "the script removes its folder and exits 1 on a signal"
  (let* ([status #f]
         [process (processes:start "sh" (list script "file.txt") (lambda (bytes end) (void)) (lambda (s) (set! status s))
                    (processes:options [directory (with-editor-test:home-path "sub")] [environment (with-editor:environment "EDITOR")]))])
    (test-runner:wait-until (lambda () (pair? (with-editor-test:request-folders))))
    (processes:signal! process (processes:signal term))
    (test-runner:wait-until (lambda () status))
    (check-equal? '(1 ()) (list status (with-editor-test:request-folders)))))

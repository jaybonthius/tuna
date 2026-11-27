(import (tuna) (test) (test-runner) (hooks) (options) (document) (buffers) (files) (undo) (undo-log) (undo-log-test edits) (undo-log-test logs))

(options:set! undo-log:keep-log? (lambda (path) #t))

(define (text b) (document:text (buffers:document b)))

(define (kept? b) (exists (lambda (entry) (entry b)) (hooks:entries files:unsaved-kept)))

(define (visited path text)
  (undo-log-test/logs:write-text! path text)
  (files:visit path))

(define (edited! b text)
  (buffers:replace! b 1 1 text)
  (let ([path (files:path b)])
    (test-runner:wait-until (lambda () (undo-log-test/logs:logged? path)))))

(test "a rename moves the renamed file's log, so a renamed buffer's unsaved edits stay kept"
  (let* ([a-path (undo-log-test/logs:home-path "a.txt")] [b-path (undo-log-test/logs:home-path "b.txt")] [a (visited a-path "alpha\n")])
    (edited! a "1 ")
    (files:rename-file a-path b-path)
    (test-runner:wait-until (lambda () (undo-log-test/logs:logged? b-path)))
    (check-equal? (list "b.txt" b-path #f) (list (buffers:name a) (files:path a) (undo-log-test/logs:logged? a-path)))
    (check (kept? a))
    (buffers:replace! a 1 1 "2 ")
    (check-equal? '(undo-history group saved at group) (undo-log-test/logs:logged-kinds b-path 5))))

(test "renaming a folder moves the logs of the files under it, also of a file no buffer visits, and its history comes back"
  (let ([f-path (undo-log-test/logs:home-path "f/c.txt")] [g-path (undo-log-test/logs:home-path "g/c.txt")])
    (mkdir (undo-log-test/logs:home-path "f"))
    (let ([c (visited f-path "c\n")])
      (edited! c "x")
      (buffers:kill! c))
    (files:rename-file (undo-log-test/logs:home-path "f") (undo-log-test/logs:home-path "g"))
    (test-runner:wait-until (lambda () (undo-log-test/logs:logged? g-path)))
    (check (not (undo-log-test/logs:logged? f-path)))
    (let ([g (files:visit g-path)])
      (buffers:with-buffer g (undo:redo 1))
      (check-equal? "xc\n" (text g)))))

(test "across file systems a folder is not merged into one that holds files, and the logs of the files it holds stay with them"
  (let* ([other (format "/dev/shm/tuna-undo-log-~a" (get-process-id))]
         [keep-path (string-append other "/dst/keep.txt")]
         [one-path (undo-log-test/logs:home-path "src/one.txt")]
         [rename! (lambda () (files:rename-file (undo-log-test/logs:home-path "src") (string-append other "/dst") (file-options no-fail)))])
    (mkdir other)
    (mkdir (string-append other "/dst"))
    (let ([keep (visited keep-path "keep\n")])
      (edited! keep "k")
      (mkdir (undo-log-test/logs:home-path "src"))
      (let ([one (visited one-path "one\n")])
        (edited! one "1")
        (check-raises (lambda (c) (and (error? c) (eq? 'files:rename-file (condition-who c)))) (rename!))
        (buffers:kill! keep)
        (check-raises (lambda (c) (and (error? c) (eq? 'files:rename-file (condition-who c)))) (rename!))
        (check-equal? (list one-path #t #t #t #t)
          (list (files:path one) (file-exists? one-path) (file-exists? keep-path) (undo-log-test/logs:logged? one-path) (undo-log-test/logs:logged? keep-path)))))
    (let ([kept (files:visit keep-path)])
      (buffers:with-buffer kept (undo:redo 1))
      (check-equal? "kkeep\n" (text kept))
      (buffers:kill! kept))
    (files:delete-file other)))

(test "a rename onto a file with a log deletes that log, whether or not the renamed file has one"
  (let ([logged-path (undo-log-test/logs:home-path "logged.txt")] [plain-path (undo-log-test/logs:home-path "plain.txt")])
    (let ([logged (visited logged-path "logged\n")])
      (edited! logged "2 ")
      (buffers:kill! logged))
    (undo-log-test/logs:write-text! plain-path "plain\n")
    (files:rename-file plain-path logged-path (file-options no-fail))
    (test-runner:wait-until (lambda () (not (undo-log-test/logs:logged? logged-path))))
    (check-equal? "plain\n" (undo-log-test/logs:read-text logged-path))
    (let ([plain (files:visit logged-path)])
      (check-equal? '("plain\n" #f) (list (text plain) (buffers:modified? plain))))))

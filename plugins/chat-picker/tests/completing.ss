(import (tuna) (test) (test-user) (test-runner) (buffers) (views) (layout) (completion) (completion-list) (pi) (chat)
        (pi-chat) (chat-picker) (test-pi) (chat-picker-test picking))

(define project (string-append (getenv "HOME") "/src/tuna"))

(define (write-file! path text) (call-with-output-file (string-append project "/" path) (lambda (p) (put-string p text))))

(system (string-append "mkdir -p " project "/lib/deep " project "/.hidden && git init -q " project))

(for-each (lambda (f) (write-file! (car f) (cadr f)))
  '(("lib/a.txt" "one\n") ("lib/deep/b.txt" "b\n") ("README" "r\n") (".hidden/secret" "s\n") (".hidden/deep.txt" "d\n")
    (".gitignore" "*.log\n") ("lib/run.log" "l\n")))

(define chat (chat-picker-test/picking:started (string-append project "/")))

(chat:show! chat)

(define (clear!) (chat:set-prompt! chat ""))

(test "TAB in the prompt completes @ and a path from the files of the chat folder's project, as git lists them, and the folders holding them"
  (test-user:type! "see @")
  (test-user:press! "TAB")
  (chat-picker-test/picking:settled)
  (check-equal? '("lib/" "README" ".hidden/" "lib/a.txt" "lib/deep/" ".gitignore" ".hidden/secret" "lib/deep/b.txt" ".hidden/deep.txt")
                (chat-picker-test/picking:texts))
  (let ([s (chat-picker-test/picking:session)])
    (test-user:type! "l/")
    (chat-picker-test/picking:settled)
    (check-equal? '("lib/" "lib/a.txt" "lib/deep/" "lib/deep/b.txt") (chat-picker-test/picking:texts))
    (test-user:type! "d")
    (chat-picker-test/picking:settled)
    (check-equal? '("lib/deep/" "lib/deep/b.txt") (chat-picker-test/picking:texts))
    (test-user:press! "TAB")
    (check-equal? "see @lib/deep/" (chat-picker-test/picking:prompt-text chat))
    (check (eq? s (chat-picker-test/picking:session))))
  (test-user:type! "b")
  (test-runner:wait-until (lambda () (equal? '("lib/deep/b.txt") (chat-picker-test/picking:texts))))
  (test-user:press! "TAB")
  (test-runner:wait-until (lambda () (not (chat-picker-test/picking:session))))
  (check-equal? "see @lib/deep/b.txt" (chat-picker-test/picking:prompt-text chat))
  (clear!))

(test "an @ inside a word starts nothing"
  (test-user:type! "x@de")
  (test-user:press! "TAB")
  (check-equal? #f (chat-picker-test/picking:session))
  (clear!))

(test "TAB completes / and a name at the prompt's start from the agent's commands, with their descriptions"
  (let ([f (chat-picker-test/picking:fake chat)])
    (test-pi:answer! f "get_commands"
      (lambda (r) '(("commands" . #((("name" . "review") ("description" . "Review the diff\nin detail") ("source" . "extension")))))))
    (test-pi:say! f (test-pi:event "agent_settled" '("aborted" . #f)))
    (test-runner:wait-until (lambda () (pair? (pi:chat-commands chat)))))
  (test-user:type! "/re")
  (test-user:press! "TAB")
  (chat-picker-test/picking:settled)
  (check-equal? '(("/review" (shadow . "Review the diff"))) (chat-picker-test/picking:rows))
  (test-user:press! "C-g")
  (clear!)
  (test-user:type! "/co")
  (test-user:press! "TAB")
  (chat-picker-test/picking:settled)
  (check-equal? '(("/copy") ("/compact")) (chat-picker-test/picking:rows))
  (test-user:press! "C-g")
  (clear!))

(test "a / after the prompt's start starts nothing"
  (test-user:type! "see /re")
  (test-user:press! "TAB")
  (check-equal? #f (chat-picker-test/picking:session))
  (clear!))

(import (tuna) (test) (test-user) (test-runner) (buffers) (document) (views) (layout) (editing) (undo) (echo-area) (chat)
        (chat-test fake-talks)
        (chat-test fake-agents) (chat-test))

(define e (chat-test/fake-talks:start 'echo (getenv "HOME")))

(chat:show! e)

(define b (chat:buffer e))

(define (sent) (chat-test/fake-talks:talk-sent e))

(define (notices)
  (map (lambda (n) (list (test-user:element-attribute n "data-level") (test-user:element-text n)))
       (test-user:elements (test-user:screen) "chat-notice")))

(test "the prompt's edits are the buffer's history, and typing marks the chat modified"
  (check-equal? #f (buffers:silent? b))
  (test-user:type! "Fix it")
  (check-equal? "Fix it\n" (chat-test:shown e))
  (check-equal? #t (buffers:modified? b)))

(test "RET moves the prompt's text into the source's history and sends it, emptying the prompt silently"
  (test-user:press! "RET")
  (check-equal? '((send . "Fix it")) (sent))
  (check-equal? "\n" (chat-test:shown e))
  (check-equal? '("Fix it") (chat-test/fake-agents:echo-history))
  (check-equal? '("no further undo information") (chat-test:press! "C-/")))

(test "S-RET adds a line, and M-RET follows up with the whole text"
  (test-user:type! "Then")
  (test-user:press! "S-RET")
  (test-user:type! "test")
  (check-equal? "Then\ntest\n" (chat-test:shown e))
  (test-user:press! "M-RET")
  (check-equal? '(follow-up . "Then\ntest") (car (sent))))

(test "blank text sends nothing"
  (test-user:type! "  ")
  (test-user:press! "RET")
  (check-equal? 2 (length (sent)))
  (test-user:press! "C-a C-k"))

(test "after a send C-/ does not bring the text back, and M-p does"
  (test-user:type! "gone")
  (test-user:press! "RET")
  (test-user:press! "C-/")
  (check (not (equal? "gone" (chat-test:prompt-text e))))
  (test-user:press! "C-a C-k M-p")
  (check-equal? "gone" (chat-test:prompt-text e)))

(test "M-p and M-n walk the source's history, newest first, and come back to what was typed"
  (test-user:press! "C-a C-k")
  (test-user:type! "more")
  (test-user:press! "M-p")
  (check-equal? "gone" (chat-test:prompt-text e))
  (test-user:press! "M-p")
  (check-equal? "Then\ntest" (chat-test:prompt-text e))
  (test-user:press! "M-n M-n")
  (check-equal? "more" (chat-test:prompt-text e)))

(test "a text the source refuses comes back before anything typed since, with a warning notice naming the source"
  (chat:set-prompt! e "busy")
  (test-user:press! "RET")
  (check-equal? "busy" (chat-test:prompt-text e))
  (check-equal? '(("warning" "Echo refused the prompt: it is busy")) (notices))
  (chat:set-prompt! e "refuse")
  (test-user:press! "RET")
  (check-equal? "refuse" (chat-test:prompt-text e))
  (check-equal? '(("warning" "Echo refused the prompt: it is busy") ("warning" "Echo refuses that")) (notices))
  (chat:set-prompt! e "typed since")
  (chat:put-back! e "Then")
  (check-equal? "Then\ntyped since" (chat-test:prompt-text e)))

(test "the conversation refuses edits: typing goes only into the prompt"
  (chat-test/fake-talks:reply! e "Hello")
  (test-user:settle)
  (chat-test:at! b "Hello")
  (let ([before (chat-test:shown e)])
    (check-equal? '("a read-only span refuses the edit") (chat-test:press! "x"))
    (check-equal? before (chat-test:shown e))))

(test "the source's queue shows under the conversation, tagged; M-<up> takes it back into the prompt and C-c C-k cancels with it"
  (chat:set-prompt! e "")
  (chat-test/fake-talks:queue! e (list (cons (chat:delivery next-step) "a") (cons (chat:delivery turn-end) "b")))
  (test-user:settle)
  (check-equal? '("Steer a" "Follow-up b")
    (map test-user:element-text (test-user:elements (car (test-user:elements (test-user:screen) "chat-queue")) "chat-queued")))
  (views:set-point! (chat-test:view) (chat:prompt-start e))
  (test-user:press! "M-<up>")
  (check-equal? "a\nb" (chat-test:prompt-text e))
  (check-equal? '() (test-user:elements (test-user:screen) "chat-queued"))
  (chat-test/fake-talks:queue! e (list (cons (chat:delivery turn-end) "c")))
  (test-user:press! "C-c C-k")
  (check-equal? "c\na\nb" (chat-test:prompt-text e)))

(test "undo in the prompt keeps its history while the agent writes above it, and keys typed over several batches join"
  (chat:set-prompt! e "")
  (views:set-point! (chat-test:view) (chat:prompt-start e))
  (test-user:type! "one")
  (test-user:press! "C-e")
  (chat-test/fake-talks:reply! e "Working")
  (test-user:settle)
  (test-user:type! " two")
  (chat-test/fake-talks:reply! e "More")
  (test-user:settle)
  (test-user:press! "C-/")
  (check-equal? "one" (chat-test:prompt-text e))
  (test-user:type! " t")
  (test-user:type! "h")
  (test-user:type! "ree")
  (test-user:press! "C-/")
  (check-equal? "one" (chat-test:prompt-text e)))

(test "M-> goes to the end of the prompt's text, where typing goes, and C-k there is at the end of the buffer"
  (chat-test:at! b "Hello")
  (test-user:press! "M->")
  (test-user:type! "!")
  (check-equal? "one!" (chat-test:prompt-text e))
  (check-equal? '("end of buffer") (chat-test:press! "C-k")))

(test "chat:add-to-prompt! adds a line, chat:set-prompt! replaces the prompt, and the prompt's range is its text"
  (chat:add-to-prompt! e "two")
  (check-equal? "one!\ntwo" (chat-test:prompt-text e))
  (chat:set-prompt! e "Replaced\nwhole")
  (check-equal? "Replaced\nwhole" (buffers:text-between (buffers:document b) (chat:prompt-start e) (chat:prompt-end e)))
  (check-equal? "not a chat" (chat-test:raised (lambda () (chat:prompt-start 'x))))
  (check-equal? "not a chat" (chat-test:raised (lambda () (chat:prompt-end 'x))))
  (check-equal? "not a string" (chat-test:raised (lambda () (chat:set-prompt! e 'x)))))

(test "chat:notice! adds a notice of the chat's own at a level, after the conversation's items"
  (chat:notice! e (chat:level info) "Noted")
  (test-user:settle)
  (check-equal? '("info" "Noted") (car (last-pair (notices))))
  (check-equal? "not a level" (chat-test:raised (lambda () (chat:notice! e 'loud "x")))))

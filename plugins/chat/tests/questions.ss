(import (tuna) (test) (test-user) (buffers) (document) (views) (layout) (chat) (chat-test fake-talks) (chat-test fake-agents) (chat-test))

(define e (chat-test/fake-talks:start 'echo (getenv "HOME")))

(chat:show! e)

(define b (chat:buffer e))

(define (answered) (chat-test/fake-talks:talk-answered e))

(define (questions) (test-user:elements (test-user:screen) "chat-question"))

(define (in-prompt?)
  (let ([p (views:point (chat-test:view))]) (and (>= p (chat:prompt-start e)) (<= p (chat:prompt-end e)))))

(test "a question is drawn above the prompt, and point stays in the prompt"
  (test-user:type! "draft")
  (chat-test/fake-talks:ask! e "d1" "Allow rm?" '(((label . "Allow") (key . #f) (value . allow)) ((label . "Block") (key . #f) (value . block))))
  (test-user:settle)
  (check-equal? 1 (length (questions)))
  (check-equal? "Allow rm?" (test-user:element-text (car (test-user:elements (car (questions)) "chat-header"))))
  (check (in-prompt?))
  (test-user:type! "!")
  (check-equal? "draft!" (chat-test:prompt-text e)))

(test "chat:next-question puts point on the first answer, and RET answers with the answer at point"
  (layout:switch-to-buffer (buffers:make "other" ""))
  (test-user:press! "C-c a d")
  (check (eq? b (views:buffer (chat-test:view))))
  (test-user:press! "C-n RET")
  (check-equal? '(("d1" . block)) (answered))
  (check-equal? '() (questions)))

(test "a question with buttons answers with the button at point; next-question puts point on its first button"
  (chat-test/fake-talks:ask! e "d2" "Clear?" 'buttons)
  (test-user:settle)
  (chat-test:at! b "No")
  (test-user:press! "RET")
  (check-equal? '("d2" . #f) (car (answered)))
  (chat-test/fake-talks:ask! e "d3" "Again?" 'buttons)
  (test-user:settle)
  (test-user:press! "C-c a d RET")
  (check-equal? '("d3" . #t) (car (answered))))

(test "off a button, a question with buttons and no answers says which to push"
  (chat-test/fake-talks:ask! e "d4" "Sure?" 'buttons)
  (test-user:settle)
  (chat-test:at! b "Sure?")
  (check-equal? '("push Yes or No") (chat-test:press! "RET"))
  (test-user:press! "C-c C-k")
  (check-equal? '() (questions))
  (check-equal? #f (assoc "d4" (answered))))

(test "a field without lines refuses a line break, RET answers with what is typed, and a rewrite of the chat keeps it"
  (chat-test/fake-talks:ask! e "d5" "Name" 'field)
  (test-user:settle)
  (test-user:press! "C-c a d")
  (test-user:type! "Zep")
  (chat-test/fake-talks:queue! e (list (cons (chat:delivery next-step) "x")))
  (test-user:settle)
  (test-user:type! "po")
  (check-equal? '("the node refuses the edit") (chat-test:press! "S-RET"))
  (test-user:press! "RET")
  (check-equal? '("d5" . "Zeppo") (car (answered))))

(test "a field of many lines takes S-RET, and next-question puts point after the text it holds"
  (chat-test/fake-talks:ask! e "d6" "Edit" 'lines)
  (test-user:settle)
  (test-user:press! "C-c a d")
  (test-user:type! "One")
  (layout:switch-to-buffer (buffers:make "elsewhere" ""))
  (test-user:press! "C-c a d")
  (test-user:press! "S-RET")
  (test-user:type! "Two")
  (test-user:press! "RET")
  (check-equal? '("d6" . "One\nTwo") (car (answered))))

(test "C-c C-k in a question cancels it; outside one it cancels the agent's turn"
  (chat-test/fake-talks:ask! e "d7" "Pick" '(((label . "a") (key . #f) (value . a))))
  (test-user:settle)
  (chat-test:at! b "Pick")
  (let ([before (length (answered))])
    (test-user:press! "C-c C-k")
    (check-equal? '() (questions))
    (check-equal? before (length (answered))))
  (chat-test/fake-talks:queue! e (list (cons (chat:delivery turn-end) "queued")))
  (views:set-point! (chat-test:view) (chat:prompt-start e))
  (test-user:press! "C-c C-k")
  (check-equal? "queued\ndraft!" (chat-test:prompt-text e)))

(test "RET where no question is raises, and so does an answers list with no row at point"
  (chat:set-prompt! e "")
  (chat-test/fake-talks:reply! e "Said")
  (test-user:settle)
  (check-equal? '("no question is at point") (chat-test:reports-during (lambda () (chat-test:at! b "Said") (chat-test:run! chat:answer))))
  (check-equal? '("no question waits") (chat-test:press! "C-c a d")))

(import (tuna) (test) (test-user) (test-runner) (options) (tables) (buffers) (views) (echo-area) (chat) (chat-test fake-talks)
        (chat-test fake-agents) (chat-test))

(define e (chat-test/fake-talks:start 'echo (getenv "HOME")))

(chat:show! e)

(define b (chat:buffer e))

(define (opens)
  (map (lambda (el) (and (test-user:element-attribute el "data-open") #t))
       (test-user:elements (test-user:screen) "chat-thinking")))

(test "the thinking and tool-call kinds fold"
  (check (tables:ref chat:block-kinds chat:thinking #f))
  (check (tables:ref chat:block-kinds chat:tool-call #f)))

(test "TAB on a block's header unfolds it, and TAB again folds it; elsewhere in the conversation there is no block"
  (chat-test/fake-talks:add! e 'thinking "Pondering")
  (chat-test/fake-talks:add! e 'thinking "Weighing")
  (chat-test/fake-talks:reply! e "Answer")
  (test-user:settle)
  (check-equal? '(#f #f) (opens))
  (chat-test:at! b "Thinking")
  (test-user:press! "TAB")
  (check-equal? '(#t #f) (opens))
  (test-user:press! "TAB")
  (check-equal? '(#f #f) (opens))
  (chat-test:at! b "Answer")
  (check-equal? '("no block is at point") (chat-test:press! "TAB")))

(test "C-c C-o folds every block while any is unfolded, else unfolds every one"
  (chat-test:at! b "Thinking")
  (test-user:press! "TAB")
  (test-user:press! "C-c C-o")
  (check-equal? '(#f #f) (opens))
  (test-user:press! "C-c C-o")
  (check-equal? '(#t #t) (opens)))

(test "folds belong to the chat's session: a block of another session starts folded where an unfolded one was"
  (chat-test/fake-talks:move! e "another-session")
  (test-user:settle)
  (check-equal? '(#f #f) (opens)))

(test "chat:toggle-thinking turns chat:thinking-shown? over, says which, and every chat is drawn again"
  (check-equal? #f (chat:thinking-shown?))
  (chat-test:run! chat:toggle-thinking)
  (test-user:settle)
  (check-equal? '(#t "Finished thinking is shown") (list (chat:thinking-shown?) (echo-area:current-message)))
  (check-equal? '(#t #t) (opens))
  (chat-test:run! chat:toggle-thinking)
  (test-user:settle)
  (check-equal? '(#f "Finished thinking is folded") (list (chat:thinking-shown?) (echo-area:current-message)))
  (check-equal? '(#f #f) (opens)))

(test "chat:markdown-blocks keys each block with the part's key; a streaming text is read unfinished, a history text plain until chat's thread converts it"
  (check-equal? '((markdown:paragraph ((key 3 . 0)) "Reply " (markdown:strong () "49") "\n"))
    (chat:markdown-blocks "Reply **49**" (chat:text-state live) 3))
  (check-equal? '((markdown:paragraph ((key 3 . 0)) "Some " (markdown:strong () "bol") "\n"))
    (chat:markdown-blocks "Some **bol" (chat:text-state streaming) 3))
  (let ([text "History **50**"])
    (check-equal? '((markdown:paragraph ((key 0 . 0)) "History **50**\n")) (chat:markdown-blocks text (chat:text-state history) 0))
    (test-runner:wait-until
      (lambda () (equal? '((markdown:paragraph ((key 0 . 0)) "History " (markdown:strong () "50") "\n"))
                         (chat:markdown-blocks text (chat:text-state history) 0))))))

(test "the closed sets are forms that refuse a misspelling"
  (check-equal? '(next-step error history) (list (chat:delivery next-step) (chat:level error) (chat:text-state history)))
  (check-raises syntax-violation? (load-module! '(chat-test bad-source level))))

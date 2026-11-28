#!tuna
(import (chat-test fake-talks) (chat) (modes) (hooks) (tables) (saved))

(saved:define-saved echo-history '() list?)

(saved:define-saved echo-drafts '() list?)

(saved:define-saved parrot-history '() list?)

(saved:define-saved parrot-drafts '() list?)

(tables:define-table keymap "Keys in a fake agent's chat.")

(hooks:define-hook %mode-hook)

(modes:define-major-mode mode (parent chat:mode) (lighter "Fake") (keymap keymap) (hook %mode-hook))

(define-condition-type &busy &error %make-busy busy?)

(define (%draw-item t item open?)
  (let ([key (vector-ref item 0)] [text (vector-ref item 2)])
    (case (vector-ref item 1)
      [(reply) (apply chat:reply (list (cons 'key key)) (chat:markdown-blocks text (chat:text-state live) 0))]
      [(history) (apply chat:reply (list (cons 'key key)) (chat:markdown-blocks text (chat:text-state history) 0))]
      [(thinking)
       (let ([unfolded? (open? 0 (chat:thinking-shown?))])
         (chat:reply (list (cons 'key key))
           (apply chat:thinking (list (cons 'key 0) (cons 'open unfolded?))
             (chat:header '() "Thinking\n")
             (if unfolded? (chat:markdown-blocks text (chat:text-state live) 0) '()))))]
      [else (apply chat:user-message (list (cons 'key key)) (chat:markdown-blocks text (chat:text-state live) 0))])))

(define (%draw-question t q)
  (let ([answers (caddr q)])
    (apply chat:question '()
      (chat:header '() (cadr q) "\n")
      (cond
        [(eq? answers 'field) (list (chat:field '((key . field)) "\n") (chat:actions '() (chat:answer-button '((value . field)) "Answer") "\n"))]
        [(eq? answers 'lines)
         (list (chat:field '((key . field) (lines . #t)) "\n") (chat:actions '() (chat:answer-button '((value . field)) "Answer") "\n"))]
        [(eq? answers 'buttons)
         (list (chat:actions '() (chat:answer-button '((value . #t)) "Yes") " " (chat:answer-button '((value . #f)) "No") "\n"))]
        [else (list (chat:answers (list (cons 'answers answers))) (chat:actions '() (chat:cancel-button '() "Cancel") "\n"))]))))

(define (%sender how)
  (lambda (t text)
    (cond
      [(string=? text "busy") (raise (condition (%make-busy) (make-message-condition "it is busy")))]
      [(string=? text "refuse") (chat:refuse "Echo refuses that")]
      [else (chat-test/fake-talks:talk-sent-set! t (cons (cons how text) (chat-test/fake-talks:talk-sent t)))])))

(define (%fork t item)
  (chat-test/fake-talks:talk-sent-set! t (cons (cons 'fork (vector-ref item 0)) (chat-test/fake-talks:talk-sent t))))

(define (%answer t q value)
  (chat-test/fake-talks:talk-answered-set! t (cons (cons (car q) value) (chat-test/fake-talks:talk-answered t)))
  (%drop-question t q))

(define (%drop-question t q)
  (chat-test/fake-talks:talk-questions-set! t (remq q (chat-test/fake-talks:talk-questions t)))
  (chat:changed! t))

(define (%activity t) (if (chat-test/fake-talks:talk-working? t) "running" "idle"))

(define (%take-queue t)
  (let ([texts (map cdr (chat-test/fake-talks:talk-queue t))])
    (chat-test/fake-talks:queue! t '())
    texts))

(chat:define-source echo
  (conversation? (chat-test/fake-talks:of-kind 'echo))
  (conversations (chat-test/fake-talks:live 'echo))
  (title "Echo")
  (mode mode)
  (directory chat-test/fake-talks:talk-directory)
  (session chat-test/fake-talks:talk-session)
  (start (lambda (folder) (chat-test/fake-talks:start 'echo folder)))
  (items chat-test/fake-talks:talk-items)
  (item-key (lambda (item) (vector-ref item 0)))
  (draw-item %draw-item)
  (activity %activity)
  (working? chat-test/fake-talks:talk-working?)
  (history echo-history)
  (drafts echo-drafts)
  (send (%sender 'send))
  (send-now (%sender 'send-now))
  (follow-up (%sender 'follow-up))
  (cancel %take-queue)
  (take-queue %take-queue)
  (queue chat-test/fake-talks:talk-queue)
  (refused? busy?)
  (item-text (lambda (item) (vector-ref item 2)))
  (questions chat-test/fake-talks:talk-questions)
  (question-id car)
  (draw-question %draw-question)
  (answer %answer)
  (cancel-question %drop-question)
  (above chat-test/fake-talks:talk-above)
  (below chat-test/fake-talks:talk-below)
  (commands (lambda (t) '(("echo" . "Says it again") ("plain" . #f))))
  (kill chat-test/fake-talks:end!)
  (fork %fork))

(chat:define-source parrot
  (conversation? (chat-test/fake-talks:of-kind 'parrot))
  (conversations (chat-test/fake-talks:live 'parrot))
  (title "Parrot")
  (mode mode)
  (directory chat-test/fake-talks:talk-directory)
  (session chat-test/fake-talks:talk-session)
  (start (lambda (folder) (chat-test/fake-talks:start 'parrot folder)))
  (items chat-test/fake-talks:talk-items)
  (item-key (lambda (item) (vector-ref item 0)))
  (draw-item %draw-item)
  (activity %activity)
  (working? chat-test/fake-talks:talk-working?)
  (history parrot-history)
  (drafts parrot-drafts)
  (send (%sender 'send))
  (cancel (lambda (t) '()))
  (questions chat-test/fake-talks:talk-questions)
  (question-id car)
  (draw-question %draw-question)
  (answer %answer)
  (cancel-question %drop-question)
  (status (lambda (t) (string-append "Parrot · " (%activity t))))
  (kill chat-test/fake-talks:end!))

(hooks:add! chat-test/fake-talks:changed chat:changed!)

#!tuna
(import (fake-talks) (chat) (modes) (hooks) (tables) (saved))

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
      [else (fake-talks:talk-sent-set! t (cons (cons how text) (fake-talks:talk-sent t)))])))

(define (%answer t q value)
  (fake-talks:talk-answered-set! t (cons (cons (car q) value) (fake-talks:talk-answered t)))
  (%drop-question t q))

(define (%drop-question t q)
  (fake-talks:talk-questions-set! t (remq q (fake-talks:talk-questions t)))
  (chat:changed! t))

(define (%activity t) (if (fake-talks:talk-working? t) "running" "idle"))

(define (%take-queue t)
  (let ([texts (map cdr (fake-talks:talk-queue t))])
    (fake-talks:queue! t '())
    texts))

(chat:define-source echo
  (conversation? (fake-talks:of-kind 'echo))
  (conversations (fake-talks:live 'echo))
  (title "Echo")
  (mode mode)
  (directory fake-talks:talk-directory)
  (session fake-talks:talk-session)
  (start (lambda (folder) (fake-talks:start 'echo folder)))
  (items fake-talks:talk-items)
  (item-key (lambda (item) (vector-ref item 0)))
  (draw-item %draw-item)
  (activity %activity)
  (working? fake-talks:talk-working?)
  (history echo-history)
  (drafts echo-drafts)
  (send (%sender 'send))
  (send-now (%sender 'send-now))
  (follow-up (%sender 'follow-up))
  (cancel %take-queue)
  (take-queue %take-queue)
  (queue fake-talks:talk-queue)
  (refused? busy?)
  (item-text (lambda (item) (vector-ref item 2)))
  (questions fake-talks:talk-questions)
  (question-id car)
  (draw-question %draw-question)
  (answer %answer)
  (cancel-question %drop-question)
  (above fake-talks:talk-above)
  (below fake-talks:talk-below)
  (commands (lambda (t) '(("echo" . "Says it again") ("plain" . #f))))
  (kill fake-talks:end!))

(chat:define-source parrot
  (conversation? (fake-talks:of-kind 'parrot))
  (conversations (fake-talks:live 'parrot))
  (title "Parrot")
  (mode mode)
  (directory fake-talks:talk-directory)
  (session fake-talks:talk-session)
  (start (lambda (folder) (fake-talks:start 'parrot folder)))
  (items fake-talks:talk-items)
  (item-key (lambda (item) (vector-ref item 0)))
  (draw-item %draw-item)
  (activity %activity)
  (working? fake-talks:talk-working?)
  (history parrot-history)
  (drafts parrot-drafts)
  (send (%sender 'send))
  (cancel (lambda (t) '()))
  (questions fake-talks:talk-questions)
  (question-id car)
  (draw-question %draw-question)
  (answer %answer)
  (cancel-question %drop-question)
  (status (lambda (t) (string-append "Parrot · " (%activity t))))
  (kill fake-talks:end!))

(hooks:add! fake-talks:changed chat:changed!)

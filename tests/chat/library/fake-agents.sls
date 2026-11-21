#!tuna
(import (fake-talks) (chat) (modes))

;; Two sources, so the chat's own rules are tested without an agent.

(define-saved echo-history '() list?)

(define-saved echo-drafts '() list?)

(define-saved parrot-history '() list?)

(define-saved parrot-drafts '() list?)

(define-table keymap "Keys in a fake agent's chat.")

(define-hook %mode-hook)

(modes:define-major-mode mode (parent chat:mode) (lighter "Fake") (keymap keymap) (hook %mode-hook))

(define (%draw-item t item open?)
  (let ([key (vector-ref item 0)] [blocks (chat:markdown-blocks (vector-ref item 2) (chat:text-state live) 0)])
    (if (eq? (vector-ref item 1) 'reply)
        (apply chat:reply (list (cons 'key key)) blocks)
        (apply chat:user-message (list (cons 'key key)) blocks))))

(define (%draw-question t q)
  (chat:question '()
    (chat:header '() (cadr q) "\n")
    (chat:answers (list (cons 'answers (caddr q))))
    (chat:actions '() (chat:cancel-button '() "Cancel") "\n")))

(define (%sender how)
  (lambda (t text)
    (fake-talks:talk-sent-set! t (cons (cons how text) (fake-talks:talk-sent t)))))

(define (%answer t q value)
  (fake-talks:talk-answered-set! t (cons (cons (car q) value) (fake-talks:talk-answered t)))
  (%drop-question t q))

(define (%drop-question t q)
  (fake-talks:talk-questions-set! t (remq q (fake-talks:talk-questions t)))
  (chat:changed! t))

(define (%activity t) (if (fake-talks:talk-working? t) "running" "idle"))

(define (%end t)
  (fake-talks:end! t))

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
  (cancel (lambda (t) '()))
  (item-text (lambda (item) (vector-ref item 2)))
  (questions fake-talks:talk-questions)
  (question-id car)
  (draw-question %draw-question)
  (answer %answer)
  (cancel-question %drop-question)
  (kill %end))

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
  (kill %end))

(add-hook! fake-talks:changed chat:changed!)

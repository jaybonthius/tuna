(import (tuna) (test) (test-runner) (test-user) (buffers) (document) (views) (layout) (undo) (markdown) (buffers-test) (markdown-test chat))

(define (view) (layout:selected-view))

(define (datums b) (document:datums (buffers:document b)))

(define chat markdown-test/chat:chat)

(define (receive! piece)
  (markdown-test/chat:receive! piece)
  (test-user:settle))

(views:set-buffer! (view) chat)

(test "the example's chat rebuilds the reply once per batch while it streams, closing what is open at its end"
  (receive! "Steps:\n-")
  (check-equal? '((markdown-test/chat:reply () (markdown:paragraph ((key . 0)) "Steps:\n"))) (datums chat))
  (receive! " **one")
  (check-equal? '((markdown-test/chat:reply () (markdown:paragraph ((key . 0)) "Steps:\n")
                   (markdown:list ((key . 1) (ordered . #f) (tight . #t)) (markdown:item ((key . 0)) (markdown:paragraph ((key . 0)) (markdown:strong () "one") "\n")))))
                (datums chat))
  (markdown-test/chat:receive! "** and `two`\n")
  (markdown-test/chat:finish!)
  (test-user:settle)
  (check-equal? '((markdown-test/chat:reply () (markdown:paragraph ((key . 0)) "Steps:\n")
                   (markdown:list ((key . 1) (ordered . #f) (tight . #t))
                                  (markdown:item ((key . 0)) (markdown:paragraph ((key . 0)) (markdown:strong () "one") " and " (markdown:code () "two") "\n")))))
                (datums chat)))

(test "the reply is silent, keeping no undo history and never modified, and read-only"
  (check-equal? '(#f 1) (list (buffers:modified? chat) (length (cddr (undo:history chat)))))
  (views:set-point! (view) 5)
  (check-equal? '((buffers:replace! "a read-only span refuses the edit"))
                (map (lambda (c) (list (condition-who c) (condition-message c))) (test-runner:reports-during (lambda () (test-user:press! "x")))))
  (check-equal? "Steps:\none and two\n" (document:text (buffers:document chat))))

(import (tuna) (test) (hooks) (options) (buffers) (document) (buffers-test forms) (buffers-test chat-example))

(define kept-scratch (lambda (buffer) (not (string=? (buffers:name buffer) "*scratch*"))))

(hooks:add! buffers:kill-queries kept-scratch)

(options:define-option fill-column 70 fixnum?)

(buffers:define-layer diagnostics (priority 50) (evaporate))

(test "the configuration's kill query keeps *scratch*"
  (let ([scratch (buffers:make "*scratch*" "")])
    (check-equal? '(#f #t) (list (buffers:kill! scratch) (buffers:live? scratch)))))

(test "the documented examples of making, editing and marking a buffer hold"
  (let ([notes (buffers:make "notes" "Buy milk.\n")])
    (check-equal? "notes" (buffers:name notes))
    (buffers:with-buffer notes (options:set-local! fill-column 60))
    (check-equal? '(60 70) (list (buffers:with-buffer notes (fill-column)) (fill-column)))
    (check-equal? 1 (buffers:edit-version (buffers:replace! notes 1 1 "Today: ")))
    (check-equal? "Today: Buy milk.\n" (document:text (buffers:document notes)))
    (check-equal? #t (buffers:modified? notes))
    (buffers:set-modified! notes #f)
    (check-equal? '(#f 1 1) (list (buffers:modified? notes) (buffers:version notes) (buffers:save-stamp notes)))
    (check-equal? #t (buffers:set-spans! (buffers:layer notes diagnostics) 0 18 (list (list 8 11 '((face . warning) (title . "vague")))) 1))
    (let ([a (buffers:anchor notes 8)])
      (buffers:replace! notes 1 1 "* ")
      (check-equal? 10 (buffers:anchor-position a)))
    (buffers:kill! notes)))

(test "the forms example's kind has its draw procedure"
  (check (eq? buffers-test/forms:draw-field (buffers:kind-draw (buffers:kind 'buffers-test/forms:field)))))

(test "the chat example writes replies silently with splice!, which asks no kind; they refuse the user's edits and the prompt takes them"
  (buffers-test/chat-example:add-reply! "Hello.")
  (buffers-test/chat-example:add-reply! "How can I help?")
  (check-equal? '((buffers-test/chat-example:transcript () (buffers-test/chat-example:reply () "Hello.") (buffers-test/chat-example:reply () "How can I help?")
                   (buffers-test/chat-example:prompt ())))
                (document:datums (buffers:document buffers-test/chat-example:chat)))
  (check-equal? '(#f #t #f) (list (buffers:modified? buffers-test/chat-example:chat) (buffers:edit-silent? (car (buffers:edits-since buffers-test/chat-example:chat 0)))
                                  (buffers:silent? buffers-test/chat-example:chat)))
  (check-equal? "the node refuses the edit"
    (guard (c [(buffers:refused? c) (condition-message c)]) (buffers:replace! buffers-test/chat-example:chat 2 2 "x")))
  (buffers:replace! buffers-test/chat-example:chat 27 27 "Thanks")
  (check-equal? "Hello.How can I help?Thanks" (document:text (buffers:document buffers-test/chat-example:chat))))

(test "reloading the chat alone keeps its buffer; reloading buffers closes every buffer, and the chat makes its own again from its saved data"
  (let ([before buffers-test/chat-example:chat] [notes (buffers:make "notes" "x\n")])
    (reload-modules! '((buffers-test chat-example)))
    (check (eq? before (buffers:find "*chat*")))
    (reload-modules! '((buffers)))
    (let ([chat (buffers:find "*chat*")])
      (check-equal? '(#f #f #t) (list (buffers:live? before) (buffers:live? notes) (buffers:live? chat)))
      (check (not (eq? before chat)))
      (check-equal? "Hello.How can I help?" (document:text (buffers:document chat)))
      (check-equal? '("*chat*") (map buffers:name (remp (lambda (b) (buffers:internal-name? (buffers:name b))) (buffers:all)))))))

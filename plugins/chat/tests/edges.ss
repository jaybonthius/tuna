(import (tuna) (test) (test-user) (buffers) (document) (views) (kill-ring) (editing) (markdown) (chat) (chat-test fake-talks)
        (chat-test fake-agents) (chat-test))

(define e (chat-test/fake-talks:start 'echo (getenv "HOME")))

(chat:show! e)

(define b (chat:buffer e))

(define (sent) (chat-test:prompt-text e))

(define (node-of kind)
  (let* ([doc (buffers:document b)] [n (document:length doc)])
    (let loop ([p 0])
      (and (< p n)
           (let ([t (document:token doc p)])
             (if (and (document:node? t) (eq? (document:node-kind t) kind)) t (loop (+ p 1))))))))

(define (on-prompt offset keys)
  (chat:set-prompt! e "hi there")
  (views:set-point! (chat-test:view) (+ (chat:prompt-start e) offset))
  (let ([reports (chat-test:press! keys)])
    (list (sent) (- (views:point (chat-test:view)) (chat:prompt-start e)) reports)))

(define cases
  '((8 "C-d") (0 "DEL") (6 "C-u 5 C-d") (8 "C-k") (3 "C-u 2 C-k") (3 "C-S-DEL") (8 "M-d") (0 "M-DEL") (8 "M-u") (8 "C-t")
    (3 "M-t") (0 "M-^")))

(test "the prompt is isolating: it keeps the line break the text sent is read up to, and only the buffer's edges raise"
  (check-equal? '(("hi there" 8 ("end of buffer")) ("hi there" 0 ("beginning of buffer")) ("hi the" 6 ()) ("hi there" 8 ("end of buffer"))
                  ("hi " 3 ()) ("" 0 ()) ("hi there" 8 ()) ("hi there" 0 ()) ("hi there" 8 ()) ("hi theer" 8 ()) ("there hi" 8 ())
                  ("hi there" 0 ()))
    (map (lambda (c) (apply on-prompt c)) cases)))

(test "with the source's datums above and below the prompt it behaves the same, but nothing raises at the edges"
  (chat-test/fake-talks:talk-above-set! e (list (chat:message '((key . w1)) "w1\n")))
  (chat-test/fake-talks:talk-below-set! e (list (chat:message '((key . w2)) "w2\n")))
  (chat:changed! e)
  (test-user:settle)
  (check-equal? "w1\nhi there\nw2\n" (chat-test:shown e))
  (check-equal? '(("hi there" 8 ()) ("hi there" 0 ()) ("hi there" 6 ("the node refuses the edit")) ("hi there" 8 ())
                  ("hi " 3 ()) ("" 0 ()) ("hi there" 8 ()) ("hi there" 0 ()) ("hi there" 8 ()) ("hi theer" 8 ()) ("there hi" 8 ())
                  ("hi there" 0 ()))
    (map (lambda (c) (apply on-prompt c)) cases)))

(test "blocks yanked into the prompt go in as text; a line moved into the datum above is refused; a region reaching out of the prompt is refused"
  (kill-ring:push! (list (buffers:piece (buffers:make "*plan*" '(markdown:quote () (markdown:heading ((level . 1)) "Plan\n"))) 1 8)))
  (check-equal? '("Plan\nhi there" 5 ()) (on-prompt 0 "C-y"))
  (check-equal? '("w1hi there" 0 ("the node refuses the edit")) (on-prompt 0 "C-x C-t"))
  (chat:set-prompt! e "hi there")
  (views:set-point! (chat-test:view) (+ (chat:prompt-start e) 3))
  (views:set-mark! (chat-test:view) (+ (document:node-start (node-of 'chat:message)) 1))
  (check-equal? '("the node refuses the edit") (chat-test:press! "C-w"))
  (check-equal? "hi there" (sent)))

(test "code that inserts after the prompt's final line break is refused, so the text sent stays what is before it"
  (check-equal? "the edit would leave a block without its final line break"
    (guard (c [(buffers:refused? c) (condition-message c)])
      (buffers:insert! b (+ (chat:prompt-end e) 1) "x")))
  (check-equal? "hi there" (sent)))

(define (field-text)
  (let ([n (node-of 'chat:field)])
    (buffers:text-between (buffers:document b) (+ (document:node-start n) 1) (- (document:node-end n) 2))))

(define (on-field offset keys)
  (let ([n (node-of 'chat:field)])
    (buffers:replace! b (+ (document:node-start n) 1) (- (document:node-end n) 2) "ab cd"))
  (views:set-point! (chat-test:view) (+ (document:node-start (node-of 'chat:field)) 1 offset))
  (let ([reports (chat-test:press! keys)])
    (list (field-text) (- (views:point (chat-test:view)) (document:node-start (node-of 'chat:field)) 1) reports)))

(test "a question's field is isolating too, and one without lines refuses a line break"
  (chat-test/fake-talks:ask! e "q1" "Name?" 'field)
  (test-user:settle)
  (check-equal? '(("ab cd" 5 ()) ("ab cd" 0 ()) ("ab cd" 5 ()) ("" 0 ()) ("" 0 ()) ("ab cd" 5 ()) ("ab cd" 0 ()) ("cd ab" 5 ())
                  ("ab dc" 5 ()) ("AB cd" 2 ()))
    (map (lambda (c) (apply on-field c))
         '((5 "C-d") (0 "DEL") (5 "C-k") (0 "C-u 2 C-k") (1 "C-S-DEL") (5 "M-d") (0 "M-DEL") (2 "M-t") (5 "C-t") (0 "M-u"))))
  (kill-ring:push! (list "xy"))
  (check-equal? '("xyab cd" 2 ()) (on-field 0 "C-y"))
  (kill-ring:push! (list "x\ny"))
  (check-equal? '("ab cd" 0 ("the node refuses the edit")) (on-field 0 "C-y"))
  (check-equal? '("Name?ab cd" 0 ("the node refuses the edit")) (on-field 0 "C-x C-t"))
  (views:set-mark! (chat-test:view) (+ (document:node-start (node-of 'chat:header)) 1))
  (check-equal? '("the node refuses the edit") (chat-test:press! "C-w"))
  (check-equal? "Name?ab cd" (field-text)))

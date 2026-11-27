(import (tuna) (test) (buffers) (document) (buffers-test md) (buffers-test))

(define (syntax-message name)
  (guard (c [(syntax-violation? c) (list (condition-message c) (syntax->datum (syntax-violation-subform c)))])
    (load-module! (list 'buffers-test name))
    'accepted))

(buffers:define-kind own)
(buffers:define-kind grid (content nodes) (whole))
(buffers:define-kind passed (inline) (stops none))
(buffers:define-kind sealed (consent (lambda (node edit) #f)))
(buffers:define-kind said (consent (lambda (node edit) "Said no")))

(define asked '())

(define (no-digits node edit)
  (let ([inserted (document:text (buffers:piece-document (buffers:edit-inserted edit)))])
    (set! asked (cons (list (document:node-kind node) (buffers:edit-start edit) inserted) asked))
    (not (exists char-numeric? (string->list inserted)))))

(buffers:define-kind words (consent no-digits))

(define words-name (buffers:kind-name (buffers:constructor-kind words)))

(define consulted '())

(buffers:define-kind told
  (consent (lambda (node edit) (set! consulted (cons (buffers:name (buffers:edit-buffer edit)) consulted)) #t)))

(test "a kind is found by its name while it is defined, with its draw procedure and keymap"
  (check-equal? '(buffers-test/md:para #f #t #f)
    (list (buffers:kind-name (buffers:kind 'buffers-test/md:para)) (buffers:kind 'nothing) (buffers:kind? (buffers:kind 'buffers-test/md:para))
          (buffers:kind? 'buffers-test/md:para)))
  (check-equal? '(#f #f) (list (buffers:kind-draw (buffers:kind 'buffers-test/md:para)) (buffers:kind-keymap (buffers:kind 'buffers-test/md:para))))
  (check-raises (buffers-test:raised-with? 'buffers:kind "not a symbol" '("buffers-test/md:para")) (buffers:kind "buffers-test/md:para")))

(test "define-kind binds a procedure that makes the kind's datum: a node, or an atom of attributes"
  (check-equal? '(#(buffers-test/md:image ((src . "x.png"))) (buffers-test/md:para () "a" (buffers-test/md:link () "b")))
    (list (buffers-test/md:image '((src . "x.png"))) (buffers-test/md:para '() "a" (buffers-test/md:link '() "b")))))

(test "a constructor names its kind, and a kind its name and the owner of the module that defined it"
  (check-equal? (list 'buffers-test/md:para (module-owner '(buffers-test md)))
    (let ([k (buffers:constructor-kind buffers-test/md:para)]) (list (buffers:kind-name k) (buffers:kind-owner k))))
  (check-equal? #f (buffers:constructor-kind buffers-test:fresh))
  (let ([k (buffers:constructor-kind own)])
    (check (eq? k (buffers:kind (buffers:kind-name k))))
    (check (eq? (current-owner) (buffers:kind-owner k))))
  (check (eq? (module-owner '(buffers)) (buffers:kind-owner (buffers:kind 'document:raw-byte))))
  (check-raises (buffers-test:raised-with? 'buffers:constructor-kind "not a procedure" '(buffers-test/md:para)) (buffers:constructor-kind 'buffers-test/md:para))
  (check-raises (buffers-test:raised-with? 'buffers:kind-name "not a kind" '(buffers-test/md:para)) (buffers:kind-name 'buffers-test/md:para)))

(test "define-kind's clauses are checked where it is written, and its procedures when it runs"
  (check-equal? '(("clause given twice" (content nodes)) ("invalid clause" (colour red)) ("invalid clause" (content green))
                  ("invalid clause" (whole #t)) ("a text clause needs (content atom)" (text label))
                  ("an atom has no inside to isolate" (isolating)))
    (map syntax-message '(kind-clause-twice kind-unknown-clause kind-unknown-content kind-whole-argument kind-text-not-atom
                          kind-atom-isolating)))
  (check-raises (buffers-test:raised-with? 'buffers:define-kind "not a procedure or #f" '(not-a-procedure))
    (load-module! '(buffers-test kind-draw-symbol))))

(test "a kind that says (whole) is whole, and so is every atom kind"
  (check-equal? '(#t #f #t #t) (map (lambda (k) (buffers:kind-whole? (buffers:kind k))) (list (buffers:kind-name (buffers:constructor-kind grid)) 'buffers-test/md:para 'buffers-test/md:image 'document:raw-byte)))
  (check-raises (buffers-test:raised-with? 'buffers:kind-whole? "not a kind" '(grid)) (buffers:kind-whole? 'grid)))

(test "raw bytes have one stop each and are edited as text is, with no plugin loaded for them"
  (let ([raw (buffers-test:fresh (list 'buffers:text '() "ab" (vector 'document:raw-byte '((byte . 233))) "c\n"))])
    (check-equal? '(1 2 3 4 5 6) (buffers-test:all-stops raw))
    (buffers:replace! raw 3 3 "x")
    (buffers:replace! raw 4 5 "")
    (check-equal? '(buffers:text () "abxc\n") (buffers-test:root raw))))

(test "a node with (stops none) has no stops inside"
  (check-equal? '(2 3 4 8 9 10) (buffers-test:all-stops (buffers-test:fresh (buffers-test/md:doc '() (buffers-test/md:para '() "ab" (passed '() "cd") "ef\n"))))))

(test "a node of an undefined kind has the stops of text but typing goes outside it, and it refuses edits inside while deleting it whole is allowed"
  (let ([u (buffers-test:fresh '(buffers-test/md:doc () (buffers-test/md:para () "ab" (unknown:kind () "cd") "ef\n")))])
    (check-equal? '(2 3 4 6 8 9 10) (buffers-test:all-stops u))
    (check-equal? '(4 2 #f) (list (buffers:stop u 5) (buffers:stop u 0) (buffers:stop u 13)))
    (check-raises (buffers-test:raised-with? 'buffers:replace! "inside a node whose kind is not loaded" '(unknown:kind))
      (buffers:replace! u 6 6 "x"))
    (check-raises (buffers-test:raised-with? 'buffers:replace! "inside a node whose kind is not loaded" '(unknown:kind))
      (buffers:replace! u 3 7 ""))
    (check (buffers:refused? (guard (c [#t c]) (buffers:replace! u 6 6 "x"))))
    (buffers:replace! u 4 8 "")
    (check-equal? '(buffers-test/md:doc () (buffers-test/md:para () "abef\n")) (buffers-test:root u))))

(test "a kind's consent sees the node and the edit as it will be made, and refuses with a buffers:refused? condition"
  (let ([w (buffers-test:fresh (buffers-test/md:doc '() (words '() "ab\n")))])
    (set! asked '())
    (buffers:replace! w 3 3 "c")
    (check-equal? '(refused "the node refuses the edit")
      (buffers-test:refusal (lambda () (buffers:replace! w 3 3 "4"))))
    (check-equal? (list (list words-name 3 "c") (list words-name 3 "4")) (reverse asked))
    (check-equal? (list 'buffers:replace! (list words-name)) (guard (c [(buffers:refused? c) (list (condition-who c) (condition-irritants c))]) (buffers:replace! w 3 3 "4")))
    (check-equal? 1 (buffers:version w))))

(test "refuses-text? asks the same consents about text in place of a range, without editing"
  (let ([w (buffers-test:fresh (buffers-test/md:doc '() (words '() "ab\n")))] [s (buffers-test:fresh (buffers-test/md:doc '() (sealed '() "ab\n")))])
    (set! asked '())
    (check-equal? '(#f 0) (list (buffers:refuses-text? w 3 3) (buffers:version w)))
    (check-equal? (list (list words-name 3 "x")) asked)
    (check-equal? '(#t #t 0) (list (buffers:refuses-text? s 3 3) (buffers:refuses-text? s 2 4) (buffers:version s)))))

(test "a consent that returns a string refuses with it as the message and no irritant"
  (let ([s (buffers-test:fresh (buffers-test/md:doc '() (said '() "ab\n")))])
    (check-equal? '("Said no" ())
      (guard (c [(buffers:refused? c) (list (condition-message c) (condition-irritants c))]) (buffers:replace! s 3 3 "x")))
    (check-equal? '(#t 0) (list (buffers:refuses-text? s 3 3) (buffers:version s)))))

(test "a consent is told the buffer the edit is made in, whichever buffer is current, and so is refuses-text?'s probe"
  (let ([other (buffers-test:fresh "x\n")] [t (buffers-test:fresh (buffers-test/md:doc '() (told '() "ab\n")))])
    (buffers:with-buffer other (buffers:replace! t 3 3 "x"))
    (check-equal? #f (buffers:refuses-text? t 3 3))
    (check-equal? (list (buffers:name t) (buffers:name t)) consulted)))

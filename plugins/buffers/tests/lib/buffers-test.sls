#!tuna
(import (buffers) (document))

(define (fresh content) (buffers:make (buffers:free-name "b") content))

(define (root b) (car (document:datums (buffers:document b))))

(define (children b) (cddr (root b)))

(define (raised? who message)
  (lambda (c)
    (and (who-condition? c) (eq? who (condition-who c))
         (message-condition? c) (string=? message (condition-message c)))))

(define (raised-with? who message irritants)
  (lambda (c)
    (and ((raised? who message) c)
         (equal? irritants (if (irritants-condition? c) (condition-irritants c) '())))))

(define (refusal thunk)
  (guard (c [(buffers:refused? c) (list 'refused (condition-message c))])
    (thunk)
    'allowed))

(define (reports-during thunk)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (thunk)
    (advice-remove! report keep)
    (reverse reported)))

(define (on-thread thunk)
  (let ([result #f])
    (join-task
      (fork-task
        (lambda (restore)
          (set! result
            (guard (c [(and (who-condition? c) (message-condition? c)) (list (condition-who c) (condition-message c))])
              (thunk))))))
    result))

(define (all-spans layer b) (buffers:spans layer 0 (document:length (buffers:document b))))

(define (all-stops b)
  (let loop ([p (or (buffers:stop b 0) (buffers:next-stop b 0))] [acc '()])
    (if p (loop (buffers:next-stop b p) (cons p acc)) (reverse acc))))

(define (kind-at b p) (document:node-kind (document:enclosing (buffers:document b) p)))

(define (%boundary? t) (or (eq? t 'close) (and (document:node? t) (not (document:atom? t)))))

(define (%place-start b p)
  (let ([doc (buffers:document b)])
    (let loop ([a p])
      (if (and (> a 0) (%boundary? (document:token doc (- a 1)))) (loop (- a 1)) a))))

(define (%place-end b p)
  (let ([doc (buffers:document b)])
    (let loop ([z p])
      (if (and (< z (document:length doc)) (%boundary? (document:token doc z))) (loop (+ z 1)) z))))

(define (backspace! b p) (buffers:replace! b (- (%place-start b p) 1) p ""))

(define (delete-forward! b p) (buffers:replace! b p (+ (%place-end b p) 1) ""))

(define (kill! b start end)
  (let ([slice (document:slice (buffers:document b) start end)])
    (buffers:replace! b start end "")
    slice))

(define (yank! b p slice) (buffers:replace! b p p slice))

(define (%search text needle)
  (let ([n (string-length needle)])
    (let loop ([i 0])
      (cond
        [(> (+ i n) (string-length text)) (assertion-violation 'buffers-test:at "not found" needle)]
        [(string=? (substring text i (+ i n)) needle) i]
        [else (loop (+ i 1))]))))

(define (at b marked)
  (let* ([doc (buffers:document b)]
         [text (list->string (map (lambda (c) (if (char=? c #\xFFFC) #\@ c)) (string->list (document:text doc))))]
         [bar (%search marked "|")]
         [needle (string-append (substring marked 0 bar) (substring marked (+ bar 1) (string-length marked)))])
    (buffers:stop b (document:position doc (+ (%search text needle) bar) (document:unit characters)))))

(define md-datum
  '(buffers-test/md:doc ()
     (buffers-test/md:heading ((level . 1)) "Title\n")
     (buffers-test/md:para () "Alpha " (buffers-test/md:link ((href . "https://x")) "beta") " gamma.\n")
     (buffers-test/lists:bulleted () (buffers-test/md:item () "one\n") (buffers-test/md:item () "two\n") (buffers-test/md:item () "three\n"))
     (buffers-test/md:code ((lang . "scheme")) "(car x)\n")
     (buffers-test/md:para () "Last " #(buffers-test/md:image ((src . "a.png"))) " line.\n")))

(define form-datum
  '(buffers-test/form:form ()
     (buffers-test/form:row () (buffers-test/form:label () "Name: ") (buffers-test/form:field ((name . name)) "John")
                  (buffers-test/form:label () "  Email: ") (buffers-test/form:field ((name . email))) "\n")
     (buffers-test/form:row () (buffers-test/form:label () "Notes: ") (buffers-test/form:field ((name . notes)) "first") "\n")
     #(buffers-test/form:button ((label . "Send")))))

(define (make-all! names) (for-each (lambda (n) (buffers:make n "")) names))

(define (names) (map buffers:name (buffers:all)))

(define (saved-order)
  (let ([f (string-append (getenv "HOME") "/.local/share/tuna/saved/tuna/buffers/saved-order.ss")])
    (and (file-exists? f) (call-with-input-file f read))))

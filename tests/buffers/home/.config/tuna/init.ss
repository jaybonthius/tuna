(import (hooks) (options) (timers) (scopes) (plugins))
(import (tuna) (testing) (document))
(use-plugin buffers
  (config
    (hooks:add! buffers:kill-queries
      (lambda (buffer) (not (string=? (buffers:name buffer) "*scratch*"))))))
(import (md) (form))
;; Loaded, not imported, so its unload in a test stays an unload.
(load-module! '(lists))

;; The configuration is read again when a plugin it imports reloads, so
;; the next name is found among the buffers rather than counted.
(define (fresh content)
  (let next ([n 1])
    (if (buffers:find (format "b~a" n))
        (next (+ n 1))
        (buffers:make (format "b~a" n) content))))

(define (root b) (car (document:datums (buffers:document b))))
(define (children b) (cddr (root b)))

(define (boundary? t) (or (eq? t 'close) (and (document:node? t) (not (document:atom? t)))))

(define (place-start b p)
  (let ([doc (buffers:document b)])
    (let loop ([a p])
      (if (and (> a 0) (boundary? (document:token doc (- a 1)))) (loop (- a 1)) a))))

(define (place-end b p)
  (let ([doc (buffers:document b)])
    (let loop ([z p])
      (if (and (< z (document:length doc)) (boundary? (document:token doc z))) (loop (+ z 1)) z))))

(define (search text needle)
  (let ([n (string-length needle)])
    (let loop ([i 0])
      (cond
        [(> (+ i n) (string-length text)) (error 'search "not found" needle)]
        [(string=? (substring text i (+ i n)) needle) i]
        [else (loop (+ i 1))]))))

;; The stop at the place "|" marks in the buffer's text, where an atom
;; reads as @.
(define (at b marked)
  (let* ([doc (buffers:document b)]
         [text (list->string (map (lambda (c) (if (char=? c #\xFFFC) #\@ c)) (string->list (document:text doc))))]
         [bar (search marked "|")]
         [needle (string-append (substring marked 0 bar) (substring marked (+ bar 1) (string-length marked)))])
    (buffers:stop b (document:position doc (+ (search text needle) bar) (document:unit characters)))))

(define (all-stops b)
  (let loop ([p (or (buffers:stop b 0) (buffers:next-stop b 0))] [acc '()])
    (if p (loop (buffers:next-stop b p) (cons p acc)) (reverse acc))))

(define (backspace b p) (buffers:replace! b (- (place-start b p) 1) p ""))
(define (delete-forward b p) (buffers:replace! b p (+ (place-end b p) 1) ""))
(define (kill b start end)
  (let ([slice (document:slice (buffers:document b) start end)])
    (buffers:replace! b start end "")
    slice))
(define (yank b p slice) (buffers:replace! b p p slice))

(define (refusal thunk)
  (guard (c [(buffers:refused? c) (list 'refused (condition-message c))])
    (thunk)
    'allowed))

(define (kind-at b p) (document:node-kind (document:enclosing (buffers:document b) p)))

(define md-datum
  '(md:doc ()
     (md:heading ((level . 1)) "Title\n")
     (md:para () "Alpha " (md:link ((href . "https://x")) "beta") " gamma.\n")
     (lists:bulleted () (md:item () "one\n") (md:item () "two\n") (md:item () "three\n"))
     (md:code ((lang . "scheme")) "(car x)\n")
     (md:para () "Last " #(md:image ((src . "a.png"))) " line.\n")))

(define form-datum
  '(form:form ()
     (form:row () (form:label () "Name: ") (form:field ((name . name)) "John")
                  (form:label () "  Email: ") (form:field ((name . email))) "\n")
     (form:row () (form:label () "Notes: ") (form:field ((name . notes)) "first") "\n")
     #(form:button ((label . "Send")))))
(import (console))

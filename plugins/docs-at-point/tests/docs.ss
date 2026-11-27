(import (tuna) (test) (faces) (docs-at-point))

(define (raised? who message)
  (lambda (c)
    (and (who-condition? c) (eq? who (condition-who c))
         (message-condition? c) (string=? message (condition-message c)))))

(test "docs-at-point loads without the echo area or any other display"
  (check (member '(docs-at-point) (loaded-modules)))
  (check (not (member '(echo-area) (loaded-modules))))
  (check (not (member '(docs-at-point-display) (loaded-modules)))))

(test "a doc keeps its text, thing, face and spans; its echo is its text unless the options give one or #f; markdown is off by default"
  (let ([d (docs-at-point:make-doc "total(items) -> Decimal"
             (docs-at-point:doc-options [thing "total"] [face faces:function] [spans (list (list 6 11 faces:highlight))]))])
    (check (docs-at-point:doc? d))
    (check-equal? (list "total(items) -> Decimal" "total" "total(items) -> Decimal" (list (list 6 11 faces:highlight)) #f)
                  (list (docs-at-point:doc-text d) (docs-at-point:doc-thing d) (docs-at-point:doc-echo d)
                        (docs-at-point:doc-spans d) (docs-at-point:doc-markdown? d))))
  (let ([plain (docs-at-point:make-doc "plain")])
    (check-equal? '("plain" #f "plain" () #f)
                  (list (docs-at-point:doc-text plain) (docs-at-point:doc-thing plain) (docs-at-point:doc-echo plain)
                        (docs-at-point:doc-spans plain) (docs-at-point:doc-markdown? plain))))
  (let ([long (docs-at-point:make-doc "Long text" (docs-at-point:doc-options [markdown] [echo #f]))])
    (check-equal? '(#t #f) (list (docs-at-point:doc-markdown? long) (docs-at-point:doc-echo long))))
  (check-equal? "Short" (docs-at-point:doc-echo (docs-at-point:make-doc "Long text" (docs-at-point:doc-options [echo "Short"]))))
  (check (not (docs-at-point:doc? "text"))))

(test "a doc's text and options are checked"
  (check-raises (raised? 'docs-at-point:make-doc "not a string") (docs-at-point:make-doc 'text))
  (check-raises (raised? 'docs-at-point:make-doc "not doc options") (docs-at-point:make-doc "text" '()))
  (check-raises (raised? 'docs-at-point:doc-options "neither a string nor #f") (docs-at-point:doc-options [thing 'total]))
  (check-raises (raised? 'docs-at-point:doc-options "neither a face nor #f") (docs-at-point:doc-options [face "bold"]))
  (check-raises (raised? 'docs-at-point:doc-options "neither a string nor #f") (docs-at-point:doc-options [echo 5]))
  (check-raises (raised? 'docs-at-point:doc-options "not a list of a start, an end and a face")
                (docs-at-point:doc-options [spans (list (list 5 2 faces:highlight))])))

(test "an unknown clause, or a clause given twice, is a syntax error"
  (for-each
    (lambda (module message)
      (check-raises (lambda (c) (and (syntax-violation? c) (string=? message (condition-message c))))
                    (load-module! (list 'bad-options module))))
    '(unknown-clause clause-twice)
    '("invalid clause" "clause given twice")))

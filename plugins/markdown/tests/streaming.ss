(import (tuna) (test) (test-user) (buffers) (document) (views) (layout) (markdown) (markdown-test chat))

(define (view) (layout:selected-view))

(define chat markdown-test/chat:chat)

(views:set-buffer! (view) chat)

(test "a block that grows at its end grows by an insertion: a cursor and an anchor in a code block streaming line by line stay"
  (markdown-test/chat:receive! "Code:\n\n```scheme\n(define (f x)\n")
  (test-user:settle)
  (check-equal? '((markdown-test/chat:reply () (markdown:paragraph ((key . 0)) "Code:\n") (markdown:code-block ((key . 1) (language . "scheme")) "(define (f x)\n")))
                (document:datums (buffers:document chat)))
  (views:set-point! (view) 18)
  (let ([in-code (buffers:anchor chat 21)] [version (buffers:version chat)])
    (markdown-test/chat:receive! "  (* x 2))\n")
    (test-user:settle)
    (check-equal? '((markdown-test/chat:reply () (markdown:paragraph ((key . 0)) "Code:\n")
                     (markdown:code-block ((key . 1) (language . "scheme")) "(define (f x)\n  (* x 2))\n")))
                  (document:datums (buffers:document chat)))
    (check-equal? '(18 21) (list (views:point (view)) (buffers:anchor-position in-code)))
    (check-equal? '((24 () ("  (* x 2))\n")))
                  (map (lambda (e) (list (buffers:edit-start e) (document:datums (buffers:piece-document (buffers:edit-removed e)))
                                         (document:datums (buffers:piece-document (buffers:edit-inserted e)))))
                       (buffers:edits-since chat version)))
    (check-equal? '("(define (f x)" "  (* x 2))")
                  (map test-user:element-text
                       (test-user:elements (car (test-user:elements (test-user:screen) "markdown-code-block")) "line")))))

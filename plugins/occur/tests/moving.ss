(import (tuna) (test) (test-user) (buffers) (views) (layout) (layout-split) (search) (occur) (isearch-test) (occur-test))

(define where occur-test:where)
(define wins occur-test:wins)

(define (at-line! text) (views:set-point! (occur-test:view) (occur-test:find-text (occur-test:occur-buffer) text)))

(define b (occur-test:src! "one foo\ntwo\nfoo three foo\nfour\nfive foo\n"))

(occur-test:occur! (occur-test:rx "foo") 0 #f)

(occur-test:in-occur!)

(test "M-n goes to the end of the next match, match by match; from inside a match, to its end; M-p to the end of the previous"
  (test-user:press! "M-n")
  (check-equal? "one foo" (where))
  (test-user:press! "M-n")
  (check-equal? "foo" (where))
  (test-user:press! "M-n")
  (check-equal? "foo three foo" (where))
  (views:set-point! (occur-test:view) (- (views:point (occur-test:view)) 2))
  (test-user:press! "M-n")
  (check-equal? "foo three foo" (where))
  (test-user:press! "M-p")
  (check-equal? "foo" (where)))

(test "digits count; past the last match M-n says No more matches and point stays; a negative count turns each backward"
  (test-user:press! "2 M-n")
  (check-equal? "five foo" (where))
  (check-equal? '("No more matches") (occur-test:reported "M-n"))
  (check-equal? "five foo" (where))
  (test-user:press! "- M-n")
  (check-equal? "foo three foo" (where))
  (test-user:press! "- M-p")
  (check-equal? "five foo" (where))
  (views:set-point! (occur-test:view) 2)
  (check-equal? '("No earlier matches") (occur-test:reported "M-p"))
  (check-equal? "" (where)))

(test "n moves from the line's end to the next match and shows its line's first match in another view, highlighted and marked, saying so"
  (at-line! "one foo")
  (occur-test:clear-messages!)
  (test-user:press! "n")
  (check-equal? '("foo" (("src" 13 #f) ("*Occur*" 63 #t)) "Next locus from *Occur*") (list (where) (wins) (occur-test:last-message)))
  (check-equal? (list '("foo" "foo") 3) (list (occur-test:pulsed (occur-test:source-view b)) (occur-test:marked)))
  (at-line! "one foo")
  (test-user:press! "2 n")
  (check-equal? '("foo three foo" (("src" 13 #f) ("*Occur*" 73 #t))) (list (where) (wins))))

(test "p from the line's start goes to the previous match, the last on a line with two, saying so"
  (at-line! "five foo")
  (occur-test:clear-messages!)
  (test-user:press! "p")
  (check-equal? '("foo three foo" (("src" 13 #f) ("*Occur*" 73 #t)) "Previous locus from *Occur*") (list (where) (wins) (occur-test:last-message)))
  (check-equal? (list '("foo" "foo") 3) (list (occur-test:pulsed (occur-test:source-view b)) (occur-test:marked))))

(test "n and p say No more matches past either end"
  (at-line! "one foo")
  (check-equal? '("No more matches") (occur-test:reported "p"))
  (at-line! "five foo")
  (check-equal? '("No more matches") (occur-test:reported "n")))

(test "n and p act in the current *Occur*, even when another was listed later"
  (test-user:press! "r")
  (let ([first-listing (views:buffer (occur-test:view))] [c (buffers:make "src2" "x foo\ny foo\n")])
    (layout:switch-to-buffer c)
    (occur-test:occur! (occur-test:rx "foo") 0 #f)
    (let ([first-view (find (lambda (v) (eq? (views:buffer v) first-listing)) (layout:views))])
      (layout:select! (or first-view (begin (views:set-buffer! (occur-test:view) first-listing) (occur-test:view)))))
    (views:set-point! (occur-test:view) (occur-test:find-text first-listing "one foo"))
    (occur-test:clear-messages!)
    (test-user:press! "n")
    (check-equal? '("*Occur: src*" "Next locus from *Occur: src*")
                  (list (buffers:name (views:buffer (occur-test:view))) (occur-test:last-message)))))

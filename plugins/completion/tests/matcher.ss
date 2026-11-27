(import (tuna) (test)
        (only (completion matcher) pattern? pattern-matcher make-store store-add! store-clear! store-sort! store-matches pattern-spans group-order))

(define (utf8s . texts) (list->vector (map string->utf8 texts)))

(define (store . texts) (make-store (apply utf8s texts) (make-vector (length texts) 0)))

(test "a pattern is a list of contains, starts, ends, not and face terms whose pieces are non-empty strings"
  (check-equal? '(#t #f #f #t #f #f #t #f #f)
    (map pattern? '(((contains "a")) ((contains)) ((ends "a" "b")) ((not (starts "x"))) ((regexp "a")) x
                    ((face m (contains "a"))) ((face "m" (contains "a"))) ((face m))))))

(test "contains finds its pieces in order; a capital in a piece makes it case-sensitive; ends and not combine"
  (let ([s (store "find-file" "files:find-file" "fundamental" "Find" "f")])
    (check-equal? '#(3 0 2 1) (store-matches s '((contains "f" "n" "d"))))
    (check-equal? '#(3) (store-matches s '((contains "Fi"))))
    (check-equal? '#(0) (store-matches s '((ends "file") (not (starts "files")))))
    (check-equal? '#(4 3 0 2 1) (store-matches s '()))))

(test "characters past ASCII are folded and matched at either end, and spans count characters"
  (check-equal? '#(0 1) (store-matches (store "ÉTÉ" "Été" "ete") '((contains "été"))))
  (let ([u (store "naïve" "École" "ÉCOLE" "ecole")])
    (check-equal? '#(2 1) (store-matches u '((starts "éc"))))
    (check-equal? '#(1) (store-matches u '((starts "Éc"))))
    (check-equal? '#(0) (store-matches u '((ends "ïve"))))
    (check-equal? '#(0) (store-matches u '((contains "a" "v")))))
  (check-equal? '((2 3 #f) (4 5 #f)) (pattern-spans '((contains "ï") (ends "e")) "naïve")))

(test "matches sort by rank, then the gaps between pieces, then length, then text, counting characters"
  (check-equal? '#(2 0 1) (store-matches (store "éa" "eaa" "eb") '()))
  (check-equal? '#(1 0) (store-matches (store "axxxb" "aééb") '((contains "a" "b"))))
  (check-equal? '#(2 3 1 0) (store-matches (make-store (utf8s "bbb" "aaa" "cc" "b") (vector 1 1 0 1)) '())))

(test "a span carries its term's face; a later term's match is drawn over an earlier one's; touching matches of one face join"
  (check-equal? '((0 4 #f) (8 10 #f)) (pattern-spans '((contains "f" "n" "d") (contains "file")) "files:find-file"))
  (check-equal? '((6 10 a) (11 15 b))
    (pattern-spans '((face a (contains "find")) (not (contains "x")) (face b (ends "file"))) "files:find-file"))
  (check-equal? '((0 2 a) (2 7 b)) (pattern-spans '((face a (contains "file")) (face b (contains "les:f"))) "files:find-file"))
  (check-equal? '((0 5 a)) (pattern-spans '((face a (contains "fi")) (face a (contains "les"))) "files")))

(test "pattern-matcher tells whether a string matches, faces and negations included"
  (check-equal? #t ((pattern-matcher '((face a (contains "define")) (not (contains "x")))) "define-record"))
  (check-equal? #t ((pattern-matcher '((contains "define") (not (contains "x")))) "define-record"))
  (check-equal? #f ((pattern-matcher '((contains "define") (not (contains "rec")))) "define-record")))

(test "a store keeps arrival order until sorted, sorts what comes after, and a cleared one numbers on from what it held"
  (let ([j (make-store)])
    (store-add! j (utf8s "zeta" "alpha") #f)
    (check-equal? '#(0 1) (store-matches j '()))
    (store-sort! j)
    (store-add! j (utf8s "beta") #f)
    (check-equal? '#(2 0 1) (store-matches j '()))
    (store-clear! j)
    (check-equal? '#() (store-matches j '()))
    (store-add! j (utf8s "be") #f)
    (store-add! j (utf8s "omega" "b") #f)
    (check-equal? '#(3 4 5) (store-matches j '()))
    (check-equal? '#(5) (store-matches j '((contains "b")) 4))
    (store-sort! j)
    (check-equal? '#(5 3 4) (store-matches j '()))
    (check-equal? '#(5 4) (store-matches j '() 4))))

(test "group-order brings each group's matches together in the order of their first, and keeps a vector already grouped"
  (let ([groups (vector 1 0 1 2 0)])
    (check-equal? '#(0 2 1 4 3) (group-order (vector 0 1 2 3 4) (lambda (m) (vector-ref groups m))))
    (let ([grouped (vector 1 4 0 2 3)])
      (check (eq? grouped (group-order grouped (lambda (m) (vector-ref groups m))))))))

(import (tuna) (test) (buffers) (document) (buffers-test md) (buffers-test))

(test "an anchor stays before text inserted at it, an anchor-after moves after it, and set-anchor! moves either"
  (let* ([t (buffers-test:fresh "abcdef\n")] [before (buffers:anchor t 3)] [after (buffers:anchor-after t 3)])
    (check-equal? '(#t #f) (list (buffers:anchor? before) (buffers:anchor? 3)))
    (buffers:replace! t 3 3 "XY")
    (check-equal? '(3 5) (list (buffers:anchor-position before) (buffers:anchor-position after)))
    (buffers:replace! t 1 2 "")
    (check-equal? '(2 #f) (list (buffers:anchor-position before) (buffers:anchor-deleted? before)))
    (buffers:replace! t 1 3 "")
    (check-equal? '(1 #t 2) (list (buffers:anchor-position before) (buffers:anchor-deleted? before) (buffers:anchor-position after)))
    (buffers:set-anchor! before 2)
    (check-equal? '(2 #f) (list (buffers:anchor-position before) (buffers:anchor-deleted? before)))))

(test "an anchor right after a node's opening says it was deleted when the node is"
  (let* ([n (buffers-test:fresh '(buffers-test/md:doc () (buffers-test/md:para () "one\n") (buffers-test/md:para () "two\n")))] [inside (buffers:anchor n 2)])
    (buffers:replace! n 1 7 "")
    (check-equal? '(1 #t (buffers-test/md:doc () (buffers-test/md:para () "two\n")))
      (list (buffers:anchor-position inside) (buffers:anchor-deleted? inside) (buffers-test:root n)))))

(define (reconciled-edits b version)
  (map (lambda (e) (list (buffers:edit-start e) (document:datums (buffers:piece-document (buffers:edit-removed e)))
                         (document:datums (buffers:piece-document (buffers:edit-inserted e)))))
       (buffers:edits-since b version)))

(define (root-node b) (document:token (buffers:document b) 0))

(test "reconcile! keeps the children whose key matches, so anchors inside them stay, and replaces only what lies between"
  (let* ([s (buffers-test:fresh '(buffers-test/md:doc () (buffers-test/md:para ((key . a)) "alpha\n") (buffers-test/md:para ((key . b)) "beta\n")))]
         [in-b (buffers:anchor s 10)])
    (buffers:reconcile! s (root-node s) '((buffers-test/md:heading ((key . top)) "Top\n") (buffers-test/md:para ((key . a)) "alpha!\n") (buffers-test/md:para ((key . b)) "beta\n")))
    (check-equal? '(buffers-test/md:doc () (buffers-test/md:heading ((key . top)) "Top\n") (buffers-test/md:para ((key . a)) "alpha!\n") (buffers-test/md:para ((key . b)) "beta\n"))
                  (buffers-test:root s))
    (check-equal? '((1 () ((buffers-test/md:heading ((key . top)) "Top\n"))) (13 () ("!"))) (reconciled-edits s 0))
    (check-equal? "be" (document:text (buffers:document s) (buffers:anchor-position in-b) (+ (buffers:anchor-position in-b) 2)))))

(test "of what differs, only the part between what old and new share at their start and end is replaced"
  (let* ([g (buffers-test:fresh '(buffers-test/md:doc () (buffers-test/md:para ((key . a)) "Some " (buffers-test/md:link () "bo") "\n")))]
         [in-link (buffers:anchor g 9)] [version (buffers:version g)])
    (buffers:reconcile! g (root-node g) '((buffers-test/md:para ((key . a)) "Some " (buffers-test/md:link () "bold") " text\n")))
    (check-equal? '((10 ((buffers-test/md:link ())) ((buffers-test/md:link () "ld") " text"))) (reconciled-edits g version))
    (check-equal? '((buffers-test/md:doc () (buffers-test/md:para ((key . a)) "Some " (buffers-test/md:link () "bold") " text\n")) 9)
      (list (buffers-test:root g) (buffers:anchor-position in-link)))
    (buffers:reconcile! g (root-node g) '((buffers-test/md:para ((key . a)) "Some text\n")))
    (check-equal? '(buffers-test/md:doc () (buffers-test/md:para ((key . a)) "Some text\n")) (buffers-test:root g))))

(test "reconcile! reorders keyed children and changes their attributes, and the same children make no edit"
  (let ([s (buffers-test:fresh '(buffers-test/md:doc () (buffers-test/md:para ((key . a)) "alpha!\n") (buffers-test/md:para ((key . b)) "beta\n")))])
    (buffers:reconcile! s (root-node s) '((buffers-test/md:para ((key . b)) "beta\n") (buffers-test/md:para ((key . a) (x . 1)) "alpha!\n")))
    (let ([version (buffers:version s)])
      (check-equal? '(buffers-test/md:doc () (buffers-test/md:para ((key . b)) "beta\n") (buffers-test/md:para ((key . a) (x . 1)) "alpha!\n")) (buffers-test:root s))
      (buffers:reconcile! s (root-node s) '((buffers-test/md:para ((key . b)) "beta\n") (buffers-test/md:para ((key . a) (x . 1)) "alpha!\n")))
      (check-equal? version (buffers:version s)))))

(test "text split into other strings, at any depth, is the same text to reconcile!"
  (let ([split (buffers-test:fresh '(buffers-test/md:doc () (buffers-test/md:para () "Some " (buffers-test/md:link () "bold") " text\n")))])
    (buffers:reconcile! split (root-node split) '((buffers-test/md:para () "So" "me " (buffers-test/md:link () "bo" "" "ld") " text" "\n")))
    (check-equal? 0 (buffers:version split))))

(test "reconcile! refuses content that does not fit and a node that is not the buffer's"
  (let ([s (buffers-test:fresh '(buffers-test/md:doc () (buffers-test/md:para () "x\n")))])
    (check-raises (buffers-test:raised? 'buffers:reconcile! "the content does not fit here")
      (buffers:reconcile! s (root-node s) '("text among blocks")))
    (check-raises (buffers-test:raised? 'buffers:reconcile! "not a node of the buffer's document")
      (buffers:reconcile! s (document:token (document:from-datum '(buffers-test/md:doc ())) 0) '()))))

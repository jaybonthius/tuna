(import (tuna) (test) (test-runner) (buffers) (document) (buffers-test md) (buffers-test cards) (buffers-test))

(buffers:define-layer responses (travels) (sticky after))

(define r (buffers-test:fresh (buffers-test/cards:rows '() (buffers-test/cards:row '((label . "one"))) (buffers-test/cards:row '((label . "two"))))))

(define (whole doc) (document:length doc))

(test "the text of a range is its characters and the text each atom's kind gives; openings and closings give nothing"
  (check-equal? "one\ntwo\n" (buffers:text-between (buffers:document r) 0 4))
  (check-equal? '((1 . "one\n") (2 . "two\n")) (buffers:atom-texts (buffers:document r) 0 4))
  (check-equal? '((2 . "two\n")) (buffers:atom-texts (buffers:document r) 2 4))
  (let ([mixed (buffers-test:fresh (buffers-test/md:doc '() (buffers-test/md:para '() "a " (buffers-test/cards:tag '((label . "TAG"))) " b\n")))])
    (check-equal? "a TAG b\n" (buffers:text-between (buffers:document mixed) 0 (whole (buffers:document mixed))))
    (check-equal? " TAG " (buffers:text-between (buffers:document mixed) 3 6))))

(test "a character U+FFFC in the text is no atom"
  (let* ([literal (buffers-test:fresh (buffers-test/md:doc '() (buffers-test/md:para '() (string #\x #\xFFFC #\y #\newline))))] [doc (buffers:document literal)])
    (check-equal? '() (buffers:atom-texts doc 0 (whole doc)))
    (check-equal? 4 (string-length (buffers:text-between doc 0 (whole doc))))))

(test "an atom of a kind with no text clause or of an undefined kind gives none; a raw byte gives U+FFFD"
  (let* ([odd (buffers-test:fresh (list 'buffers-test/cards:rows '() (buffers-test/cards:blank '()) (vector 'nowhere:atom '()) (buffers-test/cards:row '((label . "ok")))))]
         [raw (buffers-test:fresh (list 'buffers:text '() "a" (vector 'document:raw-byte '((byte . 233))) "b\n"))])
    (check-equal? '((1 . "") (2 . "") (3 . "ok\n")) (buffers:atom-texts (buffers:document odd) 0 (whole (buffers:document odd))))
    (check-equal? #\xFFFD (string-ref (buffers:text-between (buffers:document raw) 0 6) 1))))

(test "a text procedure that raises, or returns what is not a string, goes to report as the kind's module's, and its atom gives none"
  (let* ([odd (buffers-test:fresh (buffers-test/cards:rows '() (buffers-test/cards:broken '()) (buffers-test/cards:number '()) (buffers-test/cards:row '((label . "ok")))))]
         [texts #f]
         [reported (test-runner:reports-during
                     (lambda ()
                       (set! texts (buffers:atom-texts (buffers:document odd) 0 (whole (buffers:document odd))))))])
    (check-equal? '((1 . "") (2 . "") (3 . "ok\n")) texts)
    (check-equal? '(car buffers-test/cards:number) (map condition-who reported))
    (check-equal? '("a text procedure returned what is not a string" (42))
      (list (condition-message (cadr reported)) (condition-irritants (cadr reported))))))

(test "content a node takes only as text goes in as its text, atoms included"
  (let ([form (buffers-test:fresh (buffers-test/cards:rows '() (buffers-test/cards:plain '() "x\n")))])
    (buffers:replace! form 2 2 (buffers-test/cards:field '() "a " (buffers-test/cards:tag '((label . "TAG"))) " "))
    (check-equal? '(buffers-test/cards:rows () (buffers-test/cards:plain () "a TAG x\n")) (buffers-test:root form))))

(test "a travelling span after an atom moves by the length its text adds"
  (let ([form (buffers-test:fresh (buffers-test/cards:rows '() (buffers-test/cards:plain '() "x\n")))]
        [source (buffers-test:fresh (buffers-test/md:doc '() (buffers-test/md:para '() (buffers-test/cards:field '() "a" (buffers-test/cards:tag '((label . "TAG"))) "bc" (buffers-test/cards:blank '()) "de") "\n")))])
    (buffers:add-span! (buffers:layer source responses) 8 10 'x)
    (let ([field (buffers:piece source 2 11)])
      (check-equal? '(((buffers-test/cards:field () "a" #(buffers-test/cards:tag ((label . "TAG"))) "bc" #(buffers-test/cards:blank ()) "de")) "aTAGbcde")
        (list (document:datums (buffers:piece-document field)) (buffers:piece-text field)))
      (buffers:replace! form 2 2 field))
    (check-equal? '(buffers-test/cards:rows () (buffers-test/cards:plain () "aTAGbcdex\n")) (buffers-test:root form))
    (check-equal? '((8 10 x)) (buffers-test:all-spans (buffers:layer form responses) form))
    (check-equal? "de" (document:text (buffers:document form) 8 10))))

(test "the arguments are a document, or a slice of one, and a range of it"
  (check-raises (buffers-test:raised-with? 'buffers:text-between "not a document" '(x)) (buffers:text-between 'x 0 1))
  (check-raises (buffers-test:raised-with? 'buffers:atom-texts "not a range of the document" '(3 1)) (buffers:atom-texts (buffers:document r) 3 1))
  (check-raises (buffers-test:raised-with? 'buffers:text-between "not a range of the document" '(0 99)) (buffers:text-between (buffers:document r) 0 99))
  (let ([part (document:slice (buffers:document r) 2 (whole (buffers:document r)))])
    (check-equal? '("two\n" ((0 . "two\n"))) (list (buffers:text-between part 0 (whole part)) (buffers:atom-texts part 0 (whole part))))))

(test "the text of a range is read on the main thread only"
  (let ([doc (buffers:document r)])
    (check-equal? '(buffers:text-between "not on the main thread") (buffers-test:on-thread (lambda () (buffers:text-between doc 0 4))))))

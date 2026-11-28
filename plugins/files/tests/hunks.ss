(import (tuna) (test) (hooks) (buffers) (files) (files-test))

(define (numbered-lines n) (apply string-append (map (lambda (i) (format "line ~a\n" i)) (iota n))))

(define (line-start text k)
  (let loop ([i 0] [line 0])
    (if (= line k) (+ i 1) (loop (+ i 1) (if (char=? (string-ref text i) #\newline) (+ line 1) line)))))

(define reverts 0)

(define (count-revert buffer) (set! reverts (+ reverts 1)))

(test "files:revert-from-file of a file changed at two places far apart replaces two hunks in one batch, keeps an anchor between them on its text, and runs files:after-revert once"
  (let* ([text (numbered-lines 600)] [_ (files-test:write-text! "~/far.txt" text)] [far (files:visit "~/far.txt")]
         [middle (buffers:anchor far (line-start text 250))])
    (files-test:write-text! "~/far.txt"
      (apply string-append (map (lambda (i) (format (if (memv i '(5 500)) "changed ~a\n" "line ~a\n") i)) (iota 600))))
    (hooks:add! files:after-revert count-revert)
    (let ([version (buffers:version far)])
      (files:revert-from-file far)
      (check-equal? (files-test:read-text "~/far.txt") (files-test:text far))
      (check-equal? 2 (length (buffers:edits-since far version)))
      (check-equal? 1 reverts)
      (check-equal? (line-start (files-test:text far) 250) (buffers:anchor-position middle))
      (check-equal? #f (buffers:modified? far)))
    (hooks:remove! files:after-revert count-revert)))

(test "within a changed line only the characters that differ are replaced, so an anchor before them on that line stays"
  (files-test:write-text! "~/word.txt" "alpha beta gamma\n")
  (let* ([word (files:visit "~/word.txt")] [at-alpha (buffers:anchor word 2)] [at-gamma (buffers:anchor word 13)])
    (files-test:write-text! "~/word.txt" "alpha BETA gamma\n")
    (files:revert-from-file word)
    (check-equal? '("alpha BETA gamma\n" 2 13) (list (files-test:text word) (buffers:anchor-position at-alpha) (buffers:anchor-position at-gamma)))))

(define (alternating n changed?)
  (apply string-append (map (lambda (i) (if (and changed? (even? i)) (format "other ~a\n" i) (format "line ~a\n" i))) (iota n))))

(test "a file whose lines mostly differ, past the diff's work limit, is replaced as one block from its first changed line to its last"
  (files-test:write-text! "~/many.txt" (alternating 6000 #f))
  (let ([many (files:visit "~/many.txt")])
    (files-test:write-text! "~/many.txt" (alternating 6000 #t))
    (let ([version (buffers:version many)])
      (files:revert-from-file many)
      (check-equal? (files-test:read-text "~/many.txt") (files-test:text many))
      (check-equal? 1 (length (buffers:edits-since many version))))))

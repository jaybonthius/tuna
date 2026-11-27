(import (tuna) (test) (test-runner) (test-user) (options) (document) (buffers) (files) (undo) (undo-log) (undo-log disk)
        (edits) (logs))

(options:set! undo-log:keep-log? (lambda (path) #t))

(define (text b) (document:text (buffers:document b)))

(define t-path (logs:home-path "t.txt"))

(logs:write-text! t-path "start\n")

(define t (files:visit t-path))

(define (in-t command . args) (apply edits:run-in t command args))

(define (count-read file)
  (let-values ([(records torn?) (read-log file)]) (length records)))

(test "a log cut at any byte, or followed by zeros, reads as exactly the records written whole"
  (for-each (lambda (s) (in-t edits:type s)) '("q\"uo" "te\\" "λ ü"))
  (test-user:settle)
  (in-t edits:type "!")
  (test-user:settle)
  (in-t edits:insert 1 "a\nb\x0;")
  (test-user:settle)
  (in-t undo:undo 1)
  (test-user:settle)
  (in-t edits:delete 1 3)
  (test-user:settle)
  (files:save-buffer t)
  (in-t edits:insert 2 "\t")
  (test-user:settle)
  (in-t undo:undo 2)
  (test-user:settle)
  (in-t undo:redo 1)
  (check-equal? '(undo-history group saved at more group at group saved group at at) (logs:logged-kinds t-path 12))
  (let* ([file (logs:log-of t-path)]
         [all (call-with-port (open-file-input-port file) get-bytevector-all)]
         [ends (filter (lambda (i) (= (bytevector-u8-ref all i) 10)) (iota (bytevector-length all)))]
         [cut (string-append file ".cut")]
         [zeros (make-bytevector 4096 0)]
         [records-at (lambda (n tail)
                       (call-with-port (open-file-output-port cut (file-options no-fail))
                         (lambda (p) (put-bytevector p all 0 n) (put-bytevector p tail)))
                       (count-read cut))]
         [whole (lambda (n) (length (filter (lambda (e) (<= e n)) ends)))])
    (check-equal? '()
      (filter (lambda (n) (not (and (= (records-at n #vu8()) (whole n)) (= (records-at n zeros) (whole n)))))
              (iota (+ (bytevector-length all) 1))))
    (let-values ([(records torn?) (read-log file)]) (check-equal? '(12 #f) (list (length records) torn?)))
    (let-values ([(records torn?) (read-log cut)]) (check torn?))
    (delete-file cut)))

(test "a visit of a log a crash cut short attaches what the whole records hold, and writes the log again whole"
  (let ([before (list (text t) (edits:tree t))] [file (logs:log-of t-path)])
    (in-t edits:insert 1 "lost")
    (logs:logged-kinds t-path 13)
    (let ([size (call-with-port (open-file-input-port file) port-length)])
      (call-with-port (open-file-output-port file (file-options no-fail no-truncate))
        (lambda (p) (truncate-port p (- size 3)))))
    (reload-modules! '((buffers)))
    (test-runner:wait-until (lambda () (= (length (files:buffers)) 1)))
    (set! t (files:visit t-path))
    (check-equal? (list "art\nq\"uote\\λ ü!" #f before) (list (text t) (buffers:modified? t) (list (text t) (edits:tree t))))
    (test-runner:wait-until (lambda () (let-values ([(records torn?) (read-log file)]) (not torn?))))
    (let-values ([(records torn?) (read-log file)])
      (check-equal? '(undo-history group group group group saved saved at) (map car records)))))

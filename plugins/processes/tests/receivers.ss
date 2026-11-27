(import (tuna) (test) (processes))

(define (violation thunk)
  (guard (c [(assertion-violation? c) (list (condition-who c) (condition-message c))])
    (thunk)
    'no-violation))

(define (received make-receiver . pieces)
  (let* ([got '()] [receive (make-receiver (lambda (text end) (set! got (cons (list text end) got))))])
    (for-each (lambda (piece) (receive (car piece) (cdr piece))) pieces)
    (reverse got)))

(test "processes:line-receiver passes each whole line decoded as UTF-8, with the offset after its line feed, less a carriage return before it"
  (check-equal? `(("one" 5) ("twé" 10) ("\xFFFD;" 12) ("last" 16) (,(eof-object) 16))
    (received (lambda (on-line) (processes:line-receiver 0 on-line))
      (cons (string->utf8 "one\r\ntw") 7)
      (cons (bytevector #xC3) 8)
      (cons (bytevector #xA9 10 #xFF 10 108 97 115 116) 16)
      (cons (eof-object) 16))))

(test "a line receiver given output that starts after its offset skips to the first separator, since the log cut that line"
  (check-equal? '(("whole" 18))
    (received (lambda (on-line) (processes:line-receiver 2 on-line)) (cons (string->utf8 "ut line\nwhole\n") 18))))

(test "given a separator byte, a line receiver splits on that byte and trims no carriage return"
  (check-equal? `(("a\r" 3) ("b\nc" 7) ("d" 8) (,(eof-object) 8))
    (received (lambda (on-line) (processes:line-receiver 0 on-line 0))
      (cons (bytevector 97 13 0 98 10 99 0 100) 8)
      (cons (eof-object) 8)))
  (check-equal? '(("y" 7))
    (received (lambda (on-line) (processes:line-receiver 2 on-line 0)) (cons (bytevector 120 0 121 0) 7))))

(test "a gap between two pieces is a cut: the line receiver drops the line it holds and skips to the next separator"
  (check-equal? '(("first line" 11) ("next" 5000))
    (received (lambda (on-line) (processes:line-receiver 0 on-line))
      (cons (string->utf8 "first line\nhalf of a lo") 23)
      (cons (string->utf8 "of another\nnext\n") 5000))))

(test "processes:line-receiver checks its arguments"
  (check-equal? '(processes:line-receiver "not an output offset") (violation (lambda () (processes:line-receiver -1 values))))
  (check-equal? '(processes:line-receiver "not a procedure") (violation (lambda () (processes:line-receiver 0 'on-line))))
  (check-equal? '(processes:line-receiver "not a byte") (violation (lambda () (processes:line-receiver 0 values 256)))))

(test "processes:text-receiver decodes across pieces: a character cut at a piece's end waits for the rest, each call with the offset after the bytes decoded"
  (check-equal? '(("a" 1) ("€b" 5) ("😀" 9))
    (received (lambda (on-text) (processes:text-receiver 0 on-text))
      (cons (bytevector #x61 #xE2 #x82) 3)
      (cons (bytevector #xAC #x62 #xF0 #x9F) 7)
      (cons (bytevector #x98 #x80) 9))))

(test "a text receiver turns invalid bytes into U+FFFD and decodes what it holds before the end-of-file object"
  (check-equal? `(("\xFFFD;c" 2) ("\xFFFD;" 3) (,(eof-object) 3))
    (received (lambda (on-text) (processes:text-receiver 0 on-text))
      (cons (bytevector #xFF #x63 #xE2) 3)
      (cons (eof-object) 3))))

(test "a text receiver given output after its offset, or after a gap, skips to the first byte that can start a character"
  (check-equal? '(("d" 103))
    (received (lambda (on-text) (processes:text-receiver 0 on-text)) (cons (bytevector #x82 #xAC #x64) 103)))
  (check-equal? '(("a" 1) ("bé" 10))
    (received (lambda (on-text) (processes:text-receiver 0 on-text))
      (cons (bytevector 97 #xC3) 2)
      (cons (bytevector #xA9 98 #xC3 #xA9) 10))))

(test "processes:text-receiver checks its arguments"
  (check-equal? '(processes:text-receiver "not an output offset") (violation (lambda () (processes:text-receiver -1 values))))
  (check-equal? '(processes:text-receiver "not a procedure") (violation (lambda () (processes:text-receiver 0 'on-text)))))

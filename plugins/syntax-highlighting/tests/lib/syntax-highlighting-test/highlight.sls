(library (syntax-highlighting-test highlight)
  (export make-marks-highlight make-raising-highlight make-ranged-highlight make-pieces-highlight make-misshapen-highlight)
  (import (chezscheme) (document))

  (define (separator? c) (memv c '(#\space #\newline #\( #\))))

  (define (word-end text i end)
    (if (or (fx= i end) (separator? (string-ref text i)))
        i
        (word-end text (fx+ i 1) end)))

  (define (mark-spans text mark start end)
    (let loop ([i start] [acc '()])
      (cond
        [(fx>= i end) (list->vector (reverse acc))]
        [(and (char=? (string-ref text i) mark) (or (fx= i 0) (separator? (string-ref text (fx- i 1)))))
         (let ([e (word-end text (fx+ i 1) end)])
           (loop e (cons (list i e '((face . comment))) acc)))]
        [else (loop (fx+ i 1) acc)])))

  (define (paren-spans text)
    (let loop ([i (fx- (string-length text) 1)] [acc '()])
      (cond
        [(fx< i 0) (list->vector acc)]
        [(memv (string-ref text i) '(#\( #\))) (loop (fx- i 1) (cons (list i (fx+ i 1) '((paren . #t))) acc))]
        [else (loop (fx- i 1) acc)])))

  (define (make-marks-highlight)
    (let ([calls 0])
      (lambda (doc input edits)
        (set! calls (fx+ calls 1))
        (let ([text (document:text doc)])
          (values (list (mark-spans text (string-ref (car input) 0) 0 (string-length text)) (paren-spans text))
                  (list calls edits))))))

  (define (make-raising-highlight)
    (lambda (doc input edits)
      (let ([text (document:text doc)])
        (when (memv #\! (string->list text))
          (error 'marks "the highlighter raised"))
        (values (list (mark-spans text #\# 0 (string-length text))) #f))))

  ;; Answers for the range its input names with the marks of the whole
  ;; text, so the job must cut them.
  (define (make-ranged-highlight)
    (lambda (doc input edits)
      (let ([text (document:text doc)])
        (values (list (list (car input) (cadr input) (mark-spans text #\# 0 (string-length text)))) #f))))

  (define (line-ranges text)
    (let ([n (string-length text)])
      (let loop ([i 0] [start 0] [acc '()])
        (cond
          [(fx= i n) (reverse (if (fx< start n) (cons (cons start n) acc) acc))]
          [(char=? (string-ref text i) #\newline) (loop (fx+ i 1) (fx+ i 1) (cons (cons start (fx+ i 1)) acc))]
          [else (loop (fx+ i 1) start acc)]))))

  (define (wait-for path)
    (let loop ()
      (unless (file-exists? path)
        (sleep (make-time 'time-duration 10000000 0))
        (loop))))

  ;; Each call waits for its own gate file, so a test decides when each
  ;; piece is answered.
  (define (make-pieces-highlight)
    (let ([calls 0] [next 0] [last-input #f])
      (lambda (doc input edits)
        (set! calls (fx+ calls 1))
        (wait-for (string-append (car input) "/gate-" (number->string calls)))
        (unless (and (null? edits) (equal? input last-input))
          (set! next 0)
          (set! last-input input))
        (let* ([text (document:text doc)] [lines (line-ranges text)] [piece next])
          (if (null? lines)
              (values (list '#()) (list calls piece edits))
              (let ([range (list-ref lines piece)])
                (set! next (fx+ piece 1))
                (values (list (list (car range) (cdr range) (mark-spans text #\# (car range) (cdr range))))
                        (list calls piece edits)
                        (fx< next (length lines)))))))))

  (define (make-misshapen-highlight)
    (lambda (doc input edits)
      (values (if (equal? input "not a list") 'spans (list 5)) #f))))

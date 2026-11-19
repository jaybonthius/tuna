(library (line-picker lines)
  (export last-line line-candidates)
  (import (chezscheme) (document))

  ;; The empty run after a final newline is no line to go to, though
  ;; closings may follow it.
  (define (last-line doc)
    (let* ([end (fx- (document:length doc) 1)] [last (document:line doc end)] [chars (document:unit characters)])
      (if (and (fx> last 1) (fx= (document:offset doc (document:line-start doc last) chars) (document:offset doc end chars)))
          (fx- last 1)
          last)))

  ;; A line starting in an atom's text is at the position before the
  ;; atom, so each of a run of row atoms is a line of its own.
  (define (line-candidates doc atoms first last)
    (let ([final (document:line doc (fx- (document:length doc) 1))] [end (fx- (document:length doc) 1)]
          [chars (document:unit characters)])
      (let loop ([k first] [atoms atoms] [acc '()])
        (if (fx> k last)
            (values (list->vector (reverse acc)) atoms)
            (let* ([start (document:line-start doc k)]
                   [stop (if (fx< k final) (fx- (document:line-start doc (fx+ k 1)) 1) end)]
                   [text (document:text doc start (fxmax start stop))])
              (let-values ([(here rest) (partition-before atoms stop)])
                (loop (fx+ k 1) rest
                      (if (null? here)
                          (cons (cons text start) acc)
                          (split-line doc text start (document:offset doc start chars) here (fx< k final) acc)))))))))

  (define (partition-before atoms stop)
    (let loop ([atoms atoms] [here '()])
      (if (and (pair? atoms) (fx< (caar atoms) stop))
          (loop (cdr atoms) (cons (car atoms) here))
          (values (reverse here) atoms))))

  ;; Characters between atoms hold no line break, since the line is one
  ;; of the document's.
  (define (split-line doc text start base atoms newline-after? acc)
    (let ([chars (document:unit characters)])
      (let loop ([atoms atoms] [i 0] [line '()] [at #f] [from start] [after-break? #f] [acc acc])
        (define (with-chars upto)
          (if (fx< i upto)
              (values (cons (substring text i upto) line) (or at from))
              (values line at)))
        (if (null? atoms)
            (let-values ([(line at) (with-chars (string-length text))])
              (if (and after-break? (null? line) (not newline-after?))
                  acc
                  (cons (cons (apply string-append (reverse line)) (or at from)) acc)))
            (let* ([p (caar atoms)] [atom-text (cdar atoms)]
                   [index (fx- (document:offset doc p chars) base)])
              (let-values ([(line at) (with-chars index)])
                (let split ([parts (pieces atom-text)] [line line] [at at] [acc acc] [first? #t])
                  (let* ([part (car parts)]
                         [line (if (string=? part "") line (cons part line))]
                         [at (or at (and (not (string=? part "")) p))])
                    (if (null? (cdr parts))
                        (loop (cdr atoms) (fx+ index 1) line at (if first? from (fx+ p 1)) (or after-break? (not first?)) acc)
                        (split (cdr parts) '() #f
                               (cons (cons (apply string-append (reverse line)) (or at from)) acc)
                               #f))))))))))

  (define (pieces s)
    (let loop ([i 0] [from 0] [acc '()])
      (cond
        [(fx= i (string-length s)) (reverse (cons (substring s from i) acc))]
        [(char=? (string-ref s i) #\newline) (loop (fx+ i 1) (fx+ i 1) (cons (substring s from i) acc))]
        [else (loop (fx+ i 1) from acc)]))))

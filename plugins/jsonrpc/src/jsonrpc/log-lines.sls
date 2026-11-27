(library (jsonrpc log-lines)
  (export log-line log-lines)
  (import (chezscheme))

  (define (line-end? ch) (or (char=? ch #\newline) (char=? ch #\return)))

  ;; The events log's trim counts entries as lines, so an entry's line ends
  ;; become spaces.
  (define (log-line prefix text)
    (let ([line (string-append prefix text)])
      (do ([i (string-length prefix) (fx+ i 1)])
          ((fx= i (string-length line)) line)
        (when (line-end? (string-ref line i))
          (string-set! line i #\space)))))

  (define (log-lines prefix text)
    (let loop ([start 0] [i 0] [lines '()])
      (define (with-line)
        (if (fx< start i) (cons (string-append prefix (substring text start i)) lines) lines))
      (cond
        [(fx= i (string-length text)) (reverse (with-line))]
        [(line-end? (string-ref text i)) (loop (fx+ i 1) (fx+ i 1) (with-line))]
        [else (loop start (fx+ i 1) lines)]))))

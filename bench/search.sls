#!tuna
(import (search) (buffers) (document) (jobs) (timers)
  (rename (only (chezscheme) collect-request-handler) (collect-request-handler chez:collect-request-handler)))

(define (now-ns)
  (let ([t (current-time 'time-monotonic)])
    (+ (* (time-second t) 1000000000) (time-nanosecond t))))

(define (median xs) (list-ref (list-sort < xs) (quotient (length xs) 2)))

(define (ms-per-op runs thunk)
  (median
    (map (lambda (k)
           (collect-rendezvous)
           (let ([start (now-ns)]) (thunk) (/ (- (now-ns) start) 1e6)))
         (iota runs))))

(define (show name value) (printf "~a ~,3f\n" name value))

;; A fixed generator and seed, so each run searches the same text.
(define (make-rng seed)
  (let ([s seed])
    (lambda (n)
      (set! s (fxand (fx+ (fx* (fxand s #xFFFFFFF) 1103515245) 12345) #x7FFFFFFF))
      (fxmodulo (fxsrl s 4) n))))

(define code-words '#("define" "let" "lambda" "(car x)" "foo-bar" "if" "begin" "vector-ref" "123" "\"str\""))
(define cjk-words '#("日本語" "編集" "文字列" "東京" "テキスト" "エディタ" "の" "を" "は" "、" "。" "検索" "表示" "画面" "行"))

(define (sample kind nbytes)
  (let ([rng (make-rng 7)])
    (define (word)
      (if (eq? kind 'cjk)
          (if (fx= (rng 70) 0) "😀" (vector-ref cjk-words (rng 15)))
          (vector-ref code-words (rng 10))))
    (call-with-string-output-port
      (lambda (out)
        (let loop ([written 0])
          (when (< written (- nbytes 400))
            (let* ([n (rng (if (eq? kind 'cjk) 24 12))]
                   [line (let words ([j 0] [acc '()])
                           (if (fx= j n)
                               (apply string-append (reverse (cons "\n" acc)))
                               (words (fx+ j 1) (if (or (eq? kind 'cjk) (null? acc)) (cons (word) acc) (cons (word) (cons " " acc))))))])
              (put-string out line)
              (loop (+ written (bytevector-length (string->utf8 line)))))))))))

;; Every thread stops for a full collection, since collect alone refuses
;; while other threads run.
(define (collect-fully)
  (parameterize ([chez:collect-request-handler (lambda () (collect (collect-maximum-generation)))])
    (collect-rendezvous)))

(define %made 0)
(define (buffer-of text)
  (set! %made (+ %made 1))
  (let ([b (buffers:make (format "search-bench-~a" %made) text)])
    (collect-fully)
    b))

(define (end-of b) (document:length (buffers:document b)))

(define (rx text) (search:make-query text search:regexp))

(define forward (search:direction forward))
(define backward (search:direction backward))

(define (scan-ms b q filter?)
  (ms-per-op 3
    (lambda ()
      (let* ([done #f]
             [q (if filter? (search:query-with-filter q (lambda (b s e) #t)) q)]
             [s (search:scan b q 0 (end-of b) 0 (lambda (s) (when (search:scan-done? s) (set! done #t))))])
        (let wait () (unless done (timers:sleep 0.001) (wait)))))))

(define word-class "[\\p{Alphabetic}\\x{24}\\x{25}\\p{N}]")

(define (run)
  (let* ([code-1 (buffer-of (sample 'code 1000000))]
         [code-100 (buffer-of (sample 'code 100000000))]
         [cjk-1 (buffer-of (sample 'cjk 1000000))])
    (for-each
      (lambda (name b)
        (show (format "step-failing-literal-~a" name) (ms-per-op 5 (lambda () (search:find b (search:make-query "zebra-quux") 0 forward))))
        (show (format "step-failing-bref-~a" name) (ms-per-op 5 (lambda () (search:find b (rx "\\Bref") 0 forward))))
        (show (format "step-near-~a" name) (ms-per-op 5 (lambda () (search:find b (search:make-query "lambda") 0 forward))))
        (show (format "step-backward-failing-~a" name) (ms-per-op 3 (lambda () (search:find b (search:make-query "zebra-quux") (end-of b) backward))))
        (show (format "step-backward-near-~a" name) (ms-per-op 5 (lambda () (search:find b (search:make-query "lambda") (end-of b) backward))))
        (show (format "scan-vector-ref-~a" name) (scan-ms b (search:make-query "vector-ref") #f))
        (show (format "scan-busy-~a" name) (scan-ms b (rx "[a-z]+-[a-z]+") #f))
        (show (format "scan-busy-filtered-~a" name) (scan-ms b (rx "[a-z]+-[a-z]+") #t)))
      '("1mb" "100mb") (list code-1 code-100))
    (show "step-failing-words-japanese-1mb" (ms-per-op 5 (lambda () (search:find cjk-1 (rx "\\b\\w+-\\w+\\b") 0 forward))))
    (show "step-failing-words-conditional-japanese-1mb"
          (let ([b (string-append "(?(?<=" word-class ")(?!" word-class ")|(?=" word-class "))")])
            (ms-per-op 5 (lambda () (search:find cjk-1 (rx (string-append b "[\\p{Alphabetic}\\p{N}]+-[\\p{Alphabetic}\\p{N}]+" b)) 0 forward)))))
    (show "step-pathological" (ms-per-op 3 (lambda () (guard (c [(search:pattern-error? c) #f])
                                                        (search:find (buffer-of (string-append (make-string 40 #\a) "b")) (rx "^(a+)+$") 0 forward)))))
    (let ([rows (buffer-of (cons* 'search-bench-rows '() (map (lambda (k) (vector 'search-bench-row (list (cons 'n k)))) (iota 15000))))])
      (show "step-failing-15000-atoms" (ms-per-op 5 (lambda () (search:find rows (search:make-query "zebra") 0 forward))))
      (show "scan-15000-atoms" (scan-ms rows (search:make-query "row 1") #f)))))

(define (row-text node) (string-append "row " (number->string (document:node-attribute node 'n)) "\n"))
(buffers:define-kind search-bench-rows (content nodes))
(buffers:define-kind search-bench-row (content atom) (text row-text))

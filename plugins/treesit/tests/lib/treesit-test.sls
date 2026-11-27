#!tuna
(import (test-runner) (buffers) (document) (modes) (jobs) (syntax-highlighting))

(define (home-file name) (string-append (getenv "HOME") "/" name))

(define (write-file! path text)
  (let loop ([d (path-parent path)])
    (unless (or (string=? d "") (file-directory? d))
      (loop (path-parent d))
      (mkdir d)))
  (call-with-output-file path (lambda (p) (put-string p text)) 'replace))

(define (copy-file! from to)
  (write-file! to "")
  (let ([bytes (call-with-port (open-file-input-port from) get-bytevector-all)])
    (call-with-port (open-file-output-port to (file-options no-fail))
      (lambda (p) (put-bytevector p bytes)))))

(define (%install) (path-parent (car (command-line))))

;; Data files sit beside the test modules, and a test reaches its
;; plugin's files in the install's copy.
(define (%data name) (string-append (%install) "/plugins/treesit/tests/lib/treesit-test/" name))

(define (%read path) (call-with-input-file path get-string-all))

(define (sample name) (%read (%data (string-append "python/" name ".py"))))

(define (emacs-categories name level) (%read (%data (format "emacs/~a.~a" name level))))

(define (grown-text size)
  (let ([text (sample "sample")])
    (call-with-string-output-port
      (lambda (p)
        (let loop ([n 0])
          (when (< n size)
            (put-string p text)
            (loop (+ n (string-length text)))))))))

(define (buffer name text mode)
  (let ([b (buffers:make (buffers:free-name name) text)])
    (modes:set-major-mode mode b)
    b))

(define (text-of b) (document:text (buffers:document b)))

(define (spans b)
  (buffers:spans (buffers:layer b syntax-highlighting:faces) 0 (document:length (buffers:document b))))

(define (%face span) (cdr (assq 'face (caddr span))))

;; Pieces can split one face's run in two spans, so colours are read as
;; runs: the touching spans of one face joined, each with its text.
(define runs
  (case-lambda
    [(b) (runs b 0 (document:length (buffers:document b)))]
    [(b from to)
     (let ([doc (buffers:document b)])
       (let loop ([spans (spans b)] [acc '()])
         (if (null? spans)
             (map (lambda (r) (list (document:text doc (car r) (cadr r)) (caddr r))) (reverse acc))
             (let* ([s (car spans)] [start (max from (car s))] [end (min to (cadr s))] [face (%face s)])
               (cond
                 [(>= start end) (loop (cdr spans) acc)]
                 [(and (pair? acc) (= (cadar acc) start) (equal? (caddar acc) face))
                  (loop (cdr spans) (cons (list (caar acc) end face) (cdr acc)))]
                 [else (loop (cdr spans) (cons (list start end face) acc))])))))]))

;; Highlighting runs in a job, so a check waits until the colours are the
;; ones it expects, and names the colours there when they never are.
(define (runs-become b expected)
  (guard (c [(and (who-condition? c) (eq? (condition-who c) 'test-runner:wait-until))
             (errorf 'treesit-test:runs-become "~s has ~s, not ~s" (buffers:name b) (runs b) expected)])
    (test-runner:wait-until (lambda () (equal? expected (runs b))))))

(define (line-start b line) (document:line-start (buffers:document b) line))

(define (line-of b position) (document:line (buffers:document b) position))

(define (lines-of b range) (list (line-of b (car range)) (line-of b (- (cdr range) 1))))

(define %events '())

;; No public name tells a job's worker, so treesit's jobs are told by the
;; name their worker writes.
(define (%note! event job)
  (when (string=? (format "~a" job) "#<job %highlighter>")
    (set! %events (cons event %events))))

(define (job-events)
  (let ([found (reverse %events)])
    (set! %events '())
    found))

(define %sets '())

(define (%note-set! set layer start end spans . version)
  (let ([result (apply set layer start end spans version)])
    (set! %sets (cons (list layer start end) %sets))
    result))

(define (sets b)
  (let* ([layer (buffers:layer b syntax-highlighting:faces)]
         [found (filter (lambda (s) (eq? (car s) layer)) (reverse %sets))])
    (set! %sets (remp (lambda (s) (eq? (car s) layer)) %sets))
    (map cdr found)))

(advice-add! jobs:start (lambda (start . arguments) (let ([job (apply start arguments)]) (%note! 'start job) job)))
(advice-add! jobs:stop! (lambda (stop job) (%note! 'stop job) (stop job)))
(advice-add! buffers:set-spans! %note-set!)

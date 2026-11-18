(import (tuna) (tuna plugins) (document) (haml))
(use-plugin modes)
(use-plugin views)
(use-plugin chez-scheme)
(use-plugin rainbow-delimiters)
(add-hook! chez-scheme:mode-hook
  (lambda () (set-option-local! rainbow-delimiters:mode #t)))

(define (scheme-buffer name content)
  (let ([b (buffers:make name content)])
    (modes:set-major-mode chez-scheme:mode b)
    b))

;; Highlighting runs in a job, so a test waits until the bracket spans
;; have not changed for a while.
(define (brackets b)
  (let loop ([n 0] [same 0] [last #f])
    (let ([now (buffers:spans (buffers:layer b syntax:brackets) 0 (document:length (buffers:document b)))])
      (if (or (= same 15) (= n 500))
          now
          (begin
            (sleep-for 0.02)
            (loop (+ n 1) (if (equal? now last) (+ same 1) 0) now))))))

(define (search s sub from)
  (let ([n (string-length sub)] [m (string-length s)])
    (let loop ([i from])
      (cond
        [(> (+ i n) m) #f]
        [(string=? (substring s i (+ i n)) sub) i]
        [else (loop (+ i 1))]))))

(define (lines view)
  (brackets (views:buffer view))
  (let ([html (html->string (views:draw view #f))])
    (substring html (+ (search html "<div class=\"view-lines\">" 0) 24) (- (string-length html) 12))))

(define (bracket-faces view)
  (let ([html (lines view)] [mark "data-face=\"rainbow-delimiters."])
    (let loop ([from 0] [acc '()])
      (let ([i (search html mark from)])
        (if i
            (let* ([start (+ i (string-length mark))] [end (search html "\"" start)])
              (loop end (cons (string->symbol (substring html start end)) acc)))
            (reverse acc))))))
(import (console))

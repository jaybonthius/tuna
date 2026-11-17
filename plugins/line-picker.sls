#!tuna
(import (completion) (buffers) (commands) (document) (jobs) (keys) (views))

(define (%line-candidates doc first last)
  (let ([n (fx+ (fx- last first) 1)])
    (let ([v (make-vector n)] [end (document:length doc)])
      (do ([k first (fx+ k 1)]) ((fx> k last) v)
        (let* ([start (document:line-start doc k)]
               [stop (if (fx< k (document:line doc (fx- end 1))) (fx- (document:line-start doc (fx+ k 1)) 1) (fx- end 1))])
          (vector-set! v (fx- k first) (cons (document:text doc start (fxmax start stop)) start)))))))

(jobs:define-worker (%split-lines doc emit receive)
  (import (document))
  (let* ([end (fx- (document:length doc) 1)] [final (document:line doc end)]
         [last (if (and (fx> final 1) (fx= (document:line-start doc final) end)) (fx- final 1) final)])
    (let loop ([k 1])
      (when (fx<= k last)
        (let ([to (fxmin last (fx+ k 999))])
          (emit (let ([v (make-vector (fx+ (fx- to k) 1))])
                  (do ([j k (fx+ j 1)]) ((fx> j to) v)
                    (let* ([start (document:line-start doc j)]
                           [stop (if (fx< j final) (fx- (document:line-start doc (fx+ j 1)) 1) end)])
                      (vector-set! v (fx- j k) (cons (document:text doc start (fxmax start stop)) start))))))
          (loop (fx+ to 1)))))))

;; The empty run after a final newline is no line to go to.
(define (%last-line doc)
  (let* ([end (fx- (document:length doc) 1)] [last (document:line doc end)])
    (if (and (fx> last 1) (fx= (document:line-start doc last) end)) (fx- last 1) last)))

;; Matches the main thread's limit, so a buffer that completion would match
;; there is split there too.
(define (%small? doc)
  (and (fx<= (document:length doc) 50000) (fx<= (document:line doc (fx- (document:length doc) 1)) 1000)))

(define (%read-line)
  (let* ([view (views:current)] [doc (buffers:document (views:buffer view))] [point (views:point view)])
    (completion:read "Go to line: "
      (list (if (%small? doc)
                (completion:source
                  (candidates (%line-candidates doc 1 (%last-line doc)))
                  (in-order)
                  (preview (lambda (p) (views:set-point! view (or p point)))))
                (completion:source
                  (job %split-lines doc)
                  (in-order)
                  (preview (lambda (p) (views:set-point! view (or p point))))))))))

(commands:define-command (line [position (%read-line)])
  "Moves point to POSITION, the start of a line read from the current buffer."
  (views:set-point! (views:current) position))

(keys:bind! keys:global "M-s l" line)

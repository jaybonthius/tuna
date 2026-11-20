#!tuna
(import (document) (buffers) (views) (commands) (keys) (undo) (editing) (layout) (web))

(define (now-ns)
  (let ([t (current-time 'time-monotonic)])
    (+ (* (time-second t) 1000000000) (time-nanosecond t))))

(define (median xs)
  (list-ref (list-sort < xs) (quotient (length xs) 2)))

(define batch 2000)

(define (ns-per-op thunk)
  (median
    (map (lambda (k)
           (collect-rendezvous)
           (let ([start (now-ns)])
             (do ([i 0 (fx+ i 1)]) ((fx= i batch)) (thunk))
             (/ (- (now-ns) start) (exact->inexact batch))))
         (iota 9))))

;; Samples of the two alternate, each going first in turn, so that a
;; slower second run on one buffer is charged to both.
(define (ns-per-op-pair a b)
  (let loop ([k 0] [as '()] [bs '()])
    (if (fx= k 10)
        (values (median as) (median bs))
        (let* ([x (ns-per-op-once (if (fxeven? k) a b))] [y (ns-per-op-once (if (fxeven? k) b a))])
          (if (fxeven? k)
              (loop (fx+ k 1) (cons x as) (cons y bs))
              (loop (fx+ k 1) (cons y as) (cons x bs)))))))

(define (ns-per-op-once thunk)
  (collect-rendezvous)
  (let ([start (now-ns)])
    (do ([i 0 (fx+ i 1)]) ((fx= i batch)) (thunk))
    (/ (- (now-ns) start) (exact->inexact batch))))

(define (show name value)
  (printf "~a ~,2f\n" name value))

(define client (web:add-client! 1))

(define line (string-append (make-string 60 #\x) "\n"))

(define mixed
  "The quick brown fox, née Müller, jumps over 13 lazy dogs; café-au-lait $5% (x+y)*z. ")

(define made 0)

(define (view-of content . points)
  (set! made (fx+ made 1))
  (let* ([b (buffers:make (format "bench-~a" made) content)] [v (views:make b)])
    (views:set-point! v (car points))
    (for-each (lambda (p) (views:add-cursor! v p)) (cdr points))
    v))

;; The same insertion as self-insert's, with nothing else, so the
;; difference is what editing adds.
(commands:define-command (plain-insert)
  "Inserts the character typed at point."
  (let* ([v (views:current)] [p (views:point v)])
    (buffers:replace! (views:buffer v) p p (string (keys:typed-char)))
    (views:set-point! v (fx+ p 1))))

;; Code that edits outside commands makes one undo group per batch, and
;; this benchmark is one batch, so the buffers it edits that way keep no
;; history.
(define (without-history v)
  (buffers:with-buffer (views:buffer v) (set-option-local! undo:limit 0))
  v)

(define (typing-cost v command)
  (keys:bind! keys:global "<printing-char>" command)
  (views:with-view v (ns-per-op (lambda () (keys:press! client "a")))))

(define (run)
  (let ([one (view-of (string-append line line) 1)]
        [four (view-of (apply string-append (make-list 4 line)) 1 62 123 184)])
    (let* ([plain (typing-cost one plain-insert)]
           [typed (typing-cost one editing:self-insert)]
           [typed-four (typing-cost four editing:self-insert)])
      (show "self-insert-overhead" (- typed plain))
      (show "self-insert-further-cursor" (/ (- typed-four typed) 3))))
  (keys:bind! keys:global "<printing-char>" editing:self-insert)
  (let ([v (without-history (view-of (string-append line line line) 30))])
    (views:with-view v
      (show "forward-char" (/ (ns-per-op (lambda () (editing:forward-char 1) (editing:backward-char 1))) 2))
      (show "next-line" (/ (ns-per-op (lambda () (editing:next-line 1) (editing:previous-line 1))) 2))))
  (let ([v (without-history (view-of (string-append mixed mixed mixed "\n") 1))])
    (views:with-view v
      (show "forward-word" (/ (ns-per-op (lambda () (editing:forward-word 10) (editing:backward-word 10))) 20))))
  (let* ([v (without-history (view-of (apply string-append (make-list 100 line)) 62))] [b (views:buffer v)])
    (views:with-view v
      (let-values ([(killed restored)
                    (ns-per-op-pair
                      (lambda ()
                        (views:set-cursor! (car (views:cursors v)) 62 123)
                        (editing:kill-region)
                        (buffers:replace! b 62 62 line))
                      (lambda ()
                        (buffers:replace! b 62 123 "")
                        (buffers:replace! b 62 62 line)))])
        ;; Half the plain pair stands for the re-insertion each sample
        ;; also makes, so what is left is the kill with its deletion.
        (show "kill-region-line" (- killed (/ restored 2))))))
  (let ([v (without-history (view-of "Sixteen-letters word and more\n" 1))])
    (views:with-view v
      (show "upcase-word"
        (/ (ns-per-op (lambda ()
                        (views:set-point! v 1) (editing:upcase-word 1)
                        (views:set-point! v 1) (editing:downcase-word 1)))
           2))))
  (let ([v (without-history (view-of "alpha beta\n" 6))])
    (views:with-view v
      (show "transpose-words"
        (ns-per-op (lambda () (views:set-point! v 6) (editing:transpose-words))))))
  (bench-blocks))

;; Two thousand paragraphs against two thousand lines of one text: the
;; content's ends are stops, and word motion reads the nodes it passes.
(buffers:define-kind page (content nodes))
(buffers:define-kind paragraph)

;; The running program always has isolating kinds, as table cells, so a
;; region's fitting looks for isolating nodes as it does there.
(buffers:define-kind cell (isolating))

(define paragraph-text "Buy milk and café, then λx words.\n")

(define (paragraphs-content count) (apply page '() (map (lambda (i) (paragraph '() paragraph-text)) (iota count))))

(define (lines-content count) (apply string-append (make-list count paragraph-text)))

(define (paragraph-text-start k) (+ 2 (* k (+ (string-length paragraph-text) 2))))

(define (line-start k) (+ 1 (* k (string-length paragraph-text))))

;; A few runs each, for a command that moves a thousand lines.
(define (ms-per-run thunk)
  (median
    (map (lambda (k)
           (collect-rendezvous)
           (let ([start (now-ns)])
             (thunk)
             (/ (- (now-ns) start) 1e6)))
         (iota 5))))

(define (bench-blocks)
  (let ([blocks (without-history (view-of (paragraphs-content 2000) (paragraph-text-start 1000)))]
        [lines (without-history (view-of (lines-content 2000) (line-start 1000)))])
    (for-each
      (lambda (v suffix)
        (views:with-view v
          (show (string-append "forward-char-" suffix)
            (/ (ns-per-op (lambda () (editing:forward-char 1) (editing:backward-char 1))) 2))
          (show (string-append "forward-word-" suffix)
            (/ (ns-per-op (lambda () (editing:forward-word 1) (editing:backward-word 1))) 2))))
      (list blocks lines) '("blocks" "text")))
  ;; An active region over the whole buffer: after each command the
  ;; selected view's region becomes the primary selection.
  (for-each
    (lambda (content suffix)
      (let ([v (layout:selected-view)] [b (buffers:make (format "bench-~a" (begin (set! made (fx+ made 1)) made)) content)])
        (views:set-buffer! v b)
        (buffers:with-buffer b (set-option-local! undo:limit 0))
        (views:set-point! v (paragraph-text-start 1000))
        (views:set-mark! v 1)
        (views:with-view v
          (show (string-append "region-motion-" suffix)
            (/ (ns-per-op (lambda () (keys:press! client "C-f") (keys:press! client "C-b"))) 2)))))
    (list (paragraphs-content 2000) (lines-content 2000)) '("blocks" "text"))
  (for-each
    (lambda (content start end suffix)
      (let ([v (without-history (view-of content start))])
        (views:set-mark! v end)
        (views:with-view v
          (show (string-append "move-lines-" suffix)
            (/ (ms-per-run (lambda () (editing:move-line-down 1) (editing:move-line-up 1))) 2)))))
    (list (paragraphs-content 1001) (lines-content 1001))
    (list (paragraph-text-start 0) (line-start 0))
    (list (paragraph-text-start 1000) (line-start 1000))
    '("blocks" "text")))

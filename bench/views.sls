#!tuna
(import (document) (buffers) (views) (web) (haml))

(define (now-ns)
  (let ([t (current-time 'time-monotonic)])
    (+ (* (time-second t) 1000000000) (time-nanosecond t))))

(define (median xs)
  (list-ref (list-sort < xs) (quotient (length xs) 2)))

(define (ns-per-op count run)
  (median
    (map (lambda (k)
           (collect-rendezvous)
           (let ([start (now-ns)])
             (do ([i 0 (fx+ i 1)]) ((fx= i count)) (run i))
             (/ (- (now-ns) start) (exact->inexact count))))
         (iota 9))))

(define (show name value)
  (printf "~a ~,2f\n" name value))

(buffers:define-layer syntax (priority 10))
(buffers:define-layer diagnostics (priority 50))

(define (draw-paragraph node view) (haml (:div.p (views:draw-children view node))))

(buffers:define-kind code (content nodes))
(buffers:define-kind paragraph (draw draw-paragraph))

;; Lines like source code, about 45 characters in 4 highlighted tokens,
;; or 100 characters in 10 for the heavy case.
(define (code-line k heavy?)
  (if heavy?
      (format "  (define (handler-~a request) (let ([body (read-body request)]) (respond ~a body)))\n" (mod k 997) k)
      (format "  (define (name-~a x) (+ x ~a)) ; note\n" (mod k 997) (mod k 89))))

(define (spans-of-line start line heavy?)
  (let loop ([i 0] [acc '()] [n 0])
    (cond
      [(or (= n (if heavy? 10 4)) (>= (+ i 6) (string-length line))) (reverse acc)]
      [(char=? (string-ref line i) #\space) (loop (+ i 1) acc n)]
      [else
       (let ([end (let scan ([j i]) (if (or (= j (string-length line)) (char=? (string-ref line j) #\space)) j (scan (+ j 1))))])
         (loop end (cons (list (+ start i) (+ start end) (if (even? n) '((face . keyword)) '((face . name)))) acc) (+ n 1)))])))

(define made 0)

(define (file-buffer lines heavy?)
  (set! made (+ made 1))
  (let* ([texts (map (lambda (k) (code-line k heavy?)) (iota lines))]
         [b (buffers:make (format "bench-~a" made) (apply string-append texts))])
    (let loop ([texts texts] [at 1] [spans '()])
      (if (null? texts)
          (buffers:set-spans! (buffers:layer b syntax) 0 (document:length (buffers:document b)) (reverse spans))
          (loop (cdr texts) (+ at (string-length (car texts)))
                (append (reverse (spans-of-line at (car texts) heavy?)) spans))))
    (collect (collect-maximum-generation))
    b))

(define (node-buffer lines)
  (set! made (+ made 1))
  (let ([b (buffers:make (format "bench-~a" made)
             (apply code '() (map (lambda (k) (paragraph '() (code-line k #f))) (iota lines))))])
    (collect (collect-maximum-generation))
    b))

(define (lines-drawn html)
  (let loop ([i 0] [acc '()])
    (let ([j (let search ([k i])
               (cond [(> (+ k 11) (string-length html)) #f]
                     [(string=? (substring html k (+ k 11)) "data-line=\"") k]
                     [else (search (+ k 1))]))])
      (if j
          (let digits ([k (+ j 11)] [n 0])
            (if (char-numeric? (string-ref html k))
                (digits (+ k 1) (+ (* n 10) (- (char->integer (string-ref html k)) 48)))
                (loop k (cons n acc))))
          (reverse acc)))))

(define (number-after html name)
  (let ([n (string-length name)])
    (let search ([k 0])
      (if (string=? (substring html k (+ k n)) name)
          (let digits ([k (+ k n)] [v 0])
            (if (char-numeric? (string-ref html k))
                (digits (+ k 1) (+ (* v 10) (- (char->integer (string-ref html k)) 48)))
                v))
          (search (+ k 1))))))

(define (report-of v client top)
  (let* ([html (html->string (views:draw v client))] [ls (lines-drawn html)]
         [first (car ls)] [last (car (reverse ls))])
    `(("type" . "scroll") ("view" . ,(views:id v)) ("placement" . ,(number-after html "data-placement=\""))
      ("report" . 1) ("top" . ,top) ("offset" . 0) ("lastVisible" . ,(+ top 44)) ("spacer" . null)
      ("spacerDistance" . 0) ("before" . ,(- top first)) ("after" . ,(- last top))
      ("drawnHeight" . ,(* 22 (+ 1 (- last first)))) ("above" . ,(* 22 (- top first)))
      ("below" . ,(max 0 (- (* 22 (+ 1 (- last top))) 990))) ("width" . 800) ("height" . 990) ("settled" . #f))))

(define (report! v client top) ((table-ref web:input-handlers "scroll") client (report-of v client top)))

(define (scrolled-view b)
  (let* ([v (views:make b)] [doc (buffers:document b)]
         [lines (document:line doc (document:length doc))]
         [top (quotient lines 2)]
         [p (document:line-start doc (+ top 20))])
    (views:scroll-to! v (document:line-start doc top) (views:align top))
    (report! v #f top)
    (report! v #f top)
    (views:set-point! v (+ p 4))
    (views:set-mark! v (document:line-start doc (+ top 18)))
    (buffers:add-span! (buffers:layer b diagnostics) (+ p 2) (+ p 9) '((face . warning) (title . "unused")))
    (views:draw v #f)
    v))

(define (region-view b)
  (let* ([v (scrolled-view b)] [doc (buffers:document b)])
    (views:set-mark! v (document:line-start doc (- (document:line doc (views:point v)) 120)))
    (views:draw v #f)
    v))

(define (report-cost v)
  (let* ([doc (buffers:document (views:buffer v))] [top (document:line doc (views:top v))]
         [items (vector (report-of v #f top) (report-of v #f (+ top 1)))]
         [handle (table-ref web:input-handlers "scroll")])
    (ns-per-op 200 (lambda (i) (handle #f (vector-ref items (mod i 2)))))))

(define (draw-cost v)
  (ns-per-op 200 (lambda (i) (html->string (views:draw v #f)))))

(define (two-clients-cost v)
  (let ([desktop (web:make-client 1)] [phone (web:make-client 2)]
        [top (document:line (buffers:document (views:buffer v)) (views:top v))])
    (for-each (lambda (c) (report! v c top) (report! v c top)) (list desktop phone))
    (ns-per-op 200 (lambda (i) (html->string (views:draw v desktop)) (html->string (views:draw v phone))))))

(define (drawn-lines v) (length (lines-drawn (html->string (views:draw v #f)))))

;; Views drawn from atoms are saved after each batch that changed one;
;; the batch here moves one cursor among ten such views.
(define (save-cost b)
  (let* ([holder (buffers:make "holder"
                   (apply code '() (map (lambda (k) (views:view `((view . ,(+ 1000 k)) (buffer . ,(buffers:name b))))) (iota 10))))]
         [doc (buffers:document holder)]
         [views (map (lambda (k) (views:atom-view (document:token doc (+ k 1)))) (iota 10))]
         [v (car views)])
    (batch-ended)
    (ns-per-op 200
      (lambda (i)
        (views:set-point! v (+ 1 (* 7 (mod i 50))))
        (batch-ended)))))

;; Every edit tells each view of its buffer: what ten views add to an
;; edit.
(define (edit-cost plain viewed)
  (for-each (lambda (k) (views:make viewed)) (iota 10))
  (let ([typing (lambda (b) (ns-per-op 2000 (lambda (i) (buffers:replace! b 2 2 "x"))))])
    (- (typing viewed) (typing plain))))

;; An edit tells only its buffer's views: what a thousand views of other
;; buffers add to an edit.
(define (other-views-cost before after others)
  (let ([typing (lambda (b) (ns-per-op 2000 (lambda (i) (buffers:replace! b 2 2 "x"))))])
    (let ([alone (typing before)])
      (for-each (lambda (k) (views:make (list-ref others (mod k (length others))))) (iota 1000))
      (- (typing after) alone))))

(define (stop-cost v)
  (let* ([b (views:buffer v)] [p (views:point v)])
    (views:fold! v (+ p 40) (+ p 400))
    (ns-per-op 2000 (lambda (i) (views:next-stop v (+ p (mod i 200)))))))

(define (run)
  (let ([typical (scrolled-view (file-buffer 22000 #f))]
        [heavy (scrolled-view (file-buffer 10000 #t))]
        [nodes (scrolled-view (node-buffer 22000))]
        [region (region-view (file-buffer 22000 #f))])
    (printf "drawn lines: ~a typical, ~a heavy, ~a nodes\n" (drawn-lines typical) (drawn-lines heavy) (drawn-lines nodes))
    (show "build-only-typical" (ns-per-op 200 (lambda (i) (views:draw typical #f))))
    (let ([h (views:draw typical #f)]) (show "write-only-typical" (ns-per-op 200 (lambda (i) (html->string h)))))
    (show "draw-typical" (draw-cost typical))
    (show "draw-heavy" (draw-cost heavy))
    (show "draw-region" (draw-cost region))
    (show "draw-two-clients" (two-clients-cost typical))
    (show "build-only-nodes" (ns-per-op 200 (lambda (i) (views:draw nodes #f))))
    (show "draw-nodes" (draw-cost nodes))
    (show "report" (report-cost typical))
    (show "save" (save-cost (views:buffer typical)))
    (show "edit-ten-views" (edit-cost (file-buffer 1000 #f) (file-buffer 1000 #f)))
    (show "edit-other-views" (other-views-cost (file-buffer 1000 #f) (file-buffer 1000 #f)
                                               (map (lambda (k) (file-buffer 10 #f)) (iota 10))))
    (show "next-stop" (stop-cost typical))))

#!tuna
(import (document) (buffers) (views) (web) (haml) (scroll-report))

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

(define (draw-reply node view) (haml (:div.reply (views:draw-children view node))))
(define (draw-emphasis node view) (haml (:em (views:draw-children view node))))

(buffers:define-kind code (content nodes))
(buffers:define-kind paragraph (draw draw-paragraph))
(buffers:define-kind reply (content nodes) (draw draw-reply))
(buffers:define-kind emphasis (inline) (draw draw-emphasis))

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
    (collect-rendezvous)
    b))

(define (node-buffer lines)
  (set! made (+ made 1))
  (let ([b (buffers:make (format "bench-~a" made)
             (apply code '() (map (lambda (k) (paragraph '() (code-line k #f))) (iota lines))))])
    (collect-rendezvous)
    b))

(define (plain-buffer lines)
  (set! made (+ made 1))
  (let ([b (buffers:make (format "bench-~a" made) (apply string-append (map (lambda (k) (code-line k #f)) (iota lines))))])
    (collect-rendezvous)
    b))

;; Replies of a chat: paragraphs whose lines hold emphasis, as a model's
;; replies hold code spans and links.
(define (chat-buffer replies)
  (set! made (+ made 1))
  (let ([b (buffers:make (format "bench-~a" made)
             (apply code '()
               (map (lambda (k)
                      (reply '()
                        (paragraph '() (format "Reply ~a explains " k) (emphasis '() "this") " and " (emphasis '() "that") " at length.\n")
                        (paragraph '() "A second paragraph, longer, that a narrow view wraps onto a few rows of its own.\n")
                        (paragraph '() (code-line k #f))))
                    (iota replies))))])
    (collect-rendezvous)
    b))

(define desk (web:make-client 1))

(define (report-of v client top) (scroll-report:make v client top 990 #f))

(define (report! v client top) ((table-ref web:input-handlers "scroll") client (report-of v client top)))

(define (scrolled-view b)
  (let* ([v (views:make b)] [doc (buffers:document b)]
         [lines (document:line doc (document:length doc))]
         [top (quotient lines 2)]
         [p (document:line-start doc (+ top 20))])
    (views:scroll-to! v (document:line-start doc top) (views:align top))
    (report! v desk top)
    (report! v desk top)
    (views:set-point! v (+ p 4))
    (views:set-mark! v (document:line-start doc (+ top 18)))
    (buffers:add-span! (buffers:layer b diagnostics) (+ p 2) (+ p 9) '((face . warning) (title . "unused")))
    (views:draw v desk)
    (report! v desk top)
    v))

(define (region-view b)
  (let* ([v (scrolled-view b)] [doc (buffers:document b)])
    (views:set-mark! v (document:line-start doc (- (document:line doc (views:point v)) 120)))
    (views:draw v desk)
    v))

(define (report-cost v)
  (let* ([doc (buffers:document (views:buffer v))] [top (document:line doc (views:top v desk))]
         [items (vector (report-of v desk top) (report-of v desk (+ top 1)))]
         [handle (table-ref web:input-handlers "scroll")])
    (ns-per-op 200 (lambda (i) (handle desk (vector-ref items (mod i 2)))))))

(define (draw-cost v)
  (ns-per-op (if (fx> (document:length (buffers:document (views:buffer v))) 900000) 20 200) (lambda (i) (html->string (views:draw v desk)))))

(define (two-clients-cost v)
  (let ([desktop (web:make-client 3)] [phone (web:make-client 4)]
        [top (document:line (buffers:document (views:buffer v)) (views:top v desk))])
    (for-each (lambda (c) (report! v c top) (report! v c top)) (list desktop phone))
    (ns-per-op 200 (lambda (i) (html->string (views:draw v desktop)) (html->string (views:draw v phone))))))

(define (drawn-lines v) (length (scroll-report:lines-drawn (html->string (views:draw v desk)))))

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

;; The same batch with fifty buffers in each view's history, which
;; views saves apart from the views, at idle.
(define (save-with-histories-cost b)
  (let* ([kept (map (lambda (k) (buffers:make (format "kept-~a" k) "kept\n")) (iota 50))]
         [holder (buffers:make "holder-2"
                   (apply code '() (map (lambda (k) (views:view `((view . ,(+ 2000 k)) (buffer . ,(buffers:name b))))) (iota 10))))]
         [doc (buffers:document holder)]
         [views (map (lambda (k) (views:atom-view (document:token doc (+ k 1)))) (iota 10))]
         [v (car views)])
    (for-each (lambda (w) (for-each (lambda (o) (views:set-buffer! w o)) kept) (views:set-buffer! w b)) views)
    (batch-ended)
    (ns-per-op 200
      (lambda (i)
        (views:set-point! v (+ 1 (* 7 (mod i 50))))
        (batch-ended)))))

;; Showing another buffer keeps the one left, with the view's state in it.
(define (switch-cost a b)
  (let ([v (views:make a)])
    (ns-per-op 2000 (lambda (i) (views:set-buffer! v (if (even? i) b a))))))

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

(define (one-line-view)
  (set! made (+ made 1))
  (let* ([b (buffers:make (format "bench-~a" made) (string-append (make-string 1000000 #\a) "\n"))]
         [v (views:make b)])
    (views:set-option! v views:wrap-lines #f)
    (views:set-point! v 500001)
    (report! v desk 1)
    (collect-rendezvous)
    v))

(define matches (list->vector (map (lambda (k) (+ 1 (* 8 k))) (iota 125000))))

(define (first-at-or-after p)
  (let search ([a 0] [z (vector-length matches)])
    (if (fx< a z)
        (let ([m (fxquotient (fx+ a z) 2)])
          (if (fx< (vector-ref matches m) p) (search (fx+ m 1) z) (search a m)))
        a)))

(define (match-source v)
  (lambda (view client start end)
    (if (eq? view v)
        (let loop ([i (first-at-or-after (fxmax 1 (fx- start 4)))] [acc '()])
          (if (or (fx= i (vector-length matches)) (fx>= (vector-ref matches i) end))
              (reverse acc)
              (loop (fx+ i 1) (cons (list (vector-ref matches i) (fx+ (vector-ref matches i) 4) '((face . match.other))) acc))))
        '())))

(define (run)
  (let ([line (one-line-view)])
    (show "draw-one-line" (draw-cost line))
    (let ([source (match-source line)])
      (table-set! views:span-sources source 1000)
      (show "draw-one-line-source" (draw-cost line))
      (table-remove! views:span-sources source)))
  (let ([typical (scrolled-view (file-buffer 22000 #f))]
        [heavy (scrolled-view (file-buffer 10000 #t))]
        [nodes (scrolled-view (node-buffer 22000))]
        [region (region-view (file-buffer 22000 #f))])
    (printf "drawn lines: ~a typical, ~a heavy, ~a nodes\n" (drawn-lines typical) (drawn-lines heavy) (drawn-lines nodes))
    (show "build-only-typical" (ns-per-op 200 (lambda (i) (views:draw typical desk))))
    (let ([h (views:draw typical desk)]) (show "write-only-typical" (ns-per-op 200 (lambda (i) (html->string h)))))
    (show "draw-typical" (draw-cost typical))
    (show "draw-heavy" (draw-cost heavy))
    (show "draw-region" (draw-cost region))
    (show "draw-two-clients" (two-clients-cost typical))
    (show "build-only-nodes" (ns-per-op 200 (lambda (i) (views:draw nodes desk))))
    (show "draw-nodes" (draw-cost nodes))
    (show "report" (report-cost typical))
    (show "save" (save-cost (views:buffer typical)))
    (show "save-with-histories" (save-with-histories-cost (views:buffer typical)))
    (show "switch-buffer" (switch-cost (file-buffer 1000 #f) (file-buffer 1000 #f)))
    (show "edit-ten-views" (edit-cost (file-buffer 1000 #f) (file-buffer 1000 #f)))
    (show "edit-other-views" (other-views-cost (file-buffer 1000 #f) (file-buffer 1000 #f)
                                               (map (lambda (k) (file-buffer 10 #f)) (iota 10))))
    (show "next-stop" (stop-cost typical))
    (let ([large (scrolled-view (plain-buffer 1000000))])
      (show "draw-large" (draw-cost large))
      (show "type-large" (ns-per-op 2000 (lambda (i) (buffers:replace! (views:buffer large) (views:point large) (views:point large) "x"))))))
  (let ([chat (scrolled-view (chat-buffer 20000))])
    (printf "drawn lines: ~a chat\n" (drawn-lines chat))
    (show "draw-chat" (draw-cost chat))
    (show "type-chat" (ns-per-op 2000 (lambda (i) (buffers:replace! (views:buffer chat) (views:point chat) (views:point chat) "x"))))))

(import (tuna) (test) (views) (buffers) (document) (hooks) (options) (timers) (web) (test-user)
        (views-test page) (views-test text))

(options:set! views:scroll-margin 2 views:wrap-lines #f)

(define desktop (views-test/page:open 400))
(define phone (views-test/page:open 200))

(define (client page) (views-test/page:client page))
(define report! views-test/page:report!)
(define (line-of v p) (views-test/text:line-of v p))
(define (line-start v n) (views-test/text:line-start v n))

(define (make-buffer name content) (buffers:make (buffers:free-name name) content))

;; The layout draws only its own views, so each client's screen here is
;; the views this table names, drawn at each batch's end as the layout's.
(define screens '())

(define (show! page . vs)
  (set! screens (cons (cons (client page) vs) (remp (lambda (s) (eq? (car s) (client page))) screens))))

(advice-add! batch-ended
  (lambda (ended)
    (ended)
    (for-each (lambda (s) (for-each (lambda (v) (views:draw v (car s))) (cdr s))) screens)))

(define names '())
(define calls '())

(define (name! view name) (set! names (cons (cons view name) names)))

(hooks:add! views:drawn-ranges-changed
  (lambda (view buffer)
    (let ([name (assq view names)])
      (when name
        (set! calls (cons (list (cdr name) (buffers:name buffer) (eq? buffer (buffers:current))) calls))))))

;; The hook runs in a task the drawing spawns, and for a view a screen
;; left out only once the next batch has ended, so it has run once two
;; batches have ended.
(define (told)
  (test-user:settle)
  (test-user:settle)
  (let ([c (reverse calls)]) (set! calls '()) c))

(define (ranges v)
  (list-sort (lambda (a b) (< (car a) (car b)))
    (map (lambda (r) (list (line-of v (car r)) (line-of v (- (cdr r) 1)))) (views:drawn-ranges v))))

;; Ranges are read once the batch has ended and its screens are drawn.
(define (observed v)
  (let ([t (told)]) (list (ranges v) t)))

(define (observed-positions v)
  (let ([t (told)]) (list (views:drawn-ranges v) t)))

(define b (make-buffer "long" (views-test/text:lines 300)))
(define long-name (buffers:name b))
(define v (views:make b))
(name! v 'v)

(test "a view no client has drawn has no range"
  (check-equal? '(() ()) (observed-positions v)))

(test "a client's first screen draws 100 lines beyond each edge, and the hook runs once, with the view and its buffer current"
  (show! desktop v)
  (check-equal? `(((1 101)) ((v ,long-name #t))) (observed v)))

(test "the page's first report sets the range to what it asks, and each report of a moved page moves it"
  (report! desktop v 1 0 #f)
  (check-equal? `(((1 59)) ((v ,long-name #t))) (observed v))
  (report! desktop v 150 0 #f)
  (check-equal? `(((109 191)) ((v ,long-name #t))) (observed v))
  (report! desktop v 150 0 #f)
  (check-equal? `(((111 208)) ((v ,long-name #t))) (observed v))
  (report! desktop v 151 5 #t)
  (check-equal? `(((113 209)) ((v ,long-name #t))) (observed v))
  (report! desktop v 152 0 #t)
  (check-equal? `(((113 210)) ((v ,long-name #t))) (observed v))
  (report! desktop v 153 0 #t)
  (check-equal? `(((114 211)) ((v ,long-name #t))) (observed v)))

(test "a report that repeats the last, and a batch that changes nothing drawn, run no hook"
  (report! desktop v 153 0 #t)
  (check-equal? '(((114 211)) ()) (observed v))
  (check-equal? '(((114 211)) ()) (observed v)))

(test "the ends move with an edit, which runs no hook"
  (buffers:insert! b (line-start v 160) "new line\n")
  (check-equal? '(((114 212)) ()) (observed v))
  (buffers:replace! b (line-start v 160) (line-start v 161) "")
  (check-equal? '(((114 211)) ()) (observed v)))

(test "text typed at the end of a buffer whose end is drawn stays in the range and runs no hook, and a screen that leaves it out runs it"
  (let* ([s (make-buffer "short" "one\ntwo\n")] [u (views:make s)]
         [type-at-end! (lambda (text) (buffers:insert! s (- (document:length (buffers:document s)) 1) text))])
    (name! u 'u)
    (show! desktop v u)
    (report! desktop u 1 0 #f)
    (check-equal? `(((1 . 9)) ((u ,(buffers:name s) #t))) (observed-positions u))
    (type-at-end! "x")
    (check-equal? '(((1 . 10)) ()) (observed-positions u))
    (type-at-end! "y")
    (type-at-end! "\n")
    (check-equal? '(((1 . 12)) ()) (observed-positions u))
    (buffers:insert! s 1 "z")
    (check-equal? '(((1 . 13)) ()) (observed-positions u))
    (show! desktop v)
    (check-equal? `(() ((u ,(buffers:name s) #t))) (observed-positions u))))

(test "an empty buffer drawn runs the hook once, and then not again however many batches draw it"
  (let* ([e (make-buffer "empty" "")] [ev (views:make e)] [batches 0]
         [count (lambda (ended) (set! batches (+ batches 1)) (ended))])
    (name! ev 'ev)
    (show! desktop v ev)
    (check-equal? `(((1 . 1)) ((ev ,(buffers:name e) #t))) (observed-positions ev))
    (advice-add! batch-ended count)
    (timers:sleep 0.3)
    (advice-remove! batch-ended count)
    (check (< batches 100))
    (check-equal? '(((1 . 1)) ()) (observed-positions ev))
    (show! desktop v)
    (check-equal? `(() ((ev ,(buffers:name e) #t))) (observed-positions ev))))

(test "a fold or an unfold changes the range, and runs the hook, only when it leaves the range short or long for what the page asks"
  (views:fold! v (line-start v 170) (line-start v 180))
  (check-equal? `(((114 221)) ((v ,long-name #t))) (observed v))
  (views:unfold! v (line-start v 175))
  (check-equal? '(((114 221)) ()) (observed v))
  (views:fold! v (line-start v 120) (line-start v 200))
  (check-equal? '(((114 221)) ()) (observed v))
  (views:unfold! v (line-start v 150))
  (check-equal? '(((114 221)) ()) (observed v)))

(test "narrowing to a region holding the place keeps the range, and to one that does not scrolls to its start"
  (views:narrow! v (line-start v 50) (line-start v 260))
  (check-equal? '(((114 221)) ()) (observed v))
  (views:widen! v)
  (check-equal? '(((114 221)) ()) (observed v))
  (views:narrow! v (line-start v 20) (line-start v 60))
  (check-equal? `(((20 59)) ((v ,long-name #t))) (observed v))
  (views:widen! v)
  (check-equal? `(((19 101)) ((v ,long-name #t))) (observed v)))

(test "a jump draws the range anew around the new place"
  (views:scroll-to! v (line-start v 250) (views:align top))
  (check-equal? `(((209 291)) ((v ,long-name #t))) (observed v))
  (report! desktop v 250 0 #f)
  (check-equal? `(((211 300)) ((v ,long-name #t))) (observed v)))

(test "a paste inside the range carries its end along, and the next report sets it to what the page asks"
  (buffers:insert! b (line-start v 260) (views-test/text:lines 300))
  (check-equal? '(((211 600)) ()) (observed v))
  (report! desktop v 250 0 #f)
  (check-equal? `(((211 308)) ((v ,long-name #t))) (observed v)))

(define taller
  '(("aboveLines" . 81) ("aboveChars" . 6480) ("belowLines" . 81) ("belowChars" . 6480) ("side" . 160)))

(test "a taller page asks for more, which moves the range, and new columns that leave the ask as it was keep it"
  (report! desktop v 250 0 #f (cons "rows" 40) (cons "wanted" taller))
  (check-equal? `(((171 348)) ((v ,long-name #t))) (observed v))
  (report! desktop v 250 0 #f (cons "rows" 40) (cons "columns" 60) (cons "wanted" taller))
  (check-equal? '(((171 348)) ()) (observed v)))

(test "each client has a range of its own, and ranges of one view that change in one batch run the hook once"
  (show! phone v)
  (check-equal? `(((150 350) (171 348)) ((v ,long-name #t))) (observed v))
  (report! phone v 250 0 #f)
  (check-equal? `(((171 348) (231 278)) ((v ,long-name #t))) (observed v))
  (views-test/page:post-report! desktop v 240 0 #f)
  (views-test/page:post-report! phone v 240 0 #f)
  (check-equal? `(((201 298) (221 268)) ((v ,long-name #t))) (observed v)))

(test "a client that leaves takes its ranges with it, and two clients that draw the same range give it twice"
  (show! phone)
  (web:close-client! (client phone))
  (check-equal? `(((201 298)) ((v ,long-name #t))) (observed v))
  (let ([laptop (views-test/page:open 400)])
    (show! laptop v)
    (check-equal? `(((150 350) (201 298)) ((v ,long-name #t))) (observed v))
    (report! laptop v 240 0 #f)
    (check-equal? `(((201 298) (201 298)) ((v ,long-name #t))) (observed v))
    (show! laptop)
    (web:close-client! (client laptop))
    (check-equal? `(((201 298)) ((v ,long-name #t))) (observed v))))

(define o (make-buffer "other" (views-test/text:lines 50)))
(define w (views:make o))
(name! w 'w)

(test "a draw for no client adds no range"
  (views:draw w #f)
  (let ([t (told)])
    (check-equal? '(() ((201 298)) ()) (list (views:drawn-ranges w) (ranges v) t))))

(test "a screen that leaves a view out holds no range of it from then on, and the hook runs for it a batch later"
  (let* ([seen #f] [look (lambda (view buffer) (when (eq? view w) (set! seen (views:drawn-ranges v))))])
    (hooks:add! views:drawn-ranges-changed look)
    (show! desktop w)
    (let ([t (told)])
      (check-equal? `(((1 50)) () () ((w ,(buffers:name o) #t) (v ,long-name #t))) (list (ranges w) (ranges v) seen t)))
    (hooks:remove! views:drawn-ranges-changed look)
    (show! desktop v w)
    (let ([t (told)])
      (check-equal? `(((1 50)) ((201 298)) ((v ,long-name #t))) (list (ranges w) (ranges v) t)))))

(test "a view that shows another buffer runs the hook for the buffer it left, then for the one it shows, each current"
  (let ([t (make-buffer "third" (views-test/text:lines 100))])
    (views:set-buffer! v t)
    (check-equal? `(((1 100)) ((v ,long-name #t) (v ,(buffers:name t) #t))) (observed v))
    (views:previous-buffer! v)
    (check-equal? `(((150 350)) ((v ,(buffers:name t) #t) (v ,long-name #t))) (observed v))
    (views:preview-buffer! v o)
    (check-equal? `(((1 50)) ((v ,long-name #t) (v ,(buffers:name o) #t))) (observed v))
    (views:end-preview! v)
    (check-equal? `(((150 350)) ((v ,(buffers:name o) #t) (v ,long-name #t))) (observed v))
    (views:set-buffer! v t)
    (check-equal? `(((1 100)) ((v ,long-name #t) (v ,(buffers:name t) #t))) (observed v))
    (buffers:kill! t)
    (let ([t (told)])
      (check-equal? `(,long-name ((150 350)) ((v ,long-name #t))) (list (buffers:name (views:buffer v)) (ranges v) t)))))

(test "a killed buffer that no buffer replaces in a view is never told of"
  (let* ([k (make-buffer "kept" (views-test/text:lines 10))] [x (views:make k)])
    (name! x 'x)
    (show! desktop v w x)
    (check-equal? `(((1 10)) ((x ,(buffers:name k) #t))) (observed x))
    (options:with ([views:skipped-buffer-predicate (lambda (view buffer reason) (eq? view x))])
      (buffers:kill! k)
      (let ([t (told)])
        (check-equal? '(#f () ()) (list (views:buffer x) (views:drawn-ranges x) t))))))

(define (reports-during thunk)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (thunk)
    (advice-remove! report keep)
    (reverse reported)))

(test "an entry that raises is reported and kept, and the others run"
  (let ([fails (lambda (view buffer) (car '()))])
    (hooks:add! views:drawn-ranges-changed fails -1)
    (let ([reported (reports-during (lambda () (views:scroll-to! v (line-start v 20) (views:align top)) (told)))])
      (check-equal? '(car) (map condition-who reported)))
    (check-equal? '((1 120)) (ranges v))
    (let* ([seen #f]
           [reported (reports-during (lambda () (views:scroll-to! v (line-start v 200) (views:align top)) (set! seen (told))))])
      (check-equal? '(car) (map condition-who reported))
      (check-equal? `(((100 300)) ((v ,long-name #t))) (list (ranges v) seen)))
    (hooks:remove! views:drawn-ranges-changed fails)))

(test "an entry that moves the range it is told of runs the hook again once the move is drawn; moving it once, it runs twice"
  (let* ([moves 0]
         [move-once (lambda (view buffer)
                      (when (and (eq? view v) (= moves 0))
                        (set! moves (+ moves 1))
                        (views:scroll-to! v (line-start v 100) (views:align top))))])
    (hooks:add! views:drawn-ranges-changed move-once)
    (views:scroll-to! v (line-start v 20) (views:align top))
    (test-user:settle)
    (let ([t (told)])
      (check-equal? `(((1 200)) 1 ((v ,long-name #t) (v ,long-name #t))) (list (ranges v) moves t)))
    (let ([t (told)])
      (check-equal? '(((1 200)) 1 ()) (list (ranges v) moves t)))
    (hooks:remove! views:drawn-ranges-changed move-once)))

(test "an entry that moves the range on every call runs the hook every batch, and other tasks still run between rounds"
  (let* ([rounds 0]
         [move-always (lambda (view buffer)
                        (when (eq? view v)
                          (set! rounds (+ rounds 1))
                          (views:scroll-to! v (line-start v (if (even? rounds) 20 200)) (views:align top))))])
    (hooks:add! views:drawn-ranges-changed move-always)
    (views:scroll-to! v (line-start v 150) (views:align top))
    (test-user:settle)
    (check (> rounds 0))
    (test-user:settle)
    (check (> rounds 1))
    (hooks:remove! views:drawn-ranges-changed move-always)
    (told)
    (let ([stopped rounds])
      (check-equal? '() (told))
      (check-equal? stopped rounds))))

(test "a dropped view runs the hook for the buffer it showed, which no longer lists it, and has no ranges to ask for"
  (let* ([seen 'none]
         [showing (lambda (view buffer) (when (eq? view v) (set! seen (and (memq view (views:showing buffer)) #t))))])
    (hooks:add! views:drawn-ranges-changed showing)
    (show! desktop w)
    (views:drop! v)
    (let ([t (told)])
      (check-equal? `((v ,long-name #t)) t)
      (check-equal? #f seen))
    (check-raises (lambda (e) (and (who-condition? e) (eq? 'views:drawn-ranges (condition-who e))
                                   (string=? "a dropped view" (condition-message e))))
                  (views:drawn-ranges v))
    (hooks:remove! views:drawn-ranges-changed showing)))

(test "where lines do not wrap a one-line file is one range of the whole file; where they wrap, only the long line's pieces drawn"
  (let* ([m (make-buffer "minified" (make-string 100000 #\x))] [y (views:make m)])
    (name! y 'y)
    (show! desktop w y)
    (check-equal? `(((1 . 100001)) ((y ,(buffers:name m) #t))) (observed-positions y))
    (views:set-option! y views:wrap-lines #t)
    (check-equal? `(((1 . 20993)) ((y ,(buffers:name m) #t))) (observed-positions y))))

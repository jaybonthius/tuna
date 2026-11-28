(import (tuna) (test) (test-runner) (views) (buffers) (document) (options) (tables) (web) (test-user)
        (views-test page) (views-test md) (views-test keyed) (views-test fill) (views-test wide))

(options:set! views:scroll-margin 2 views:wrap-lines #f)

(define (raised-by who)
  (lambda (e) (and (who-condition? e) (eq? who (condition-who e)))))

(define (text-of b) (document:text (buffers:document b)))

(define (bounds v) (call-with-values (lambda () (views:bounds v)) list))

(tables:define-table own-keys)

(test "a view shows a buffer and is found by its number while it lives"
  (let* ([notes (buffers:make (buffers:free-name "notes") "one two three\n")]
         [v (views:make notes)]
         [w (views:make notes)])
    (check (views:view? v))
    (check (not (views:view? notes)))
    (check-equal? (+ (views:id v) 1) (views:id w))
    (check-equal? w (views:find (views:id w)))
    (check-equal? #f (views:find (+ (views:id w) 1000)))
    (check-equal? notes (views:buffer v))
    (check-equal? (list v w) (list-sort (lambda (a b) (< (views:id a) (views:id b))) (views:showing notes)))
    (check-raises (test-runner:raised-with 'views:make "not a live buffer") (views:make 'notes))
    (check-raises (test-runner:raised-with 'views:find "not a view number") (views:find 0))
    (check-raises (test-runner:raised-with 'views:showing "not a buffer") (views:showing 'notes))))

(test "a view has cursors, the primary first, and moving one does not edit the buffer"
  (let* ([notes (buffers:make (buffers:free-name "notes") "one two three\nfour five six\nseven\n")]
         [v (views:make notes)]
         [c2 (views:add-cursor! v 5)])
    (check (views:cursor? c2))
    (check-equal? '(1 5) (map views:cursor-point (views:cursors v)))
    (check-equal? 0 (buffers:version notes))
    (views:set-cursor! c2 9 5)
    (check-equal? '(9 5) (list (views:cursor-point c2) (views:cursor-mark c2)))
    (views:set-cursor-goal! c2 4)
    (check-equal? 4 (views:cursor-goal c2))
    (views:set-cursor! c2 10 #f)
    (check-equal? '(#f #f) (list (views:cursor-goal c2) (views:cursor-mark c2)))
    (views:set-mark! v 3)
    (check-equal? '(1 3) (list (views:point v) (views:mark v)))
    (views:set-mark! v #f)
    (check-equal? #f (views:mark v))))

(test "a point moves to the nearest stop inside the buffer's root, and a position past the end is refused"
  (let ([v (views:make (buffers:make (buffers:free-name "notes") "one two\n"))])
    (views:set-point! v 0)
    (check-equal? 1 (views:point v))
    (check-raises (test-runner:raised-with 'views:set-point! "not a position in the view's buffer") (views:set-point! v 1000))))

(test "a cursor whose point meets another's after an edit goes, and each view keeps its own cursors"
  (let* ([notes (buffers:make (buffers:free-name "notes") "one two three\nfour five six\nseven\n")]
         [v (views:make notes)]
         [w (views:make notes)]
         [c2 (views:add-cursor! v 10)])
    (views:set-point! v 5)
    (let ([c3 (views:add-cursor! v 9)])
      (check-equal? 3 (length (views:cursors v)))
      (buffers:replace! notes 5 9 "")
      (test-user:settle)
      (check-equal? '(5 6) (map views:cursor-point (views:cursors v)))
      (views:remove-cursor! v (car (views:cursors v)))
      (check-raises (test-runner:raised-with 'views:remove-cursor! "not a cursor of the view") (views:remove-cursor! v c3))
      (check-raises (test-runner:raised-with 'views:remove-cursor! "not a cursor of the view") (views:remove-cursor! w c2))
      (check-equal? '(6 1) (list (views:point v) (views:point w))))))

(test "the last cursor cannot be removed"
  (let ([v (views:make (buffers:make (buffers:free-name "notes") "one\n"))])
    (check-raises (raised-by 'views:remove-cursor!) (views:remove-cursor! v (car (views:cursors v))))))

(test "a view's option wins over the buffer's local value, is checked, and is taken back when removed"
  (let* ([notes (buffers:make (buffers:free-name "notes") "one\n")]
         [v (views:make notes)]
         [w (views:make notes)])
    (buffers:with-buffer notes (options:set-local! views-test/fill:column 60))
    (views:set-option! v views-test/fill:column 72)
    (check-equal? '(72 60 70)
      (list (views:with-view v (views-test/fill:column)) (views:with-view w (views-test/fill:column)) (views-test/fill:column)))
    (check-equal? 72 (views:with-view v (buffers:with-buffer notes (options:set-local! views-test/fill:column 50)) (views-test/fill:column)))
    (check-equal? 50 (views:with-view w (views-test/fill:column)))
    (check-raises (raised-by 'views:set-option!) (views:set-option! v views-test/fill:column 'wide))
    (check-raises (test-runner:raised-with 'views:set-option! "not an option") (views:set-option! v 'fill:column 1))
    (views:remove-option! v views-test/fill:column)
    (check-equal? 50 (views:with-view v (views-test/fill:column)))))

(test "with-view makes the view and its buffer current"
  (let* ([notes (buffers:make (buffers:free-name "notes") "one\n")] [v (views:make notes)])
    (check-equal? #f (views:current))
    (check (views:with-view v (eq? (views:current) v)))
    (check (views:with-view v (eq? (buffers:current) notes)))
    (check (views:call-with-view v (lambda () (eq? (views:current) v))))
    (check-raises (test-runner:raised-with 'views:call-with-view "not a procedure") (views:call-with-view v 5))))

(test "the values a module sets for a view go when it unloads"
  (let ([v (views:make (buffers:make (buffers:free-name "notes") "one\n"))])
    (call-as-owner (module-owner '(views-test wide)) (lambda () (views-test/wide:widen-view! v)))
    (check-equal? 3 (views:with-view v (views:drawn-screens)))
    (unload-owner! (module-owner '(views-test wide)))
    (check-equal? 2 (views:with-view v (views:drawn-screens)))))

(test "a view keeps state per node, apart from other views, and it goes with its node"
  (let* ([m (buffers:make (buffers:free-name "m")
              (views-test/md:doc '() (views-test/md:para '() "a\n") (views-test/md:para '() "b\n")))]
         [mv (views:make m)]
         [mw (views:make m)]
         [para (lambda (k) (document:token (buffers:document m) (if (= k 1) 1 5)))])
    (views:set-node-state! mv (para 2) 'open)
    (check-equal? '(open closed closed)
      (list (views:node-state mv (para 2) 'closed) (views:node-state mw (para 2) 'closed) (views:node-state mv (para 1) 'closed)))
    (views:set-node-state! mv (para 2) 'shut)
    (check-equal? 'shut (views:node-state mv (para 2) #f))
    (buffers:splice! m 1 5 (document:from-datum))
    (check-equal? 'shut (views:node-state mv (para 1) 'gone))
    (buffers:splice! m 1 5 (document:from-datum (views-test/md:para '() "c\n")))
    (check-equal? 'gone (views:node-state mv (para 1) 'gone))
    (check-raises (test-runner:raised-with 'views:node-state "not a node") (views:node-state mv 'x #f))))

(test "the keymaps at the primary cursor are its layers' by priority, a span's own first, then its nodes' kinds, innermost first"
  (let* ([k (buffers:make (buffers:free-name "k")
              (views-test/keyed:box '() (views-test/keyed:field '() "abc\n")))]
         [kv (views:make k)])
    (buffers:add-span! (buffers:layer k views-test/keyed:links) 2 4 'link)
    (buffers:add-span! (buffers:layer k views-test/keyed:plain) 2 4 'plain)
    (check-equal? '(link-keys field-keys box-keys) (views:keymaps kv))
    (views:set-point! kv 5)
    (check-equal? '(field-keys box-keys) (views:keymaps kv))
    (buffers:add-span! (buffers:layer k views-test/keyed:links) 2 3 (list (cons 'keymap own-keys)))
    (views:set-point! kv 2)
    (let ([ks (views:keymaps kv)])
      (check-equal? own-keys (car ks))
      (check-equal? '(link-keys field-keys box-keys) (cdr ks)))
    (views:set-point! kv 3)
    (check-equal? '(link-keys field-keys box-keys) (views:keymaps kv))))

(test "set-buffer! shows a buffer at its last point and keeps the view's options, not its folds"
  (let* ([notes (buffers:make (buffers:free-name "notes") "one two three\nfour five six\n")]
         [k (buffers:make (buffers:free-name "k") "abcdef\n")]
         [kv (views:make k)]
         [w (views:make notes)])
    (views:set-point! kv 5)
    (views:set-option! w views:wrap-lines #t)
    (views:fold! w 2 3)
    (views:set-buffer! w k)
    (check-equal? k (views:buffer w))
    (check-equal? 5 (views:point w))
    (check (not (views:folded? w 2)))
    (check (views:with-view w (views:wrap-lines)))
    (buffers:kill! k)
    (check-equal? notes (views:buffer w))))

(test "copy-state! gives a view of the same buffer another's cursors, marks, narrowing, folds and options, but not its buffer history, and each view keeps its own"
  (let* ([notes (buffers:make (buffers:free-name "notes") (apply string-append (map (lambda (i) "a line of text\n") (iota 20))))]
         [k (buffers:make (buffers:free-name "k") "abcdef\n")]
         [v (views:make k)]
         [w (views:make notes)])
    (views:set-buffer! v notes)
    (views:narrow! v 10 200)
    (views:fold! v 50 70)
    (views:set-point! v 30)
    (views:set-mark! v 20)
    (views:set-cursor! (views:add-cursor! v 40) 45 42)
    (views:set-option! v views:wrap-lines #f)
    (views:copy-state! v w)
    (check-equal? '((30 . 20) (45 . 42)) (map (lambda (c) (cons (views:cursor-point c) (views:cursor-mark c))) (views:cursors w)))
    (check-equal? '(10 200) (bounds w))
    (check (views:folded? w 60))
    (check-equal? #f (views:with-view w (views:wrap-lines)))
    (check-equal? '() (views:previous-buffers w))
    (check-equal? (list k) (views:previous-buffers v))
    (views:set-point! w 100)
    (views:widen! w)
    (views:unfold! w 60)
    (check-equal? '(30 (10 200) #t) (list (views:point v) (bounds v) (views:folded? v 60)))
    (check-raises (test-runner:raised-with 'views:copy-state! "the views show different buffers") (views:copy-state! v (views:make k)))
    (check-raises (test-runner:raised-with 'views:copy-state! "not a view") (views:copy-state! v notes))))

(test "copy-state! gives the copy the state the view keeps per node, which each then changes apart"
  (let* ([m (buffers:make (buffers:free-name "m")
              (views-test/md:doc '() (views-test/md:para '() "a\n") (views-test/md:para '() "b\n")))]
         [mv (views:make m)]
         [mw (views:make m)]
         [para (document:token (buffers:document m) 5)])
    (views:set-node-state! mv para 'open)
    (views:copy-state! mv mw)
    (check-equal? 'open (views:node-state mw para 'closed))
    (views:set-node-state! mw para 'shut)
    (check-equal? '(open shut) (list (views:node-state mv para #f) (views:node-state mw para #f)))))

(test "views are used on the main thread only"
  (let* ([v (views:make (buffers:make (buffers:free-name "notes") "one\n"))]
         [reported '()]
         [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (let ([t (fork-task (lambda (restore) (views:set-point! v 1)))])
      (check-raises (test-runner:raised-with 'views:set-point! "not on the main thread") (test-runner:join t)))
    (test-runner:wait-until (lambda () (pair? reported)))
    (advice-remove! report keep)
    (check-equal? 1 (length reported))
    (check ((test-runner:raised-with 'views:set-point! "not on the main thread") (car reported)))))

(test "a cursor whose node an edit deletes moves to a stop, and one from before set-buffer! is no cursor of the view"
  (let* ([three (buffers:make (buffers:free-name "three")
                  (views-test/md:doc '() (views-test/md:para '() "aa\n") (views-test/md:para '() "bb\n")
                                         (views-test/md:para '() "cc\n")))]
         [tv (views:make three)])
    (views:set-point! tv 8)
    (buffers:replace! three 6 11 "")
    (test-user:settle)
    (check-equal? 7 (views:point tv))
    (check-equal? 7 (buffers:stop three (views:point tv)))
    (let ([old (car (views:cursors tv))])
      (views:set-buffer! tv (buffers:make (buffers:free-name "notes") "x\n"))
      (check-raises (test-runner:raised-with 'views:set-cursor! "not a cursor of the view") (views:set-cursor! old 1 #f)))))

(test "drawn-screens takes only finite numbers, and a huge one still draws"
  (let ([v (views:make (buffers:make (buffers:free-name "notes") "one\n"))])
    (check-raises (raised-by 'options:set!) (options:set! views:drawn-screens +inf.0))
    (views:set-option! v views:drawn-screens 1e300)
    (check (views-test/page:element-for-no-client v))))

(test "a dropped view is forgotten: no number finds it, it shows nothing, and using it raises"
  (let* ([notes (buffers:make (buffers:free-name "notes") "one\n")]
         [gone (views:make notes)]
         [id (views:id gone)])
    (views:drop! gone)
    (check-equal? #f (views:find id))
    (check (views:view? gone))
    (check-equal? #f (memq gone (views:showing notes)))
    (check-raises (test-runner:raised-with 'views:point "a dropped view") (views:point gone))
    (check-raises (test-runner:raised-with 'views:drop! "a dropped view") (views:drop! gone))))

(test "killing a buffer drops the views its atoms drew, and a view showing it shows another buffer"
  (let* ([notes (buffers:make (buffers:free-name "notes") "one\n")]
         [host (buffers:make (buffers:free-name "host")
                 (views-test/md:doc '() (views:view `((view . 40) (buffer . ,(buffers:name notes))))))]
         [hv (views:make host)])
    (check (views-test/page:element-for-no-client hv))
    (check-equal? 40 (views:id (views:find 40)))
    (buffers:kill! host)
    (check-equal? #f (views:find 40))
    (check (not (eq? (views:buffer hv) host)))
    (check-equal? hv (views:find (views:id hv)))))

(test "each view of a killed buffer shows its newest previous buffer, never an internal one"
  (let* ([older (buffers:make (buffers:free-name "older") "o\n")]
         [inner (buffers:make (buffers:free-name " inner") "i\n")]
         [doomed (buffers:make (buffers:free-name "doomed") "d\n")]
         [came-from-older (views:make older)])
    (views:set-buffer! came-from-older inner)
    (views:set-buffer! came-from-older doomed)
    (let ([fresh (views:make doomed)])
      (buffers:kill! doomed)
      (check-equal? older (views:buffer came-from-older))
      (check (not (buffers:internal-name? (buffers:name (views:buffer fresh)))))
      (check (not (eq? doomed (views:buffer fresh)))))))

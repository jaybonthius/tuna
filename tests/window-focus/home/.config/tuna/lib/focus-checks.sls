#!tuna
(import (layout) (layout-split) (layout-tabs) (layout-scroll) (layout-float) (buffers) (document) (views)
        (commands) (minibuffer) (web) (keys) (status-line) (recent-views) (haml) (tables) (timers))

(define-record-type %node
  (fields kind attrs kids id (mutable parent)))

(define (%parse d)
  (if (vector? d)
      (make-%node 'view (vector-ref d 1) '() (cdr (assq 'view (vector-ref d 1))) #f)
      (let ([n (make-%node (car d) (cadr d) (map %parse (cddr d)) #f #f)])
        (for-each (lambda (k) (%node-parent-set! k n)) (%node-kids n))
        n)))

(define (%tree-of b) (%parse (car (document:datums (buffers:document b)))))

(define (%atoms n)
  (if (eq? (%node-kind n) 'view) (list n) (fold-right (lambda (k acc) (append (%atoms k) acc)) '() (%node-kids n))))

(define (%attribute? n key) (let ([p (assq key (%node-attrs n))]) (and p (cdr p) #t)))

(define (%flag? n key)
  (let loop ([n n]) (and n (or (%attribute? n key) (loop (%node-parent n))))))

(define (%locked? n) (%flag? n 'locked))
(define (%other-view? n) (%flag? n 'other-view))
(define (%level? n) (eq? (%node-kind n) 'layout:level))
(define (%tabs? n) (eq? (%node-kind n) 'layout-tabs:container))
(define (%float? n) (eq? (%node-kind n) 'layout-float:container))

(define (%ancestors n) (let loop ([p (%node-parent n)]) (if p (cons p (loop (%node-parent p))) '())))

(define (%within? n outer) (or (eq? n outer) (and (memq outer (%ancestors n)) #t)))

(define (%level-of n) (find %level? (%ancestors n)))

(define (%find-atom root id) (find (lambda (a) (eqv? (%node-id a) id)) (%atoms root)))

(define (%ids n) (map %node-id (%atoms n)))

(define (%placed-below? n top)
  (let loop ([n n]) (and n (not (eq? n top)) (or (%attribute? n 'depth) (loop (%node-parent n))))))

(define (%mru atoms order)
  (let* ([unlocked (remp %locked? atoms)] [pool (if (null? unlocked) atoms unlocked)])
    (and (pair? pool)
         (or (exists (lambda (id) (find (lambda (a) (eqv? (%node-id a) id)) pool)) order)
             (car pool)))))

(define (%candidate? root id)
  (let ([a (%find-atom root id)]) (and a (not (%locked? a)) (not (%other-view? a)))))

(define (%reference root order)
  (or (%mru (filter (lambda (a) (%candidate? root (%node-id a))) (%atoms root)) order) (%mru (%atoms root) order)))

;; Written from the rule's words, not from layout's steps, so that an
;; error in those steps shows as a disagreement.
(define (%successor old new r-id order)
  (let* ([r (%find-atom old r-id)]
         [survivors (lambda (n) (filter (lambda (id) (%find-atom new id)) (%ids n)))]
         [held (filter pair?
                 (let loop ([child r] [acc '()])
                   (let ([k (%node-parent child)])
                     (if k (loop k (if (%tabs? k) (cons (survivors child) acc) acc)) acc))))]
         [excluded? (lambda (w) (eqv? (%node-id w) r-id))])
    (define (pin-child n)
      (find (lambda (c) (exists (lambda (ids) (for-all (lambda (id) (%within? (%find-atom new id) c)) ids)) held))
            (%node-kids n)))
    (define (focused n)
      (or (exists (lambda (id) (find (lambda (c) (memv id (%ids c))) (%node-kids n))) order)
          (car (%node-kids n))))
    (define (shows? n c rel)
      (let ([pin (pin-child n)])
        (eq? c (if (and pin (holds? pin rel)) pin (focused n)))))
    (define (visible? w top rel)
      (let loop ([x w])
        (or (eq? x top)
            (let ([p (%node-parent x)])
              (and (or (not (%tabs? p)) (shows? p x rel)) (loop p))))))
    (define (holds? c rel)
      (exists (lambda (w) (and (not (excluded? w)) (not (%locked? w)) (not (%placed-below? w rel)) (visible? w c rel)))
              (%atoms c)))
    (define (stand-in m)
      (let* ([top (car (%node-kids m))]
             [shown (filter (lambda (w) (and (not (excluded? w)) (visible? w top m))) (%atoms m))]
             [free (remp (lambda (w) (%placed-below? w m)) shown)])
        (%mru (if (null? free) shown free) order)))
    (define (candidates l)
      (let* ([top (car (%node-kids l))]
             [usable? (lambda (u) (and u (not (%locked? u)) (not (%placed-below? u l))))]
             [views (filter (lambda (w) (and (eq? (%level-of w) l) (not (excluded? w)) (visible? w top l) (usable? w)))
                            (%atoms l))]
             [nested (let collect ([n top])
                       (cond
                         [(eq? (%node-kind n) 'view) '()]
                         [(%level? n) (list n)]
                         [else (apply append (map collect (%node-kids n)))]))]
             [standing (filter usable?
                         (map stand-in (filter (lambda (m) (visible? m top l)) nested)))]
             [all (%atoms new)])
        (filter (lambda (w) (or (memq w views) (memq w standing))) all)))
    (define (level-found l)
      (let ([ids (survivors l)])
        (and (pair? ids)
             (let* ([enclosing (map (lambda (id) (filter %level? (%ancestors (%find-atom new id)))) ids)]
                    [common (filter (lambda (m) (for-all (lambda (ls) (memq m ls)) enclosing)) (car enclosing))])
               (and (pair? common) (car common))))))
    (or (exists (lambda (l) (let ([m (level-found l)]) (and m (%mru (candidates m) order))))
                (filter %level? (%ancestors r)))
        (%mru (remp excluded? (%atoms new)) order))))

(define (%with-first id order) (cons id (remv id order)))

(define (%expected-order old new popups order)
  (let* ([live? (lambda (id) (or (%find-atom new id) (%find-atom popups id)))]
         [selected (and (pair? order) (car order))]
         [r (%reference old order)]
         [r-id (and r (%node-id r))]
         [handed? (and r (not (%candidate? new r-id)))]
         [o (filter live? order)]
         [o (if handed?
                (let ([s (%successor old new r-id o)])
                  (cond
                    [(not s) o]
                    [(and (eqv? r-id selected) (not (live? r-id))) (%with-first (%node-id s) o)]
                    [(not (%candidate? new (%node-id s))) o]
                    [else
                     (let loop ([os (remv (%node-id s) o)] [before '()])
                       (cond
                         [(null? os) (append (reverse before) (list (%node-id s)))]
                         [(%candidate? new (car os)) (append (reverse before) (cons (%node-id s) os))]
                         [else (loop (cdr os) (cons (car os) before))]))]))
                o)])
    (if (or (null? o) (and (not (live? selected)) (not (and handed? (eqv? r-id selected)))))
        (%with-first (%node-id (%reference new o)) o)
        o)))

(define (%floats-by-use floats order)
  (let* ([rank (lambda (f) (let loop ([os order] [k 0])
                             (cond [(null? os) #f] [(memv (car os) (%ids f)) k] [else (loop (cdr os) (fx+ k 1))])))]
         [used (filter rank floats)])
    (append (list-sort (lambda (a b) (fx< (rank a) (rank b))) used) (reverse (remp rank floats)))))

(define %checks 0)
(define %failures 0)
(define %where #f)

;; A failure prints the tree and the order it happened in, since a seed
;; replays only as far as the editor's own timing allows.
(define (%fail! fmt . args)
  (set! %failures (+ %failures 1))
  (when (<= %failures 10)
    (apply printf fmt args)
    (printf "  in ~s\n  order ~s\n" (car (document:datums (buffers:document layout:buffer))) (%order-ids))))

(define (%check! what expected actual)
  (set! %checks (+ %checks 1))
  (unless (equal? expected actual)
    (%fail! "~s: ~a: expected ~s, got ~s\n" %where what expected actual)))

(define (%order-ids) (map views:id (layout:selection-order)))
(define (%selected-id) (views:id (layout:selected-view)))

(define (%layout) (%tree-of layout:buffer))
(define (%popups) (%tree-of layout:popups-buffer))

(define (%pick-one xs) (and (pair? xs) (list-ref xs (random (length xs)))))

(define (%nodes b)
  (let ([doc (buffers:document b)] [acc '()])
    (let walk ([n (document:token doc 0)])
      (unless (document:atom? n)
        (document:for-each-child n (fx+ (document:node-start n) 1) (fx- (document:node-end n) 1)
          (lambda (c at)
            (when (document:node? c)
              (set! acc (cons c acc))
              (walk c))))))
    (reverse acc)))

(define (%all-views)
  (filter values (map (lambda (n) (and (document:atom? n) (views:find (document:node-attribute n 'view #f))))
                      (append (%nodes layout:buffer) (%nodes layout:popups-buffer)))))

(define %count 0)

(define (%fresh-buffer)
  (set! %count (+ %count 1))
  (buffers:make (string-append "v" (number->string %count)) "x\n"))

(define (%fresh-view) (views:make (%fresh-buffer)))

(define (%view-datum v attrs)
  (views:view (cons* (cons 'view (views:id v)) (cons 'buffer (buffers:name (views:buffer v))) attrs)))

(define (%marks)
  (append (if (fxzero? (random 6)) '((locked . #t)) '())
          (if (fxzero? (random 8)) '((depth . 50)) '())
          (if (fxzero? (random 10)) '((other-view . #t)) '())))

(define (%random-part depth level-ok?)
  (let ([r (if (fx>= depth 4) 0 (random 7))])
    (case r
      [(0 1) (%view-datum (%fresh-view) (%marks))]
      [(2) (apply layout-split:container (cons* (cons 'direction (if (fxzero? (random 2)) 'row 'column)) (%marks))
                  (map (lambda (k) (%random-part (fx+ depth 1) #t)) (iota (fx+ 2 (random 3)))))]
      [(3) (apply layout-tabs:container (%marks) (map (lambda (k) (%random-part (fx+ depth 1) #t)) (iota (fx+ 1 (random 3)))))]
      [(4) (if level-ok?
               (layout:level (%marks) (%random-part (fx+ depth 1) #f))
               (%random-part depth #f))]
      [(5) (apply layout-scroll:container (%marks)
                  (map (lambda (k) (%with-attribute (%random-part (fx+ depth 1) #t) '(size . 1/2))) (iota (fx+ 1 (random 4)))))]
      [else (apply layout-float:container (%marks)
                   (cons (%random-part (fx+ depth 1) #t)
                         (map (lambda (k) (%with-attribute (%random-part (fx+ depth 1) #t) '(place box 1/2 1/2)))
                              (iota (random 3)))))])))

(define (%with-attribute d a)
  (if (vector? d)
      (vector (vector-ref d 0) (append (vector-ref d 1) (list a)))
      (cons* (car d) (append (cadr d) (list a)) (cddr d))))

(define (%run client thunk)
  (parameterize ([web:current-client client])
    (views:call-with-view (layout:selected-view) thunk)))

;; A command refused is reported, not raised; the checks count the
;; refusals a user meets as such, and any other condition as a failure, so
;; an error inside a command does not pass for a refusal.
(define %quiet? (make-thread-parameter #f))
(define %refused #f)

(define (%hush report c) (if (%quiet?) (set! %refused c) (report c)))

(define %refusals
  '("the last view of its level" "the last view that is not locked" "a locked part"
    "no more back history in this level" "no more forward history in this level"
    "the selected view is in no tabs" "the selected view is in no strip" "no more recent tabs"))

(define (%refused? thunk)
  (set! %refused #f)
  (let ([c (guard (c [(not (cancelled? c)) c])
             (parameterize ([%quiet? #t]) (thunk))
             %refused)])
    (and c
         (or (and (message-condition? c) (member (condition-message c) %refusals) #t)
             (begin
               (set! %checks (+ %checks 1))
               (%fail! "~s: unexpected ~a ~s\n" %where (if (message-condition? c) (condition-message c) c)
                       (and (irritants-condition? c) (condition-irritants c)))
               #t)))))

(define (%command! client command) (%refused? (lambda () (%run client (lambda () (commands:run command))))))

(define (%end-prompts! client)
  (let ([p (minibuffer:current-prompt)])
    (when p
      (%run client minibuffer:abort)
      (let wait () (when (eq? (minibuffer:current-prompt) p) (timers:sleep 0.01) (wait)))
      (%end-prompts! client))))

(define (%close-popups!)
  (for-each (lambda (n) (when (document:atom? n) (guard (c [#t #f]) (layout-float:close! (views:find (document:node-attribute n 'view))))))
            (%nodes layout:popups-buffer)))

(define (%set-root! d)
  (let ([n (document:length (buffers:document layout:buffer))])
    (buffers:replace! layout:buffer 1 (fx- n 1) (document:from-datum d))))

(define (%build! client)
  (%end-prompts! client)
  (%close-popups!)
  (let loop ([tries 0])
    (let ([d (%random-part 0 #f)])
      (unless (and (not (and (pair? d) (eq? (car d) 'layout:level)))
                   (guard (c [#t #f]) (%set-root! d) #t)
                   (exists (lambda (a) (not (%locked? a))) (%atoms (%layout))))
        (when (fx< tries 50) (loop (fx+ tries 1))))))
  (do ([k (random 4) (fx- k 1)]) ((fxzero? k))
    (guard (c [#t #f])
      ((layout-split:display-at-side (%pick-one (list (layout:direction left) (layout:direction right) (layout:direction up) (layout:direction down)))
                                     (fx+ 10 (random 80)) '(columns 10) (if (fxzero? (random 2)) '((locked . #t)) '()))
       (%fresh-buffer))))
  (do ([k (random 3) (fx- k 1)]) ((fxzero? k))
    (guard (c [#t #f])
      (if (fxzero? (random 2))
          (layout-float:display-palette (%fresh-buffer))
          (let ([v (%pick-one (layout:views))])
            (layout-float:show-at! v 0 (%fresh-buffer) '(columns 10) '(lines 3))))))
  (do ([k (random 7) (fx- k 1)]) ((fxzero? k))
    (let ([v (%pick-one (%all-views))]) (when v (layout:select! v)))))

(define (%before) (list (%layout) (%popups) (%order-ids) (map buffers:name (buffers:all))))

(define (%check-order! what before)
  (%check! (list what 'order) (%expected-order (car before) (%layout) (%popups) (caddr before)) (%order-ids)))

(define (%check-edit! what before)
  (%check-order! what before)
  (%check! (list what 'no-use) (filter buffers:find (cadddr before)) (map buffers:name (buffers:all))))

(define (%check-not-locked! what before)
  (let ([old (car (caddr before))] [tree (%layout)])
    (unless (or (%find-atom tree old) (%find-atom (%popups) old))
      (let ([a (%find-atom tree (%selected-id))])
        (%check! (list what 'not-locked)
                 #t (or (not a) (not (%locked? a)) (not (exists (lambda (w) (not (%locked? w))) (%atoms tree)))))))))

(define (%check-part-reach! what before)
  (let* ([tree (car before)] [order (caddr before)] [old (%find-atom tree (car order))]
         [new (%find-atom tree (%selected-id))])
    (when (and old new (not (eq? old new)))
      (let* ([common (find (lambda (p) (%within? old p)) (%ancestors new))]
             [part (let up ([n new]) (if (eq? (%node-parent n) common) n (up (%node-parent n))))])
        (%check! (list what 'part-view) (%node-id (%mru (%atoms part) order)) (%node-id new))
        (%check! (list what 'not-locked) #f (%locked? new))))))

(define (%check-live!)
  (let ([v (layout:selected-view)])
    (%check! 'live #t (and (or (layout:view-node v) (layout:popup-node v)) #t))))

(define (%check-reference!)
  (let* ([tree (%layout)] [order (%order-ids)] [r (%reference tree order)] [s (%selected-id)]
         [in-layout (%find-atom tree s)]
         [others (map views:id (layout:other-views))])
    (cond
      [(or (not in-layout) (%other-view? in-layout))
       (%check! 'reference-scroll (%node-id r) (views:id (layout:other-view-for-scrolling)))
       (for-each
         (lambda (id)
           (let ([a (%find-atom tree id)])
             (when (and a (not (%other-view? a)))
               (%check! (list 'reference-level id) #t (%within? a (%level-of r))))))
         others)]
      [(%locked? in-layout)
       (when (and (not (eqv? (%node-id r) s)) (memv (%node-id r) (map views:id (layout:views))))
         (%check! 'reference-first (%node-id r) (and (pair? others) (car others))))])))

(define (%check-nested-levels!)
  (let* ([tree (%layout)] [s (%find-atom tree (%selected-id))])
    (when (and s (not (%locked? s)) (not (%other-view? s)) (not (layout:zoomed-view)))
      (let* ([shown (map views:id (layout:views))] [others (map views:id (layout:other-views))] [l (%level-of s)])
        (for-each
          (lambda (m)
            (when (and (eq? (%level-of m) l)
                       (exists (lambda (w) (and (memv (%node-id w) shown) (not (%locked? w)) (not (%placed-below? w m))))
                               (%atoms m)))
              (%check! (list 'nested-level-in-other-views (%ids m)) #t
                       (exists (lambda (id) (and (memv id (%ids m)) #t)) others))))
          (filter %level? (let all ([n (car (%node-kids l))]) (if (eq? (%node-kind n) 'view) '() (cons n (apply append (map all (%node-kids n))))))))))))

(define (%check-stacking! client)
  (let ([s (html->string (layout:screen client))])
    (define (search sub from)
      (let loop ([i from])
        (cond
          [(> (+ i (string-length sub)) (string-length s)) #f]
          [(string=? (substring s i (+ i (string-length sub))) sub) i]
          [else (loop (+ i 1))])))
    (define (z-of style)
      (let ([key "--layout-float-z:"])
        (and style
             (let find-key ([i 0])
               (cond
                 [(> (+ i (string-length key)) (string-length style)) #f]
                 [(string=? (substring style i (+ i (string-length key))) key)
                  (let* ([k (+ i (string-length key))]
                         [e (let next ([e k]) (if (and (< e (string-length style)) (char-numeric? (string-ref style e))) (next (+ e 1)) e))])
                    (string->number (substring style k e)))]
                 [else (find-key (+ i 1))])))))
    (define (class-has? class word)
      (and class (member word (let split ([cs (string->list class)] [w '()] [acc '()])
                                (cond
                                  [(null? cs) (reverse (if (null? w) acc (cons (list->string (reverse w)) acc)))]
                                  [(char=? (car cs) #\space) (split (cdr cs) '() (if (null? w) acc (cons (list->string (reverse w)) acc)))]
                                  [else (split (cdr cs) (cons (car cs) w) acc)])))
           #t))
    (let loop ([i 0] [stack (list (vector #f #f #f '()))])
      (let ([open (search "<div" i)] [close (search "</div>" i)])
        (cond
          [(and open (or (not close) (< open close)))
           (let* ([end (search ">" open)]
                  [class (let ([i (search "class=\"" open)]) (and i (< i end) (substring s (+ i 7) (search "\"" (+ i 7)))))]
                  [style (let ([i (search "style=\"" open)]) (and i (< i end) (substring s (+ i 7) (search "\"" (+ i 7)))))]
                  [selected? (and (class-has? class "layout-view") (class-has? class "selected"))])
             (when selected? (for-each (lambda (f) (vector-set! f 2 #t)) stack))
             (loop (+ end 1) (cons (vector class (z-of style) selected? '()) stack)))]
          [close
           (let ([f (car stack)] [parent (cadr stack)])
             (when (class-has? (vector-ref f 0) "float")
               (let* ([children (filter (lambda (c) (class-has? (vector-ref c 0) "float-child")) (vector-ref f 3))]
                      [top (find (lambda (c) (vector-ref c 2)) children)])
                 (when (and top (vector-ref top 1))
                   (%check! 'stacking #t
                            (for-all (lambda (c) (or (eq? c top) (not (vector-ref c 1)) (< (vector-ref c 1) (vector-ref top 1)))) children)))))
             (vector-set! parent 3 (cons f (vector-ref parent 3)))
             (loop (+ close 6) (cdr stack)))]
          [else (void)])))))

(define (%raises? thunk) (guard (c [(not (cancelled? c)) #t]) (thunk) #f))

(define (%op-delete! client)
  (let ([n (%pick-one (%nodes layout:buffer))] [before (%before)])
    (when n
      (unless (%raises? (lambda () (layout:delete-part! n)))
        (%check-edit! 'delete-part before)))))

(define (%op-delete-view! client)
  (let ([before (%before)])
    (if (%command! client layout:delete-view)
        (%check! '(C-x-0 unchanged) (caddr before) (%order-ids))
        (%check-edit! 'C-x-0 before))))

(define (%op-close-popup! client)
  (let ([n (%pick-one (filter document:atom? (%nodes layout:popups-buffer)))] [before (%before)])
    (when n
      (unless (%raises? (lambda () (layout:delete-part! n)))
        (%check-edit! 'close-popup before)))))

(define (%op-attribute! client)
  (let* ([n (%pick-one (%nodes layout:buffer))] [before (%before)]
         [key (if (fxzero? (random 2)) 'locked 'other-view)])
    (when (and n (or (eq? key 'other-view) (%unlocked-outside? n)))
      (unless (%raises? (lambda () (layout:set-part-attribute! n key #t)))
        (%check-edit! 'attribute before)))))

;; Saved data refuses a layout with no view that is not locked.
(define (%unlocked-outside? n)
  (let ([s (document:node-start n)] [e (document:node-end n)])
    (exists (lambda (m)
              (and (document:atom? m) (not (and (fx<= s (document:node-start m)) (fx<= (document:node-end m) e)))
                   (not (layout:locked? m))))
            (%nodes layout:buffer))))

(define (%op-select! client)
  (let ([v (%pick-one (%all-views))])
    (when v
      (layout:select! v)
      (%check! 'select (views:id v) (%selected-id)))))

(define (%op-deselect! client)
  (let* ([v (layout:selected-view)] [order (%order-ids)] [tree (%layout)] [r (%reference tree order)])
    (layout:deselect! v)
    (let ([expected (cond
                      [(not r) order]
                      [(eqv? (%node-id r) (views:id v))
                       (let ([s (%successor tree tree (views:id v) order)])
                         (if s (%with-first (%node-id s) order) order))]
                      [else (%with-first (%node-id r) order)])])
      (%check! 'deselect expected (%order-ids)))))

(define (%node-ids n)
  (let ([s (document:node-start n)] [e (document:node-end n)])
    (filter values (map (lambda (m) (and (document:atom? m) (fx<= s (document:node-start m)) (fx<= (document:node-end m) e)
                                         (document:node-attribute m 'view #f)))
                        (%nodes layout:buffer)))))

(define (%op-part-view! client)
  (let ([n (%pick-one (%nodes layout:buffer))])
    (when n
      (let ([atoms (filter (lambda (a) (memv (%node-id a) (%node-ids n))) (%atoms (%layout)))])
        (%check! 'part-view (%node-id (%mru atoms (%order-ids))) (views:id (layout:part-view n)))))))

(define (%click! client node button)
  (let ([s layout:screen-view])
    (for-each
      (lambda (action)
        (parameterize ([web:current-client client])
          ((tables:ref web:input-handlers "mouse") client
           `(("token" . ,(document:node-start node)) ("type" . "mouse") ("action" . ,action) ("button" . ,button)
             ("clicks" . 1) ("modifiers" . #()) ("view" . ,(views:id s)) ("version" . ,(buffers:version layout:buffer))
             ("showing" . ,(views:shown-count s))
             ,@(if (= button 3) `(("keymaps" . ,(vector (%mark-number status-line:keymap)))) '())))))
      '("down" "click"))))

(define (%mark-number keymap) (read (open-input-string (views:keymap-mark keymap))))

(define (%op-click! client)
  (let ([n (%pick-one (%nodes layout:buffer))] [before (%before)])
    (when n
      (%refused? (lambda () (%click! client n 1)))
      (let* ([atoms (filter (lambda (a) (memv (%node-id a) (%node-ids n))) (%atoms (car before)))]
             [m (%mru atoms (caddr before))])
        (%check! 'click (if (and m (not (%locked? m))) (%node-id m) (car (caddr before))) (%selected-id))))))

(define (%op-mouse-3! client)
  (let ([v (%pick-one (layout:views))])
    (when (and v (not (layout:locked? (layout:view-node v))))
      (layout:select! v)
      (let ([before (%before)])
        (%refused? (lambda () (%click! client (layout:view-node v) 3)))
        (%check-edit! 'mouse-3 before)))))

(define (%op-reach! client)
  (let ([before (%before)] [command (%pick-one (list layout:select-left layout:select-right layout:select-up layout:select-down
                                                     layout-tabs:next-tab layout-tabs:previous-tab layout-tabs:recent-tab
                                                     layout-scroll:first layout-scroll:last))])
    (%command! client command)
    (%check-part-reach! 'reach before)))

(define (%op-cycle! client)
  (let* ([tree (%layout)] [order (%order-ids)] [a (%find-atom tree (%selected-id))]
         [f (and a (find %float? (%ancestors a)))]
         [expected
          (if f
              (let* ([child (let up ([n a]) (if (eq? (%node-parent n) f) n (up (%node-parent n))))]
                     [base (find (lambda (c) (not (%attribute? c 'place))) (%node-kids f))]
                     [others (filter (lambda (c) (if (eq? child base) (not (eq? c base)) (eq? c base))) (%node-kids f))]
                     [m (exists (lambda (c) (let ([m (%mru (%atoms c) order)]) (and m (not (%locked? m)) m)))
                                (%floats-by-use others order))])
                (if m (%node-id m) (%selected-id)))
              (%selected-id))])
    (%command! client layout-float:cycle)
    (%check! 'cycle expected (%selected-id))
    (%check-stacking! client)))

(define (%op-zoom! client)
  (let* ([v (layout:selected-view)] [n (layout:view-node v)] [zoomed? (and (layout:zoomed-view) #t)]
         [raised? (%raises? (lambda () (%run client (lambda () (layout:zoom #f)))))])
    (when (and n (layout:locked? n) (not zoomed?))
      (%check! 'zoom-locked-raises #t raised?))
    (when (and (layout:zoomed-view) (layout:view-node (layout:selected-view)))
      (%check! 'zoom-shows-selected #t (and (memq (layout:selected-view) (layout:views)) #t)))))

(define (%op-reset! client)
  (let* ([tree (%layout)] [order (%order-ids)] [r (%reference tree order)]
         [inside (%ids (%level-of r))] [before (%ids tree)])
    (unless (%command! client layout:reset-layout)
      (let* ([after (%ids (%layout))] [gone (remp (lambda (id) (memv id after)) before)])
        (%check! 'reset-in-level '() (remp (lambda (id) (memv id inside)) gone))
        (%check! 'reset-selects (%node-id r) (%selected-id))))))

(define (%op-display! client)
  (let* ([b (%fresh-buffer)] [before (%before)])
    (unless (%raises? (lambda () (%run client (lambda () (layout:display-buffer b)))))
      (%check-order! 'display before))))

(define (%op-use-other-view! client)
  (let* ([b (%fresh-buffer)] [tree (%layout)] [s (%find-atom tree (%selected-id))])
    (when (or (not s) (%locked? s) (%other-view? s))
      (let ([r (%reference tree (%order-ids))] [v (%run client (lambda () (layout:use-other-view b)))])
        (when v
          (let ([after (%layout)])
            (%check! 'use-other-view-level #t
                     (%within? (%find-atom after (views:id v)) (%level-of (%find-atom after (%node-id r)))))))))))

(define (%op-other-view-prefix! client)
  (let ([b (%fresh-buffer)])
    (unless (%refused? (lambda ()
                         (%run client (lambda ()
                                        (layout:call-with-overriding-action layout:display-in-other-view
                                          (lambda () (layout:switch-to-buffer b)))))))
      (%check! 'other-view-prefix b (views:buffer (layout:selected-view))))))

(define (%op-other-view! client)
  (let ([others (map views:id (layout:other-views))])
    (%command! client layout:other-view)
    (when (pair? others) (%check! 'C-x-o (car others) (%selected-id)))))

;; recent-views' delay is set long so a seed does not depend on timing, so
;; no view ticks: this checks only that s-o stays among the other views;
;; its ranking is prompts.transcript's.
(define (%op-recent! client)
  (let ([others (map views:id (layout:other-views))] [old (%selected-id)])
    (%command! client recent-views:select-recent-view)
    (%check! 's-o #t (and (memv (%selected-id) (cons old others)) #t))))

(define (%op-quit! client)
  (let ([before (%before)])
    (unless (%command! client layout:quit-view)
      (%check-order! 'quit before))))

(define (%op-kill-and-delete! client)
  (let ([before (%before)])
    (unless (%command! client layout:kill-buffer-and-view)
      (%check-edit! 'C-x-4-0 before))))

(define (%op-history! client)
  (let ([before (%before)])
    (%command! client (if (fxzero? (random 2)) layout:history-back layout:history-forward))
    (%check-not-locked! 'history before)))

(define (%op-part-mode! client)
  (let ([before (%before)])
    (%command! client layout:part-mode)
    (do ([k (random 3) (fx- k 1)]) ((fxzero? k)) (%command! client layout:select-parent))
    (%command! client (if (fxzero? (random 2)) layout:delete-view layout:raise))
    (%command! client layout:part-mode-leave)
    (%check-not-locked! 'part-mode before)))

(define (%op-prompt! client)
  (if (minibuffer:current-prompt)
      (let* ([p (minibuffer:current-prompt)] [selected? (eq? (layout:selected-view) (minibuffer:prompt-view p))]
             [back (minibuffer:prompt-selected-view p)])
        (%run client minibuffer:abort)
        (let loop () (when (eq? (minibuffer:current-prompt) p) (timers:sleep 0.01) (loop)))
        (when selected?
          (if back
              (%check! 'prompt-back (views:id back) (%selected-id))
              (%check! 'prompt-reference (%node-id (%reference (%layout) (%order-ids))) (%selected-id)))))
      (let ([t (spawn-task (lambda (restore) (guard (c [(cancelled? c) #f]) (%run client (lambda () (minibuffer:read "Q: "))))))])
        (let loop () (unless (or (minibuffer:current-prompt) (eq? (task-state t) 'done)) (timers:sleep 0.01) (loop))))))

(define %ops
  (list (cons 'delete %op-delete!) (cons 'delete %op-delete!) (cons 'C-x-0 %op-delete-view!) (cons 'close-popup %op-close-popup!)
        (cons 'attribute %op-attribute!) (cons 'select %op-select!) (cons 'select %op-select!) (cons 'deselect %op-deselect!)
        (cons 'part-view %op-part-view!) (cons 'click %op-click!) (cons 'mouse-3 %op-mouse-3!) (cons 'reach %op-reach!)
        (cons 'reach %op-reach!) (cons 'cycle %op-cycle!) (cons 'zoom %op-zoom!) (cons 'reset %op-reset!)
        (cons 'display %op-display!) (cons 'use-other-view %op-use-other-view!) (cons 'C-x-4-4 %op-other-view-prefix!)
        (cons 'C-x-o %op-other-view!) (cons 's-o %op-recent!) (cons 'q %op-quit!) (cons 'C-x-4-0 %op-kill-and-delete!)
        (cons 'history %op-history!) (cons 'part-mode %op-part-mode!) (cons 'prompt %op-prompt!) (cons 'prompt %op-prompt!)))

(define (%case! client make picks)
  (%end-prompts! client)
  (%close-popups!)
  (let* ([views (map (lambda (k) (%fresh-view)) (iota 6))] [v (lambda (k) (list-ref views k))])
    (%set-root! (make (lambda (k . marks) (%view-datum (v k) marks))))
    (for-each (lambda (k) (layout:select! (v k))) picks)
    (%op-delete-view! client)))

;; Trees the random ones rarely make: tabs inside tabs, nested levels, a
;; placed part beside the user's level, a tab kept, a level dissolved.
(define (%cases! client)
  (set! %where '(cases))
  (let ([split (lambda (dir . parts) (apply layout-split:container (list (cons 'direction dir)) parts))])
    (%case! client (lambda (v) (layout-tabs:container '() (layout-tabs:container '() (v 0) (split 'row (v 1) (v 2))))) '(0 2 1))
    (%case! client (lambda (v) (layout-tabs:container '() (v 3) (layout-tabs:container '() (v 0) (split 'row (v 1) (v 2))))) '(0 2 1))
    (%case! client (lambda (v) (layout-tabs:container '() (layout-tabs:container '() (split 'row (v 1) (v 2)) (v 0)))) '(0 2 1))
    (%case! client (lambda (v) (layout-tabs:container '() (layout-tabs:container '() (layout-tabs:container '() (v 0)) (v 1) (v 2)))) '(2 1))
    (%case! client (lambda (v) (layout-tabs:container '() (layout-tabs:container '() (v 0) (v 1) (v 2)))) '(2 1))
    (%case! client (lambda (v) (split 'row (v 3) (layout:level '((depth . 50)) (layout-tabs:container '() (layout-tabs:container '() (layout-tabs:container '() (v 0)) (v 1) (v 2)))))) '(3 2 1))
    (%case! client (lambda (v) (split 'row (v 3) (layout:level '() (split 'column (v 0 '(depth . 50)) (v 1))) (v 2))) '(1 0 2))
    (%case! client (lambda (v) (split 'row (v 0) (layout:level '() (split 'column (v 1) (v 2))))) '(0 2 1))
    (%case! client (lambda (v) (split 'row (v 0) (layout:level '() (split 'column (v 1) (v 2))))) '(2 0 1))
    (%case! client (lambda (v) (split 'row (v 3 '(depth . 50)) (layout:level '() (split 'row (v 0) (v 1))))) '(3 0))
    (%case! client (lambda (v) (layout-tabs:container '() (split 'row (v 0) (v 1)) (v 2))) '(1 2 0))
    (%case! client (lambda (v) (split 'row (v 3) (layout:level '() (split 'column (v 0) (layout:level '() (v 1)))))) '(1 3 0))))

(define (run client seed layouts steps)
  (random-seed seed)
  (set! %checks 0)
  (set! %failures 0)
  (%cases! client)
  (do ([l 0 (fx+ l 1)]) ((fx= l layouts))
    (%build! client)
    (do ([s 0 (fx+ s 1)]) ((fx= s steps))
      (let ([op (%pick-one %ops)])
        (set! %where (list seed l s (car op)))
        (guard (c [(not (cancelled? c))
                   (%fail! "~s: raised ~s ~a ~s\n" %where (and (who-condition? c) (condition-who c))
                           (if (message-condition? c) (condition-message c) c) (and (irritants-condition? c) (condition-irritants c)))])
          ((cdr op) client)
          (%check-live!)
          (%check-reference!)
          (%check-nested-levels!)))))
  (%end-prompts! client)
  (list %checks %failures))

(advice-add! report %hush)

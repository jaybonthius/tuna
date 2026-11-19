#!tuna
(import (buffers) (document) (views) (keys) (commands) (web) (haml))

;; This module defines list as a kind constructor, so its own code builds
;; lists with cons and quasiquote.

(define-table %buttons)

(define-table list-keys "Keys that move through a list and choose its row.")

(define-table disabled-keys "Keys that do nothing on a disabled button or link.")

(module %internals
  (draw-labelled button-at disabled? list-node? row-atom? list-state set-list-state! add-list-rows! rows-vector rows-count
   rows-draw rows-choose rows-shown
   rows-failed? rows-failed?-set! selected-index index-position window-start window-for write-window! list-at
   current-drawing drawing-rows drawing-selected with-drawing place posn-or-point forget-buffer!)

  (define (disabled? node) (and (document:node-attribute node 'disabled #f) #t))

  ;; Not the disabled attribute, with which the browser drops the press
  ;; and release of the mouse on the button, so a drag that ends there
  ;; would end only at the next move.
  (define (draw-labelled class node view)
    (haml (:button ([class class] [type "button"] [tabindex "-1"] [aria-disabled (and (disabled? node) "true")])
            (views:draw-children view node))))

  (define (button-at v p)
    (let ([b (views:buffer v)])
      (and b
           (let ([doc (buffers:document b)])
             (and (fx<= p (document:length doc))
                  (let loop ([n (document:enclosing doc p)])
                    (cond
                      [(not n) #f]
                      [(table-ref %buttons (document:node-kind n) #f) n]
                      [else (loop (document:enclosing doc (document:node-start n)))])))))))

  (define (list-node? n)
    (and n (not (document:atom? n)) (eq? (document:node-kind n) %list-kind)))

  (define (row-atom? t)
    (and (document:node? t) (document:atom? t) (eq? (document:node-kind t) %row-kind)))

  ;; A list's rows from one vector carry one generation in their keys, so
  ;; a click on a row drawn from an earlier vector finds its atom gone and
  ;; is stale, rather than choosing whatever row took its index. A list
  ;; whose draw or choose procedure raised stays failed until its rows are
  ;; set again, so a procedure whose module is gone is not called, and its
  ;; error not reported, on every draw. Rows added go into a vector of the
  ;; list's own, owned?, never into the one its maker set, which the maker
  ;; may still hold.
  (define-record-type rows
    (sealed #t)
    (fields (mutable vector) (mutable count) (mutable owned?) (mutable draw) (mutable choose) (mutable shown)
            (mutable generation) (mutable failed?)))

  ;; Only an anchor right after a node's opening reports the node's deletion.
  (define lists (make-eq-hashtable))

  (define (entries-of b)
    (let ([live (filter (lambda (e) (not (buffers:anchor-deleted? (car e)))) (eq-hashtable-ref lists b '()))])
      (eq-hashtable-set! lists b live)
      live))

  (define (list-state b node)
    (let ([at (fx+ (document:node-start node) 1)])
      (let loop ([es (entries-of b)])
        (cond
          [(null? es) #f]
          [(fx= (buffers:anchor-position (caar es)) at) (cdar es)]
          [else (loop (cdr es))]))))

  (define (first-key doc node)
    (and (fx> (fx- (document:node-end node) (document:node-start node)) 2)
         (let ([t (document:token doc (fx+ (document:node-start node) 1))])
           (and (row-atom? t)
                (let ([key (document:node-attribute t 'key)])
                  (and (pair? key) (fixnum? (car key)) (fixnum? (cdr key)) key))))))

  ;; A list met afresh, as after this module reloads, may hold rows a
  ;; previous instance wrote, so its first generation is past theirs.
  (define (set-list-state! b node vector draw choose shown)
    (let ([state (list-state b node)])
      (if state
          (begin
            (unless (eq? vector (rows-vector state))
              (rows-generation-set! state (fx+ (rows-generation state) 1)))
            (rows-vector-set! state vector)
            (rows-count-set! state (vector-length vector))
            (rows-owned?-set! state #f)
            (rows-draw-set! state draw)
            (rows-choose-set! state choose)
            (rows-shown-set! state shown)
            (rows-failed?-set! state #f)
            state)
          (let* ([key (first-key (buffers:document b) node)]
                 [state (make-rows vector (vector-length vector) #f draw choose shown (if key (fx+ (car key) 1) 0) #f)])
            (eq-hashtable-set! lists b
              (cons (cons (buffers:anchor b (fx+ (document:node-start node) 1)) state) (entries-of b)))
            state))))

  (define (add-list-rows! state rows)
    (let* ([n (rows-count state)] [k (vector-length rows)] [m (fx+ n k)] [v (rows-vector state)]
           [v (if (and (rows-owned? state) (fx<= m (vector-length v)))
                  v
                  (let ([w (make-vector (fxmax m (fx* 2 n)))])
                    (vector-copy! v 0 w 0 n)
                    w))])
      (vector-copy! rows 0 v n k)
      (rows-vector-set! state v)
      (rows-count-set! state m)
      (rows-owned?-set! state #t)))

  (define (forget-buffer! b) (eq-hashtable-delete! lists b))

  ;; The row at a point after the last row is the last row, so a list
  ;; whose rows shrink keeps a row selected.
  (define (selected-index doc node p)
    (let ([s (document:node-start node)] [e (document:node-end node)])
      (and (fx< s p e)
           (let ([t (document:token doc (if (fx= p (fx- e 1)) (fx- p 1) p))])
             (and (row-atom? t)
                  (let ([key (document:node-attribute t 'key)])
                    (and (pair? key) (cdr key))))))))

  ;; The rows a list holds are consecutive indexes, from its first row's.
  (define (window doc node)
    (let ([key (first-key doc node)])
      (if key
          (values (cdr key) (fx- (fx- (document:node-end node) (document:node-start node)) 2))
          (values 0 0))))

  (define (window-start doc node)
    (let ([key (first-key doc node)]) (if key (cdr key) 0)))

  (define (generation-of doc node)
    (let ([key (first-key doc node)]) (and key (car key))))

  (define (window-for i first count shown)
    (let ([first (cond
                   [(not i) first]
                   [(fx< i first) i]
                   [(fx>= i (fx+ first shown)) (fx- i (fx- shown 1))]
                   [else first])])
      (fxmax 0 (fxmin first (fx- count shown)))))

  (define (index-position node first n i)
    (fx+ (document:node-start node) 1 (if (fx= n 0) 0 (fx- (fxmax first (fxmin i (fx+ first n -1))) first))))

  (define (row-datums generation first n)
    (let loop ([i (fx+ first n -1)] [acc '()])
      (if (fx< i first) acc (loop (fx- i 1) (cons (%list-row `((key . (,generation . ,i)))) acc)))))

  ;; Each view selecting a row of the list keeps its index, or the nearest
  ;; one the new window shows, rather than wherever the rows it was on
  ;; went. Rows of a new generation keep none of the old, so one splice
  ;; writes them, at a quarter of the cost of reconciling.
  (define (write-window! b node state first n)
    (let*-values ([(doc) (buffers:document b)] [(first0 n0) (window doc node)]
                  [(same-generation?) (eqv? (generation-of doc node) (rows-generation state))])
      (unless (and same-generation? (fx= first first0) (fx= n n0))
        (let ([selections (fold-left
                            (lambda (acc v)
                              (let ([i (selected-index doc node (views:point v))])
                                (if i (cons (cons v i) acc) acc)))
                            '() (views:showing b))]
              [s (document:node-start node)])
          (if same-generation?
              (buffers:reconcile! b node (row-datums (rows-generation state) first n))
              (buffers:splice! b (fx+ s 1) (fx- (document:node-end node) 1)
                (apply document:from-datum (row-datums (rows-generation state) first n))))
          (let ([node (document:token (buffers:document b) s)])
            (for-each (lambda (sel) (views:set-point! (car sel) (index-position node first n (cdr sel))))
                      selections))))))

  (define (list-at v)
    (let ([b (views:buffer v)])
      (and b
           (let ([doc (buffers:document b)])
             (let loop ([n (document:enclosing doc (views:point v))])
               (cond
                 [(not n) #f]
                 [(list-node? n) n]
                 [else (loop (document:enclosing doc (document:node-start n)))]))))))

  (define-record-type drawing
    (sealed #t)
    (fields rows selected))

  (define current-drawing (make-thread-parameter #f))

  (define (with-drawing node view thunk)
    (let* ([b (views:buffer view)] [doc (buffers:document b)])
      (parameterize ([current-drawing (make-drawing (list-state b node) (selected-index doc node (views:point view)))])
        (thunk))))

  (define (place posn)
    (if posn
        (values (views:posn-view posn) (views:posn-point posn))
        (let ([v (views:current)]) (values v (and v (views:buffer v) (views:point v))))))

  (define (posn-or-point)
    (let ([e (keys:command-event)])
      (place (and (keys:event? e) (keys:event-start e))))))

(import %internals)

(define (%draw-button node view) (draw-labelled "ui-button" node view))

(define (%draw-link node view) (draw-labelled "ui-link" node view))

(define (%bind-button! who keymap kind command)
  (unless (commands:command? command)
    (assertion-violation who "not a command" command))
  (keys:bind! keymap "<mouse-1>" command)
  (keys:bind! keymap "<mouse-2>" command)
  (keys:bind! keymap "RET" command)
  (keys:bind! keymap "<down-mouse-1>" keys:ignore)
  (keys:bind! keymap "<drag-mouse-1>" keys:ignore)
  (keys:bind! keymap "<drag-mouse-2>" keys:ignore)
  (table-set! %buttons kind))

(define-syntax %define-labelled-kind
  (lambda (x)
    (syntax-case x ()
      [(_ who id command-expr drawer)
       (with-syntax ([id-keys (datum->syntax #'id (string->symbol (string-append (symbol->string (syntax->datum #'id)) "-keys")))])
         #'(begin
             (define-table id-keys "The keys of a button kind.")
             (buffers:define-kind id (inline) (draw drawer) (keymap id-keys))
             (define-values () (begin (%bind-button! 'who id-keys (buffers:kind-name (buffers:constructor-kind id)) command-expr) (values)))))])))

(define-syntax define-button
  (lambda (x)
    (syntax-case x ()
      [(_ id command-expr)
       (identifier? #'id)
       #'(%define-labelled-kind ui:define-button id command-expr %draw-button)]
      [_ (syntax-violation 'ui:define-button "expected (ui:define-button id command)" x)])))

(define-syntax define-link
  (lambda (x)
    (syntax-case x ()
      [(_ id command-expr)
       (identifier? #'id)
       #'(%define-labelled-kind ui:define-link id command-expr %draw-link)]
      [_ (syntax-violation 'ui:define-link "expected (ui:define-link id command)" x)])))

(define (pushed-button)
  (let-values ([(v p) (posn-or-point)])
    (or (and v p (button-at v p))
        (assertion-violation 'ui:pushed-button "no button is at the click or at point"))))

(define (%disabled-keymaps client posn)
  (let-values ([(v p) (place posn)])
    (let ([button (and v p (button-at v p))])
      (if (and button (disabled? button)) (cons disabled-keys '()) '()))))

(define label
  (case-lambda
    [(text) (label text "")]
    [(text class)
     (unless (string? text)
       (assertion-violation 'ui:label "not a string" text))
     (unless (string? class)
       (assertion-violation 'ui:label "not a string" class))
     (haml (:span.ui-label ([class (and (not (string=? class "")) class)]) text))]))

(define (row . items)
  (for-each (lambda (item) (unless (html? item) (assertion-violation 'ui:row "not HTML" item))) items)
  (haml (:div.ui-row items)))

(define (%warning-only? c)
  (and (warning? c) (not (serious-condition? c))))

(define (%failure? c)
  (not (or (quit-condition? c) (%warning-only? c))))

;; Rows drawn before one that raised are drawn again, as nothing, so the
;; list is drawn empty from the draw that failed.
(define (%draw-list node view)
  (with-drawing node view
    (lambda ()
      (let* ([state (drawing-rows (current-drawing))] [failed? (and state (rows-failed? state))]
             [html (haml (:ul.ui-list (views:draw-children view node)))])
        (if (and state (not failed?) (rows-failed? state))
            (haml (:ul.ui-list (views:draw-children view node)))
            html)))))

(define (%draw-list-row node view)
  (let* ([d (current-drawing)] [state (and d (drawing-rows d))] [key (document:node-attribute node 'key)]
         [i (and (pair? key) (cdr key))])
    (if (and state (not (rows-failed? state)) (fixnum? i) (fx< i (rows-count state)))
        (guard (c [(%failure? c) (rows-failed?-set! state #t) (report c) '()])
          (haml (:li.ui-list-row ([aria-current (and (eqv? i (drawing-selected d)) "true")])
                  ((rows-draw state) (vector-ref (rows-vector state) i)))))
        '())))

;; Rows go only when ui writes them, which asks no kind. Text, which the
;; list's content refuses anyway, is consented to: refusing it would also
;; refuse the probe that makes the place before a row a stop, and point
;; could not rest on the first row of a list inside other text.
(define (%keep-rows node edit)
  (and (fx= (document:length (buffers:edit-removed edit)) 0)
       (let ([inserted (buffers:edit-inserted edit)])
         (let loop ([p 0])
           (or (fx= p (document:length inserted))
               (and (char? (document:token inserted p)) (loop (fx+ p 1))))))))

(buffers:define-kind list (content nodes) (consent %keep-rows) (keymap list-keys) (draw %draw-list))

(buffers:define-kind %list-row (content atom) (draw %draw-list-row))

(define %list-kind (buffers:kind-name (buffers:constructor-kind list)))

(define %row-kind (buffers:kind-name (buffers:constructor-kind %list-row)))

(define (%check-list who b node)
  (let ([current (and (document:node? node)
                      (let ([doc (buffers:document b)] [s (document:node-start node)])
                        (and (fx< s (document:length doc)) (document:token doc s))))])
    (unless (and (list-node? current) (fx= (document:node-end current) (document:node-end node)))
      (assertion-violation who "not a list of the buffer" node))
    current))

(define (%check-view who view)
  (unless (views:view? view)
    (assertion-violation who "not a view" view))
  (or (views:buffer view)
      (assertion-violation who "the view shows no buffer" view)))

(define set-rows!
  (case-lambda
    [(buffer node rows draw-row choose) (set-rows! buffer node rows draw-row choose 10)]
    [(buffer node rows draw-row choose shown)
     (unless (buffers:buffer? buffer)
       (assertion-violation 'ui:set-rows! "not a buffer" buffer))
     (unless (vector? rows)
       (assertion-violation 'ui:set-rows! "not a vector" rows))
     (unless (procedure? draw-row)
       (assertion-violation 'ui:set-rows! "not a procedure" draw-row))
     (unless (procedure? choose)
       (assertion-violation 'ui:set-rows! "not a procedure" choose))
     (unless (and (fixnum? shown) (fx> shown 0))
       (assertion-violation 'ui:set-rows! "not a positive count" shown))
     (let ([node (%check-list 'ui:set-rows! buffer node)])
       (%write-rows! buffer node (set-list-state! buffer node rows draw-row choose shown)))]))

(define (%write-rows! buffer node state)
  (let* ([doc (buffers:document buffer)] [count (rows-count state)] [shown (rows-shown state)] [v (views:current)]
         [i (and v (eq? (views:buffer v) buffer) (selected-index doc node (views:point v)))])
    (let ([first (window-for (and i (fxmin i (fx- count 1))) (window-start doc node) count shown)])
      (write-window! buffer node state first (fxmin shown (fx- count first))))))

(define (add-rows! buffer node rows)
  (unless (buffers:buffer? buffer)
    (assertion-violation 'ui:add-rows! "not a buffer" buffer))
  (unless (vector? rows)
    (assertion-violation 'ui:add-rows! "not a vector" rows))
  (let* ([node (%check-list 'ui:add-rows! buffer node)]
         [state (or (list-state buffer node) (assertion-violation 'ui:add-rows! "the list has no rows set" node))])
    (add-list-rows! state rows)
    (%write-rows! buffer node state)))

(define (selected-row node view)
  (let ([b (%check-view 'ui:selected-row view)])
    (selected-index (buffers:document b) (%check-list 'ui:selected-row b node) (views:point view))))

(define (select-row! node view index)
  (let ([b (%check-view 'ui:select-row! view)])
    (unless (and (fixnum? index) (fx>= index 0))
      (assertion-violation 'ui:select-row! "not a row index" index))
    (let* ([node (%check-list 'ui:select-row! b node)] [state (list-state b node)]
           [count (if state (rows-count state) 0)])
      (unless (fx= count 0)
        (let* ([i (fxmin index (fx- count 1))] [shown (rows-shown state)]
               [first (window-for i (window-start (buffers:document b) node) count shown)]
               [n (fxmin shown (fx- count first))])
          (write-window! b node state first n)
          (let ([node (document:token (buffers:document b) (document:node-start node))])
            (views:set-point! view (index-position node first n i))))))))

(define (describe-list node view)
  (let* ([b (%check-view 'ui:describe-list view)] [node (%check-list 'ui:describe-list b node)]
         [state (list-state b node)] [count (if state (vector-length (rows-vector state)) 0)]
         [i (selected-index (buffers:document b) node (views:point view))])
    (and (fx> count 0) i (format "row ~a of ~a" (fx+ (fxmin i (fx- count 1)) 1) count))))

(define (%list-here who)
  (let ([v (views:current)])
    (unless v
      (assertion-violation who "no view is current"))
    (let ([node (list-at v)])
      (unless node
        (assertion-violation who "the cursor is in no list"))
      (values v node))))

(define (%move-row who n)
  (unless (fixnum? n)
    (assertion-violation who "not a count" n))
  (let-values ([(v node) (%list-here who)])
    (let ([i (selected-row node v)])
      (when i (select-row! node v (fxmax 0 (fx+ i n)))))))

(commands:define-command (next-row [n (commands:prefix-number)])
  "Selects the row n after the selected one in the list holding the cursor, stopping at the last."
  (%move-row 'ui:next-row n))

(commands:define-command (previous-row [n (commands:prefix-number)])
  "Selects the row n before the selected one in the list holding the cursor, stopping at the first."
  (%move-row 'ui:previous-row (fx- 0 n)))

(commands:define-command (choose-row)
  "Calls the list's choose procedure with its selected row; run by a click, first selects the row clicked."
  (let-values ([(v p) (posn-or-point)])
    (when (and v p) (views:set-point! v p))
    (let-values ([(v node) (%list-here 'ui:choose-row)])
      (let ([state (list-state (views:buffer v) node)] [i (selected-row node v)])
        (when (and state (not (rows-failed? state)) i (fx< i (rows-count state)))
          (with-exception-handler
            (lambda (c)
              (when (%failure? c) (rows-failed?-set! state #t))
              (raise-continuable c))
            (lambda () ((rows-choose state) (vector-ref (rows-vector state) i)))))))))

(define (%draw-showcase node view)
  (haml (:article (views:draw-children view node))))

(define (%draw-showcase-heading node view)
  (haml (:div.ui-showcase-heading (views:draw-children view node))))

;; Hover and pressed last only while the pointer is on a real button or
;; link, so a sample holds one.
(define (%draw-state-sample node view)
  (let ([state (document:node-attribute node 'state)])
    (haml (:button ([class (if (eq? (document:node-attribute node 'of) 'link) "ui-link" "ui-button")]
                    [type "button"] [tabindex "-1"]
                    [data-ui-state (symbol->string state)])
            (document:node-attribute node 'label)))))

(define (%draw-helper-sample node view)
  (case (document:node-attribute node 'of)
    [(label) (label "A label")]
    [(label-class) (label "A label with a class" "ui-showcase-muted")]
    [(row) (row (label "notes.org") (label "~/notes" "ui-showcase-muted") (label "2 KB" "ui-showcase-faint"))]))

(define (%draw-chosen node view)
  (label (document:node-attribute node 'name "nothing yet")))

(buffers:define-kind %showcase (content nodes) (draw %draw-showcase))
(buffers:define-kind %showcase-heading (draw %draw-showcase-heading))
(buffers:define-kind %showcase-text)
(buffers:define-kind %state-sample (content atom) (draw %draw-state-sample))
(buffers:define-kind %helper-sample (content atom) (draw %draw-helper-sample))
(buffers:define-kind %chosen (content atom) (draw %draw-chosen))
(buffers:define-layer %read-only (read-only))

(define %showcase-kind (buffers:kind-name (buffers:constructor-kind %showcase)))
(define %chosen-kind (buffers:kind-name (buffers:constructor-kind %chosen)))

(define (%times verb n)
  (string-append verb " " (number->string n) (if (= n 1) " time" " times")))

;; The count lives in the button's attributes, so it outlives a reload of
;; this module as the buffer does.
(commands:define-command (%count-push [button (pushed-button)])
  "Counts a push of a showcase button or link in its label."
  (let ([n (+ (document:node-attribute button 'n 0) 1)] [verb (document:node-attribute button 'verb)])
    (buffers:splice! (buffers:current) (document:node-start button) (document:node-end button)
      (document:from-datum `(,(document:node-kind button) ((n . ,n) (verb . ,verb)) ,(%times verb n))))))

(define-button %sample-button %count-push)

(define-link %sample-link %count-push)

(define %short-rows
  '#(("init.ss" . "configuration") ("notes.org" . "outline") ("todo.txt" . "text") ("ui.sls" . "plugin")
     ("ui.css" . "stylesheet") ("README.md" . "markdown") ("Makefile" . "build") ("build.ss" . "scheme")))

(define %long-rows
  (let ([v (make-vector 300)])
    (do ([i 0 (fx+ i 1)]) ((fx= i 300) v)
      (vector-set! v i (cons (string-append "Row " (number->string (fx+ i 1)))
                             (string-append (number->string (fx+ i 1)) " of 300"))))))

(define (%draw-showcase-row r)
  (row (label (car r)) (label (cdr r) "ui-showcase-muted")))

(define (%showcase-node b match?)
  (call/1cc
    (lambda (k)
      (let walk ([n (document:token (buffers:document b) 0)])
        (document:for-each-child n 0 (document:length (buffers:document b))
          (lambda (child at)
            (when (document:node? child)
              (when (match? child) (k child))
              (unless (document:atom? child) (walk child))))))
      #f)))

(define (%showcase-list b rows)
  (%showcase-node b (lambda (n) (and (list-node? n) (eq? (document:node-attribute n 'rows) rows)))))

(define (%show-chosen! b r)
  (let ([chosen (%showcase-node b (lambda (n) (eq? (document:node-kind n) %chosen-kind)))])
    (buffers:splice! b (document:node-start chosen) (document:node-end chosen)
      (document:from-datum (%chosen `((name . ,(car r))))))))

(define (%fill-showcase! b)
  (let ([choose (lambda (r) (%show-chosen! b r))])
    (set-rows! b (%showcase-list b 'short) %short-rows %draw-showcase-row choose 5)
    (set-rows! b (%showcase-list b 'long) %long-rows %draw-showcase-row choose (vector-length %long-rows))))

(define (%showcase-datum)
  (%showcase '()
    (%showcase-text '()
      "Every component and helper of the ui plugin, in each of its states.\n"
      "The buffer is read-only.\n\n")
    (%showcase-heading '() "Buttons: ui:define-button\n")
    (%showcase-text '()
      "normal    " (%sample-button '((n . 0) (verb . "Pushed")) "Push me") "  a click or RET counts\n"
      "hover     " (%state-sample '((of . button) (state . hover) (label . "Push me"))) "\n"
      "pressed   " (%state-sample '((of . button) (state . pressed) (label . "Push me"))) "\n"
      "disabled  " (%sample-button '((n . 0) (verb . "Pushed") (disabled . #t)) "Push me")
      "  a click or RET does nothing\n\n")
    (%showcase-heading '() "Links: ui:define-link\n")
    (%showcase-text '()
      "normal    " (%sample-link '((n . 0) (verb . "Followed")) "Follow me") "  a click or RET counts\n"
      "hover     " (%state-sample '((of . link) (state . hover) (label . "Follow me"))) "\n"
      "disabled  " (%sample-link '((n . 0) (verb . "Followed") (disabled . #t)) "Follow me")
      "  a click or RET does nothing\n\n")
    (%showcase-heading '() "Labels and rows: ui:label, ui:row\n")
    (%showcase-text '()
      "label     " (%helper-sample '((of . label))) "\n"
      "class     " (%helper-sample '((of . label-class))) "\n"
      "A row of three labels, the second muted and the third faint:\n"
      (%helper-sample '((of . row))) "\n")
    (%showcase-heading '() "Lists: ui:list\n")
    (%showcase-text '()
      "C-n and C-p move, RET or a click chooses. Eight rows, five shown:\n"
      "moving past them slides the rows. Each window on this buffer selects\n"
      "its own row; split the window to see a list in a window without focus.\n")
    (list '((rows . short)))
    (%showcase-text '() "chosen    " (%chosen '()) "\n\n")
    (%showcase-text '() "Three hundred rows, all shown, so the window scrolls through them.\n")
    (list '((rows . long)))))

(define (%showcase-buffer)
  (let ([b (buffers:find "*Showcase*")])
    (and b (eq? (document:node-kind (document:token (buffers:document b) 0)) %showcase-kind) b)))

(define (%make-showcase)
  (let ([b (buffers:make "*Showcase*" (%showcase-datum))])
    (buffers:add-span! (buffers:layer b %read-only) 0 (document:length (buffers:document b)) '())
    (%fill-showcase! b)
    (buffers:set-modified! b #f)
    b))

;; Point starts on the first list's first row, so the showcase opens with
;; a selected row and the list's keys active; a view with no measurements
;; would centre that point and hide the buttons above it.
(commands:define-command (showcase)
  "Shows every component and helper of the ui plugin, in each of its states, in the read-only buffer *Showcase*."
  (let ([v (views:current)])
    (unless v
      (assertion-violation 'ui:showcase "no view is current"))
    (let ([b (or (%showcase-buffer) (%make-showcase))])
      (unless (eq? (views:buffer v) b)
        (views:set-buffer! v b)
        (select-row! (%showcase-list b 'short) v 0)
        (views:scroll-to! v 0 (views:align top))))))

(keys:bind! list-keys "C-n" next-row)
(keys:bind! list-keys "<down>" next-row)
(keys:bind! list-keys "C-p" previous-row)
(keys:bind! list-keys "<up>" previous-row)
(keys:bind! list-keys "RET" choose-row)
(keys:bind! list-keys "<mouse-1>" choose-row)
(keys:bind! list-keys "<mouse-2>" choose-row)
(keys:bind! disabled-keys "<mouse-1>" keys:ignore)
(keys:bind! disabled-keys "<mouse-2>" keys:ignore)
(keys:bind! disabled-keys "RET" keys:ignore)
(keys:bind! disabled-keys "<down-mouse-1>" keys:ignore)
(keys:bind! disabled-keys "<drag-mouse-1>" keys:ignore)
(keys:bind! disabled-keys "<drag-mouse-2>" keys:ignore)
;; Ahead of the entries that find the button kind's own keymap.
(add-hook! keys:find-keymaps %disabled-keymaps -10)
(table-set! views:position-describers list describe-list)
(table-set! web:stylesheets 'ui "ui/ui.css")
(add-hook! buffers:killed forget-buffer!)

;; A list's rows are this module's, so a showcase made before a reload
;; gets them again.
(let ([b (%showcase-buffer)])
  (when b (%fill-showcase! b)))

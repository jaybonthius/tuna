#!tuna
(import (buffers) (document) (views) (keys) (commands) (modes) (web) (haml))

;; This module defines list as a kind constructor, so its own code builds
;; lists with cons and quasiquote.

(define-table %buttons)

(define-table list-keys "Keys that move through a list and choose its row.")

(define-table row-keys "Keys on a list's row: a click chooses it.")

(define-table disabled-keys "Keys that do nothing on a disabled button or link.")

(module %internals
  (draw-labelled button-at disabled? list-node? row-atom? list-state set-list-state! rows-count rows-count-set! rows-draw
   rows-choose rows-generation rows-failed? rows-failed?-set! failure? heading-of row-count selected-index index-position
   row-datum list-at drawing-rows drawing-selected drawing-start drawing-last drawing-last-set!
   drawing-last-heading drawing-last-heading-set! current-drawing with-drawing place clicked-posn posn-or-point
   forget-buffer!)

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

  ;; The rows of one call to set-rows! carry one generation, so they
  ;; differ from every earlier call's at the first row, and a click on a
  ;; screen drawn before them is stale rather than choosing whatever row
  ;; took its index. A list whose draw, heading or choose procedure raised
  ;; stays failed until its rows are set again, so a procedure whose
  ;; module is gone is not called, and its error not reported, on every
  ;; draw.
  (define-record-type rows
    (sealed #t)
    (fields (mutable count) (mutable draw) (mutable heading) (mutable choose) (mutable generation) (mutable failed?)))

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

  (define (first-generation doc node)
    (and (fx> (row-count node) 0)
         (let ([t (document:token doc (fx+ (document:node-start node) 1))])
           (and (row-atom? t)
                (let ([g (document:node-attribute t 'generation)])
                  (and (fixnum? g) g))))))

  ;; A list met afresh, as after this module reloads, may hold rows a
  ;; previous instance wrote, so its first generation is past theirs.
  (define (set-list-state! b node count draw heading choose)
    (let ([state (list-state b node)])
      (if state
          (begin
            (rows-count-set! state count)
            (rows-draw-set! state draw)
            (rows-heading-set! state heading)
            (rows-choose-set! state choose)
            (rows-generation-set! state (fx+ (rows-generation state) 1))
            (rows-failed?-set! state #f)
            state)
          (let* ([g (first-generation (buffers:document b) node)]
                 [state (make-rows count draw heading choose (if g (fx+ g 1) 0) #f)])
            (eq-hashtable-set! lists b
              (cons (cons (buffers:anchor b (fx+ (document:node-start node) 1)) state) (entries-of b)))
            state))))

  (define (forget-buffer! b) (eq-hashtable-delete! lists b))

  (define (row-datum generation) (%list-row `((generation . ,generation))))

  (define (row-count node) (fx- (fx- (document:node-end node) (document:node-start node)) 2))

  (define (row-index node p) (fx- p (fx+ (document:node-start node) 1)))

  (define (index-position node i) (fx+ (document:node-start node) 1 i))

  ;; The row at a point after the last row is the last row, so a list
  ;; whose rows shrink keeps a row selected.
  (define (selected-index node p)
    (let ([n (row-count node)])
      (and (fx> n 0) (fx< (document:node-start node) p (document:node-end node))
           (fxmin (row-index node p) (fx- n 1)))))

  (define (warning-only? c)
    (and (warning? c) (not (serious-condition? c))))

  (define (failure? c)
    (not (or (quit-condition? c) (warning-only? c))))

  (define (heading-of state i)
    (and (not (rows-failed? state))
         (guard (c [(failure? c) (rows-failed?-set! state #t) (report c) #f])
           (let ([h ((rows-heading state) i)])
             (unless (or (not h) (string? h))
               (assertion-violation 'ui:set-rows! "a heading procedure returned neither a string nor #f" h))
             h))))

  (define (list-at v p)
    (let ([b (views:buffer v)])
      (and b
           (let ([doc (buffers:document b)])
             (let loop ([n (document:enclosing doc p)])
               (cond
                 [(not n) #f]
                 [(list-node? n) n]
                 [else (loop (document:enclosing doc (document:node-start n)))]))))))

  ;; The last row drawn and its heading, so that a row's heading is
  ;; compared with the row before's without calling the heading procedure
  ;; for that row again.
  (define-record-type drawing
    (sealed #t)
    (fields rows selected start (mutable last) (mutable last-heading)))

  (define current-drawing (make-thread-parameter #f))

  (define (with-drawing node view thunk)
    (let ([b (views:buffer view)])
      (parameterize ([current-drawing (make-drawing (list-state b node) (selected-index node (views:point view))
                                                    (document:node-start node) #f #f)])
        (thunk))))

  (define (place posn)
    (if posn
        (values (views:posn-view posn) (views:posn-point posn))
        (let ([v (views:current)]) (values v (and v (views:buffer v) (views:point v))))))

  (define (clicked-posn)
    (let ([e (keys:command-event)])
      (and (keys:event? e) (keys:event-start e))))

  (define (posn-or-point) (place (clicked-posn))))

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

;; A heading goes beside its row's element, not inside it: that element
;; carries the row's position, so a click on the heading would choose the
;; row, the cursor's outline would surround the heading too, and a sticky
;; heading could not outlast its own row. The first row drawn gets its
;; heading whatever the row before it, so a run that starts inside a
;; group still names it.
(define (%with-heading child html)
  (let* ([d (current-drawing)] [state (and d (drawing-rows d))])
    (if (and state (row-atom? child) (not (rows-failed? state)))
        (let* ([i (fx- (document:node-start child) (drawing-start d) 1)] [h (heading-of state i)]
               [shown? (and h (not (and (eqv? (drawing-last d) (fx- i 1))
                                        (drawing-last-heading d) (string=? (drawing-last-heading d) h))))])
          (drawing-last-set! d i)
          (drawing-last-heading-set! d h)
          (if (and shown? (not (rows-failed? state)))
              `(,(haml (:li.ui-list-heading (:span h))) ,html)
              html))
        html)))

;; Rows drawn before one that raised are drawn again, as nothing, so the
;; list is drawn empty from the draw that failed.
(define (%draw-list node view)
  (define (draw) (with-drawing node view (lambda () (haml (:ul.ui-list (views:draw-children view node %with-heading))))))
  (let* ([state (list-state (views:buffer view) node)] [failed? (and state (rows-failed? state))] [html (draw)])
    (if (and state (not failed?) (rows-failed? state)) (draw) html)))

(define (%draw-list-row node view)
  (let* ([d (current-drawing)] [state (and d (drawing-rows d))]
         [i (and d (fx- (document:node-start node) (drawing-start d) 1))])
    (if (and state (not (rows-failed? state)) (fx< i (rows-count state)))
        (guard (c [(failure? c) (rows-failed?-set! state #t) (report c) '()])
          (haml (:li.ui-list-row ([aria-current (and (eqv? i (drawing-selected d)) "true")])
                  ((rows-draw state) i))))
        '())))

;; Rows go only when ui writes them, which asks no kind. Text, which the
;; list's content refuses anyway, is consented to: refusing it would also
;; refuse the probe that makes the place before a row a stop, and point
;; could not rest on the first row of a list inside other text.
(define (%keep-rows node edit)
  (and (fx= (buffers:piece-length (buffers:edit-removed edit)) 0)
       (let ([inserted (buffers:piece-document (buffers:edit-inserted edit))])
         (let loop ([p 0])
           (or (fx= p (document:length inserted))
               (and (char? (document:token inserted p)) (loop (fx+ p 1))))))))

(buffers:define-kind list (content nodes) (consent %keep-rows) (keymap list-keys) (draw %draw-list))

(buffers:define-kind %list-row (content atom) (keymap row-keys) (draw %draw-list-row))

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

(define (%check-count who n)
  (unless (and (fixnum? n) (fx>= n 0))
    (assertion-violation who "not a count" n)))

(define (%no-heading i) #f)

;; The rows are not the buffer's text, so writing them is silent.
(define (%write-rows! b node start end count generation)
  (buffers:with-silent-edits b
    (buffers:splice! b start end (document:repeat (document:from-datum (row-datum generation)) count))))

;; Each view selecting a row keeps its index, clamped to the new rows, and
;; shows it, rather than whatever row took its place.
(define set-rows!
  (case-lambda
    [(buffer node count draw-row choose) (set-rows! buffer node count draw-row choose %no-heading)]
    [(buffer node count draw-row choose heading)
     (unless (buffers:buffer? buffer)
       (assertion-violation 'ui:set-rows! "not a buffer" buffer))
     (%check-count 'ui:set-rows! count)
     (unless (procedure? draw-row)
       (assertion-violation 'ui:set-rows! "not a procedure" draw-row))
     (unless (procedure? choose)
       (assertion-violation 'ui:set-rows! "not a procedure" choose))
     (unless (procedure? heading)
       (assertion-violation 'ui:set-rows! "not a procedure" heading))
     (let* ([node (%check-list 'ui:set-rows! buffer node)]
            [state (set-list-state! buffer node count draw-row heading choose)]
            [s (document:node-start node)]
            [selections (fold-left (lambda (acc v)
                                     (let ([i (selected-index node (views:point v))])
                                       (if i (cons (cons v i) acc) acc)))
                                   '() (views:showing buffer))])
       (%write-rows! buffer node (fx+ s 1) (fx- (document:node-end node) 1) count (rows-generation state))
       (unless (fx= count 0)
         (let ([node (document:token (buffers:document buffer) s)])
           (for-each (lambda (sel) (views:set-point! (car sel) (index-position node (fxmin (cdr sel) (fx- count 1)))))
                     selections))))]))

(define (add-rows! buffer node count)
  (unless (buffers:buffer? buffer)
    (assertion-violation 'ui:add-rows! "not a buffer" buffer))
  (%check-count 'ui:add-rows! count)
  (let* ([node (%check-list 'ui:add-rows! buffer node)]
         [state (or (list-state buffer node) (assertion-violation 'ui:add-rows! "the list has no rows set" node))]
         [end (fx- (document:node-end node) 1)])
    (unless (fx= count 0)
      (%write-rows! buffer node end end count (rows-generation state))
      (rows-count-set! state (fx+ (rows-count state) count)))))

(define (selected-row node view)
  (let ([b (%check-view 'ui:selected-row view)])
    (selected-index (%check-list 'ui:selected-row b node) (views:point view))))

(define (select-row! node view index)
  (let ([b (%check-view 'ui:select-row! view)])
    (unless (and (fixnum? index) (fx>= index 0))
      (assertion-violation 'ui:select-row! "not a row index" index))
    (let* ([node (%check-list 'ui:select-row! b node)] [n (row-count node)])
      (unless (fx= n 0)
        (views:set-point! view (index-position node (fxmin index (fx- n 1))))))))

;; A list that cannot show all its first rows in most lines takes them
;; all, since the line a heading needs may be the one left over.
(define (list-lines buffer node most)
  (unless (buffers:buffer? buffer)
    (assertion-violation 'ui:list-lines "not a buffer" buffer))
  (unless (and (fixnum? most) (fx> most 0))
    (assertion-violation 'ui:list-lines "not a positive count" most))
  (let* ([node (%check-list 'ui:list-lines buffer node)] [state (list-state buffer node)]
         [n (if state (fxmin (rows-count state) (row-count node)) 0)])
    (let loop ([i 0] [lines 0] [before #f])
      (cond
        [(fx> lines most) most]
        [(fx= i n) lines]
        [else
         (let ([h (heading-of state i)])
           (loop (fx+ i 1) (fx+ lines 1 (if (and h (not (and before (string=? before h)))) 1 0)) h))]))))

(define (describe-list node view)
  (let* ([b (%check-view 'ui:describe-list view)] [node (%check-list 'ui:describe-list b node)]
         [i (selected-index node (views:point view))])
    (and i (format "row ~a of ~a" (fx+ i 1) (row-count node)))))

(define (%list-here who)
  (let ([v (views:current)])
    (unless v
      (assertion-violation who "no view is current"))
    (let ([node (list-at v (views:point v))])
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

(define (%choose! v node i)
  (let ([state (list-state (views:buffer v) node)])
    (when (and state (not (rows-failed? state)) (fx< i (rows-count state)))
      (with-exception-handler
        (lambda (c)
          (when (failure? c) (rows-failed?-set! state #t))
          (raise-continuable c))
        (lambda () ((rows-choose state) i))))))

;; A click on a heading names the list's own node, whose position views
;; gives as its first row's, so the clicked node, not the position, tells
;; a row from a heading.
(commands:define-command (choose-row)
  "Calls the list's choose procedure with its selected row; run by a click, selects and chooses the row clicked, and does nothing for a click on no row, such as on a heading."
  (let ([posn (clicked-posn)])
    (if posn
        (let* ([v (views:posn-view posn)] [p (views:posn-point posn)] [b (views:buffer v)]
               [node (and b p (row-atom? (views:posn-node posn)) (list-at v p))]
               [i (and node (selected-index node p))])
          (when i
            (views:set-point! v p)
            (%choose! v node i)))
        (let-values ([(v node) (%list-here 'ui:choose-row)])
          (let ([i (selected-row node v)])
            (when i (%choose! v node i)))))))

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

(define (%showcase-group i)
  (if (fx< i 3) "Notes" "Project"))

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
  (define (fill! rows name heading)
    (set-rows! b (%showcase-list b name) (vector-length rows)
               (lambda (i) (%draw-showcase-row (vector-ref rows i)))
               (lambda (i) (%show-chosen! b (vector-ref rows i)))
               heading))
  (fill! %short-rows 'short %showcase-group)
  (fill! %long-rows 'long %no-heading))

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
      "C-n and C-p move, RET or a click chooses. Eight rows under two\n"
      "headings. Each window on this buffer selects its own row; split the\n"
      "window to see a list in a window without focus.\n")
    (list '((rows . short)))
    (%showcase-text '() "chosen    " (%chosen '()) "\n\n")
    (%showcase-text '()
      "Three hundred rows: the window scrolls through them and draws only\n"
      "those near what it shows.\n")
    (list '((rows . long)))))

(define-table showcase-keymap "Keys in *Showcase*.")

(define-hook showcase-mode-hook "Called in each buffer that turns on ui:showcase-mode.")

(modes:define-major-mode showcase-mode
  (parent modes:special)
  (lighter "Showcase")
  (keymap showcase-keymap)
  (hook showcase-mode-hook))

(define (%showcase-buffer)
  (let ([b (buffers:find "*Showcase*")])
    (and b (eq? (document:node-kind (document:token (buffers:document b) 0)) %showcase-kind) b)))

;; Read-only, so every edit is this plugin's, and it holds nothing to
;; save.
(define (%make-showcase)
  (let ([b (buffers:make "*Showcase*" (%showcase-datum))])
    (buffers:set-silent! b #t)
    (buffers:add-span! (buffers:layer b %read-only) 0 (document:length (buffers:document b)) '())
    (modes:set-major-mode showcase-mode b)
    (%fill-showcase! b)
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

(keys:bind! showcase-keymap "g" keys:undefined)
(keys:bind! list-keys "C-n" next-row)
(keys:bind! list-keys "<down>" next-row)
(keys:bind! list-keys "C-p" previous-row)
(keys:bind! list-keys "<up>" previous-row)
(keys:bind! list-keys "RET" choose-row)
(keys:bind! list-keys "<mouse-1>" keys:ignore)
(keys:bind! list-keys "<mouse-2>" keys:ignore)
;; A press would move point where it lands, and a press on a heading
;; lands on the list's first row, so the release alone selects.
(keys:bind! list-keys "<down-mouse-1>" keys:ignore)
(keys:bind! list-keys "<drag-mouse-1>" keys:ignore)
(keys:bind! list-keys "<drag-mouse-2>" keys:ignore)
(keys:bind! row-keys "<mouse-1>" choose-row)
(keys:bind! row-keys "<mouse-2>" choose-row)
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

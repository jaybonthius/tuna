#!tuna
(import (buffers) (document) (views) (layout) (layout-split) (keys) (commands) (modes) (echo-area) (web) (haml) (ask))

(define-saved history '() (lambda (v) (and (list? v) (for-all string? v))))

(define-saved number-history '() (lambda (v) (and (list? v) (for-all string? v))))

(define-option history-length 100 (lambda (v) (and (fixnum? v) (fx>= v 0)))
  "How many answers a history keeps.")

(define-hook prompt-started "Called with each prompt after its setup, before the task pauses.")

(define-hook prompt-ended "Called with each prompt after it ends, however it ends.")

(define-hook input-changed "Called with a prompt after each edit of its input, in the task that made the edit.")

(define-table keymap "The keymap of the minibuffer's major mode.")

(define-hook %mode-hook)

(modes:define-major-mode mode (keymap keymap) (hook %mode-hook) (plugin-only #t))

;; The plugin writes prompts with splice!, which asks no kind, so every
;; kind but the input refuses the user's edits.
(define (%refuse-edits node edit) #f)

;; An edit reaching past the input's edges would delete the question or
;; the list after it, as C-d at the input's end would. One that ends just
;; after the input's closing, as C-k from the input does at the line's
;; end, keeps the closing and changes only the input.
(define (%input-edit? input edit)
  (let ([start (buffers:edit-start edit)])
    (and (fx> start (document:node-start input))
         (fx<= (fx+ start (buffers:piece-length (buffers:edit-removed edit))) (document:node-end input)))))

(define (%prompt-consent node edit)
  (let ([input (%input-of node)])
    (and input (%input-edit? input edit))))

;; A view narrowed to nothing draws no line, so the idle part takes no
;; room.
(define (%draw-prompts node view)
  (let-values ([(start end) (views:bounds view)])
    (haml (:div.minibuffer-prompts (unless (fx= start end) (views:draw-children view node))))))

(define (%draw-prompt node view)
  (let ([depth (document:node-attribute node 'depth 1)])
    (haml (:div.minibuffer-prompt
            (when (and (fixnum? depth) (fx> depth 1)) (:span.minibuffer-depth "[" depth "] "))
            (views:draw-children view node)))))

(define (%draw-question node view)
  (haml (:span.minibuffer-question (views:draw-children view node))))

(define (%with-faces text ranges)
  (let loop ([at 0] [ranges (list-sort (lambda (a b) (fx< (car a) (car b))) ranges)] [acc '()])
    (cond
      [(null? ranges) (reverse (cons (substring text at (string-length text)) acc))]
      [(fx< (caar ranges) at) (loop at (cdr ranges) acc)]
      [else
       (let ([r (car ranges)])
         (loop (cadr r) (cdr ranges)
               (cons* (haml (:span ([data-face (symbol->string (caddr r))]) (substring text (car r) (cadr r))))
                      (substring text at (car r))
                      acc)))])))

(define (%draw-message text face ranges)
  (haml (:span.minibuffer-message ([role "status"] [data-face (and face (symbol->string face))])
          " [" (%with-faces text ranges) "]")))

;; The prompt's own message is about its input, so it wins over the echo
;; area's.
(define (%message-html p)
  (cond
    [(not p) '()]
    [(prompt-message p) => (lambda (text) (%draw-message text #f '()))]
    [(and (eq? p (bottom-prompt)) (echo-area:hidden?) (echo-area:current-message))
     => (lambda (text) (%draw-message text (echo-area:current-face) (echo-area:current-spans)))]
    [else '()]))

(define (%draw-input node view)
  (haml (:span.minibuffer-input (views:draw-children view node) (%message-html (prompt-of node view)))))

(define (%draw-content node view)
  (haml (:div.minibuffer-content (views:draw-children view node))))

(buffers:define-kind %prompts (content nodes) (consent %refuse-edits) (draw %draw-prompts))

(buffers:define-kind prompt (stops children) (consent %prompt-consent) (draw %draw-prompt))

(buffers:define-kind question (inline) (stops none) (consent %refuse-edits) (draw %draw-question))

(buffers:define-kind input-field (inline) (consent %input-edit?) (draw %draw-input))

(buffers:define-kind content (inline) (stops none) (consent %refuse-edits) (draw %draw-content))

(module %internals
  (check-main-thread check-prompt check-live buffer prompts make-prompt prompt-record? prompt-depth prompt-task
   history-of entries-of prompt-chosen prompt-chosen-set! default-of shown-in prompt-keymaps prompt-keymaps-set! prompt-message prompt-message-set!
   prompt-recalled prompt-recalled-set! prompt-typed prompt-typed-set! prompt-ended? prompt-node prompt-parts
   input-range input-text prompt-holding prompt-at start-prompt! end-prompt! answer! prompt-of
   setups prompt-keymaps-at quit-condition without-quits bar-view narrow-views! at-bottom bottom-prompt
   write-content! prompt-answer prompt-resume-set! clear-messages! prompt-before-id live-view)

  (define main-thread (get-thread-id))

  (define (check-main-thread who)
    (unless (fx= (get-thread-id) main-thread)
      (assertion-violation who "not on the main thread")))

  (define-record-type (prompt-record make-prompt prompt-record?)
    (sealed #t)
    (fields (immutable depth prompt-depth) (immutable task prompt-task) (immutable history history-of)
            (immutable default default-of) (mutable view shown-in shown-in-set!) (mutable view-id shown-id shown-id-set!)
            (mutable keymaps prompt-keymaps prompt-keymaps-set!) (mutable message prompt-message prompt-message-set!)
            (mutable recalled prompt-recalled prompt-recalled-set!) (mutable typed prompt-typed prompt-typed-set!)
            (mutable ended? prompt-ended? prompt-ended?-set!) (mutable resume prompt-resume prompt-resume-set!)
            (mutable answer prompt-answer prompt-answer-set!) (mutable before-id prompt-before-id prompt-before-id-set!)
            (mutable point prompt-point prompt-point-set!) (mutable final prompt-final prompt-final-set!)
            (immutable entries entries-of) (mutable chosen prompt-chosen prompt-chosen-set!)))

  (define (check-prompt who p)
    (unless (prompt-record? p)
      (assertion-violation who "not a prompt" p)))

  (define (check-live who p)
    (check-prompt who p)
    (check-main-thread who)
    (when (prompt-ended? p)
      (assertion-violation who "a prompt that has ended" p)))

  ;; Tuna's dynamic-wind holds quits off while its in runs, so a prompt is
  ;; never left half inserted or half removed.
  (define (without-quits thunk)
    (let ([result #f])
      (dynamic-wind (lambda () (set! result (thunk))) void void)
      result))

  (define quit-condition (record-constructor (record-constructor-descriptor &quit)))

  ;; An internal buffer starts silent, but the input's edits are the
  ;; user's.
  (define buffer
    (let ([b (or (buffers:find " *Minibuf*") (buffers:make " *Minibuf*" (%prompts '())))])
      (let ([doc (buffers:document b)])
        (unless (fx= (document:length doc) 2)
          (buffers:with-silent-edits b
            (buffers:splice! b 0 (document:length doc) (document:from-datum (%prompts '()))))))
      (buffers:set-silent! b #f)
      b))

  (define prompts '())

  ;; The plugin's writes are silent, so undo in an input steps over them,
  ;; and removing a prompt takes its input's history with it.
  (define (write! start end datum)
    (buffers:with-silent-edits buffer
      (buffers:splice! buffer start end (document:from-datum datum))))

  (define (root-children)
    (let* ([doc (buffers:document buffer)] [acc '()])
      (document:for-each-child (document:token doc 0) 1 (fx- (document:length doc) 1)
        (lambda (c at) (when (document:node? c) (set! acc (cons c acc)))))
      (reverse acc)))

  (define (prompt-node p)
    (find (lambda (n) (eqv? (document:node-attribute n 'depth #f) (prompt-depth p))) (root-children)))

  (define (prompt-parts node)
    (let ([acc '()])
      (document:for-each-child node (fx+ (document:node-start node) 1) (fx- (document:node-end node) 1)
        (lambda (c at) (when (document:node? c) (set! acc (cons c acc)))))
      (reverse acc)))

  (define (input-range p)
    (let ([input (cadr (prompt-parts (prompt-node p)))])
      (values (fx+ (document:node-start input) 1) (fx- (document:node-end input) 1))))

  ;; An ended prompt keeps its last input, for prompt-ended's entries.
  (define (input-text p)
    (if (prompt-ended? p)
        (prompt-final p)
        (let-values ([(s e) (input-range p)])
          (document:text (buffers:document buffer) s e))))

  (define (write-content! p datums)
    (let ([c (caddr (prompt-parts (prompt-node p)))])
      (without-quits
        (lambda () (write! (document:node-start c) (document:node-end c) (apply content '() datums))))))

  (define (prompt-at position)
    (find (lambda (p)
            (let ([n (prompt-node p)])
              (and n (fx< (document:node-start n) position (document:node-end n)))))
          prompts))

  (define (prompt-holding position)
    (find (lambda (p) (let-values ([(s e) (input-range p)]) (fx<= s position e))) prompts))

  (define (prompt-of node view)
    (and (eq? (views:buffer view) buffer)
         (let ([n (document:enclosing (buffers:document buffer) (document:node-start node))])
           (and n (find (lambda (p) (eqv? (prompt-depth p) (document:node-attribute n 'depth #f))) prompts)))))

  (define (clear-messages!)
    (for-each (lambda (p) (prompt-message-set! p #f)) prompts))

  (define (prompt-keymaps-at view position)
    (let ([p (and view position (eq? (views:buffer view) buffer) (prompt-holding position))])
      (if p (prompt-keymaps p) '())))

  ;; Each call-with-setup pushes a box, emptied by the first prompt that
  ;; takes it; a task's parameter bindings are its own, so a prompt in
  ;; another task never takes it.
  (define setups (make-thread-parameter '()))

  (define (bar-view) (layout:find-view buffer))

  (define (set-other-view! v on?)
    (let ([node (or (layout:view-node v) (layout:popup-node v))])
      (when node (layout:set-part-attribute! node 'other-view on?))))

  (define (narrow-views! shown)
    (let ([n (and shown (prompt-node shown))] [v (and shown (shown-in shown))])
      (for-each
        (lambda (view)
          (if (and n (eq? view v))
              (views:narrow! view (document:node-start n) (document:node-end n))
              (views:narrow! view 1 1)))
        (views:showing buffer))))

  ;; Only a prompt in the part at the bottom takes the echo area's place;
  ;; a display rule may show one elsewhere, as in a palette.
  (define bottom-id #f)

  (define (at-bottom b)
    (let ([v ((layout-split:display-at-side (layout:direction down) 100 'content '((locked . #t))) b)])
      (set! bottom-id (views:id v))
      v))

  (define (bottom-prompt)
    (and (pair? prompts)
         (let ([p (car prompts)])
           (and (eqv? (shown-id p) bottom-id) (live-view bottom-id) p))))

  ;; A view of a part that went is dropped, and a dropped view raises;
  ;; its number, unique while Tuna runs, finds it only while it lives.
  (define (live-view id) (and id (views:find id)))

  ;; As Emacs does, a prompt starts with an empty echo area. Clearing it
  ;; shows any queued reports first and so erases them unseen; clear only
  ;; a message that shows, and let a queued report show after the input.
  (define (start-prompt! p text)
    (when (echo-area:current-message) (echo-area:message! ""))
    (without-quits
      (lambda ()
        (let ([outer (and (pair? prompts) (car prompts))] [end (fx- (document:length (buffers:document buffer)) 1)])
          (when outer
            (let ([v (live-view (shown-id outer))])
              (when (and v (eq? (views:buffer v) buffer))
                (prompt-point-set! outer (buffers:anchor buffer (views:point v))))))
          (write! end end (prompt (list (cons 'depth (prompt-depth p))) (question '() text) (input-field '()) "\n" (content '())))
          (set! prompts (cons p prompts))
          (prompt-before-id-set! p (views:id (layout:selected-view)))
          (let ([v (layout:display-buffer buffer at-bottom)])
            (shown-in-set! p v)
            (shown-id-set! p (views:id v))
            (narrow-views! p)
            (let-values ([(s e) (input-range p)]) (views:set-point! v e))
            (layout:select! v)
            (set-other-view! v #t))))))

  ;; Only the innermost prompt's end moves the selection: an outer one
  ;; ending while an inner one waits leaves the inner one selected. A
  ;; prompt whose start raised may have no node.
  (define (end-prompt! p)
    (unless (prompt-ended? p)
      (without-quits
        (lambda ()
          (let ([v (live-view (shown-id p))] [n (prompt-node p)] [before (live-view (prompt-before-id p))]
                [innermost? (and (pair? prompts) (eq? p (car prompts)))])
            (prompt-final-set! p (if n (input-text p) ""))
            (prompt-ended?-set! p #t)
            (set! prompts (remq p prompts))
            (when n (write! (document:node-start n) (document:node-end n) ""))
            (let ([selected? (and innermost? v (eq? (layout:selected-view) v))])
              (cond
                [(pair? prompts)
                 (let* ([inner (car prompts)] [a (prompt-point inner)] [iv (live-view (shown-id inner))])
                   (narrow-views! inner)
                   (when (and innermost? a iv (eq? (views:buffer iv) buffer))
                     (views:set-point! iv (buffers:anchor-position a))))]
                [else
                 (narrow-views! #f)
                 (when v
                   (if (layout:view-node v)
                       (set-other-view! v #f)
                       (let ([popup (layout:popup-node v)])
                         (when popup (layout:delete-part! popup)))))])
              (when selected?
                (cond
                  [(and before (or (layout:view-node before) (layout:popup-node before)))
                   (layout:select! before)]
                  ;; A palette's removal already selected the view the
                  ;; user works in, so its view is no longer selected and
                  ;; needs nothing more.
                  [(live-view (shown-id p)) => layout:deselect!]))))))
      (prompt-ended p)))

  (define (answer! p thunk)
    (prompt-answer-set! p thunk)
    (let ([resume (prompt-resume p)])
      (when resume
        (prompt-resume-set! p #f)
        (resume thunk)))))

(import %internals)

(define (%input-of node)
  (let ([parts (prompt-parts node)])
    (and (pair? parts) (pair? (cdr parts)) (cadr parts))))

(define (prompt? v) (prompt-record? v))

(define (buffer? b)
  (unless (buffers:buffer? b)
    (assertion-violation 'minibuffer:buffer? "not a buffer" b))
  (eq? b buffer))

(define (current-prompt)
  (check-main-thread 'minibuffer:current-prompt)
  (and (pair? prompts) (car prompts)))

(define (prompt-view p)
  (check-prompt 'minibuffer:prompt-view p)
  (shown-in p))

(define (prompt-selected-view p)
  (check-prompt 'minibuffer:prompt-selected-view p)
  (check-main-thread 'minibuffer:prompt-selected-view)
  (let ([v (live-view (prompt-before-id p))])
    (and v (or (layout:view-node v) (layout:popup-node v)) v)))

(define (prompt-history p)
  (check-prompt 'minibuffer:prompt-history p)
  (history-of p))

(define (prompt-entries p)
  (check-prompt 'minibuffer:prompt-entries p)
  (entries-of p))

(define (recall! p k)
  (check-live 'minibuffer:recall! p)
  (let ([n (+ (length (entries-of p)) (let ([h (history-of p)]) (if h (length (h)) 0)))])
    (unless (and (fixnum? k) (fx<= 1 k n))
      (assertion-violation 'minibuffer:recall! "not an index of the prompt's entries and history" k)))
  (%recall! p (- k (prompt-recalled p)) 'minibuffer:recall!))

(define (prompt-default p)
  (check-prompt 'minibuffer:prompt-default p)
  (default-of p))

(define (input p)
  (check-prompt 'minibuffer:input p)
  (check-main-thread 'minibuffer:input)
  (input-text p))

(define (input-start p)
  (check-live 'minibuffer:input-start p)
  (let-values ([(s e) (input-range p)]) s))

(define (input-end p)
  (check-live 'minibuffer:input-end p)
  (let-values ([(s e) (input-range p)]) e))

(define (set-input! p text)
  (check-live 'minibuffer:set-input! p)
  (unless (string? text)
    (assertion-violation 'minibuffer:set-input! "not a string" text))
  (let-values ([(s e) (input-range p)])
    (buffers:replace! buffer s e text)
    (let ([v (shown-in p)])
      (when (and v (eq? (views:buffer v) buffer))
        (let-values ([(s e) (input-range p)]) (views:set-point! v e))))))

(define (add-keymap! p keymap)
  (check-live 'minibuffer:add-keymap! p)
  (unless (table? keymap)
    (assertion-violation 'minibuffer:add-keymap! "not a table" keymap))
  (prompt-keymaps-set! p (cons keymap (prompt-keymaps p))))

(define (set-content! p datums)
  (check-live 'minibuffer:set-content! p)
  (unless (list? datums)
    (assertion-violation 'minibuffer:set-content! "not a list" datums))
  (write-content! p datums))

(define (message! p text)
  (check-live 'minibuffer:message! p)
  (unless (string? text)
    (assertion-violation 'minibuffer:message! "not a string" text))
  (when (echo-area:current-message) (echo-area:message! ""))
  (prompt-message-set! p text))

;; An entry of the read's own, recalled and left as it was, is the one
;; chosen; it is not saved, as it was never typed.
(define (%note-chosen! p)
  (let ([k (prompt-recalled p)] [entries (entries-of p)])
    (when (and (fx<= 1 k (length entries)) (string=? (input-text p) (list-ref entries (fx- k 1))))
      (prompt-chosen-set! p (fx- k 1)))))

(define (%add-to-history! p)
  (let ([h (history-of p)] [text (input-text p)])
    (when (and h (not (prompt-chosen p)) (not (string=? text "")))
      (let loop ([entries (cons text (remove text (h)))] [n (history-length)] [acc '()])
        (if (or (null? entries) (fx= n 0))
            (set-saved! h (reverse acc))
            (loop (cdr entries) (fx- n 1) (cons (car entries) acc)))))))

(define (exit! p value)
  (check-live 'minibuffer:exit! p)
  (%note-chosen! p)
  (%add-to-history! p)
  (end-prompt! p)
  (answer! p (lambda () value)))

(define (call-with-setup setup thunk)
  (unless (procedure? setup)
    (assertion-violation 'minibuffer:call-with-setup "not a procedure" setup))
  (unless (procedure? thunk)
    (assertion-violation 'minibuffer:call-with-setup "not a procedure" thunk))
  (parameterize ([setups (cons (box setup) (setups))])
    (thunk)))

(define (%run-setups! p)
  (for-each
    (lambda (b)
      (let ([setup (unbox b)])
        (when setup
          (set-box! b #f)
          (setup p))))
    (setups)))

(define %read
  (case-lambda
    [(question h default) (%read question h default '() (lambda (answer chosen) answer))]
    [(question h default entries give)
     (check-main-thread 'minibuffer:read)
     (unless (current-task)
       (assertion-violation 'minibuffer:read "not in a task"))
     (let ([p (make-prompt (fx+ 1 (fold-left (lambda (m p) (fxmax m (prompt-depth p))) 0 prompts))
                           (current-task) h default #f #f '() #f 0 #f #f #f #f #f #f #f entries #f)])
       (guard (c [#t (end-prompt! p) (raise c)])
         (start-prompt! p question)
         (%run-setups! p)
         (prompt-started p)
         (let ([v (suspend
                    (lambda (resume)
                      (let ([answer (prompt-answer p)])
                        (if answer (resume answer) (prompt-resume-set! p resume)))))])
           (end-prompt! p)
           (give v (prompt-chosen p)))))]))

(define read
  (case-lambda
    [(question) (read question history #f)]
    [(question h) (read question h #f)]
    [(question h default)
     (unless (string? question)
       (assertion-violation 'minibuffer:read "not a string" question))
     (unless (or (not h) (saved? h))
       (assertion-violation 'minibuffer:read "neither saved data nor #f" h))
     (unless (or (not default) (string? default))
       (assertion-violation 'minibuffer:read "neither a string nor #f" default))
     (%read question h default)]))

(define (read-entry question h entries)
  (unless (string? question)
    (assertion-violation 'minibuffer:read-entry "not a string" question))
  (unless (or (not h) (saved? h))
    (assertion-violation 'minibuffer:read-entry "neither saved data nor #f" h))
  (unless (and (list? entries) (for-all string? entries))
    (assertion-violation 'minibuffer:read-entry "not a list of strings" entries))
  (%read question h #f entries values))

(define (%ask-line question default) (read question history default))

(define (ask-yes-or-no question)
  (unless (string? question)
    (assertion-violation 'minibuffer:ask-yes-or-no "not a string" question))
  (let loop ([complaint #f])
    (let ([answer (call-with-setup
                    (lambda (p) (when complaint (message! p complaint)))
                    (lambda () (%read (string-append question "(yes or no) ") #f #f)))])
      (cond
        [(string=? answer "yes") #t]
        [(string=? answer "no") #f]
        [else (loop "Please answer yes or no")]))))

(define read-number
  (case-lambda
    [(question) (read-number question number-history #f)]
    [(question h) (read-number question h #f)]
    [(question h default)
     (unless (string? question)
       (assertion-violation 'minibuffer:read-number "not a string" question))
     (unless (or (not h) (saved? h))
       (assertion-violation 'minibuffer:read-number "neither saved data nor #f" h))
     (unless (or (not default) (real? default))
       (assertion-violation 'minibuffer:read-number "neither a real number nor #f" default))
     (let loop ([complaint #f])
       (let* ([answer (call-with-setup
                        (lambda (p) (when complaint (message! p complaint)))
                        (lambda () (%read question h (and default (number->string default)))))]
              [n (string->number answer 10)])
         (if (and n (real? n)) n (loop "Please enter a number"))))]))

(define-table y-or-n-keymap "Added to the prompt of each y-or-n question.")

(define (%y-or-n-question? p)
  (and (memq y-or-n-keymap (prompt-keymaps p)) #t))

(define (%prompt-holding-point)
  (let ([v (views:current)])
    (and v (eq? (views:buffer v) buffer) (prompt-holding (views:point v)))))

(modes:define-minor-mode y-or-n-mode
  "Whether point is in a prompt that waits for a y-or-n answer."
  (state ()
    (let ([p (%prompt-holding-point)])
      (and p (%y-or-n-question? p)))))

(define (%question-to-answer who)
  (let ([p (%prompt-holding-point)])
    (if (and p (%y-or-n-question? p))
        p
        (or (find %y-or-n-question? prompts) (assertion-violation who "no y-or-n question waits")))))

(commands:define-command (answer-yes)
  "Answers yes to the y-or-n question holding point, or else to the innermost one."
  (exit! (%question-to-answer 'minibuffer:answer-yes) #t))

(commands:define-command (answer-no)
  "Answers no to the y-or-n question holding point, or else to the innermost one."
  (exit! (%question-to-answer 'minibuffer:answer-no) #f))

(commands:define-command (%reject-y-or-n-answer)
  "Tells the user that the y-or-n question takes only y or n."
  (message! (%question-to-answer 'minibuffer:%reject-y-or-n-answer) "Please answer y or n"))

(define (ask-y-or-n question)
  (unless (string? question)
    (assertion-violation 'minibuffer:ask-y-or-n "not a string" question))
  (let loop ([complaint #f])
    (let ([answer (call-with-setup
                    (lambda (p)
                      (add-keymap! p y-or-n-keymap)
                      (when complaint (message! p complaint)))
                    (lambda () (%read (string-append question "(y or n) ") #f #f)))])
      (if (boolean? answer) answer (loop "Please answer y or n")))))

(define (%input-edited b e)
  (when (and (eq? b buffer) (not (buffers:edit-silent? e)))
    (let ([p (prompt-holding (buffers:edit-start e))])
      (when p (input-changed p)))))

(define (%prompt-keymaps client posn)
  (if posn
      (prompt-keymaps-at (views:posn-view posn) (views:posn-point posn))
      (let ([v (views:current)])
        (prompt-keymaps-at v (and v (eq? (views:buffer v) buffer) (views:point v))))))

(define (%innermost who)
  (or (current-prompt) (assertion-violation who "no prompt waits")))

(commands:define-command (exit)
  "Ends the prompt holding point with its input as the answer."
  (let* ([v (views:current)]
         [p (or (and v (eq? (views:buffer v) buffer) (prompt-at (views:point v))) (%innermost 'minibuffer:exit))]
         [text (input-text p)] [default (default-of p)])
    (exit! p (if (and default (string=? text "")) default text))))

(commands:define-command (abort)
  "Quits the innermost prompt: its read raises a quit."
  (let ([p (%innermost 'minibuffer:abort)])
    (end-prompt! p)
    (signal-task (prompt-task p) (quit-condition))))

(define (%recall! p n who)
  (let* ([h (history-of p)] [entries (append (entries-of p) (if h (h) '()))] [k (+ (prompt-recalled p) n)] [default (default-of p)])
    (cond
      [(> k (length entries)) (error who "beginning of history")]
      [(< k (if default -1 0)) (error who (if default "end of defaults" "end of history"))]
      [else
       (when (fx= (prompt-recalled p) 0) (prompt-typed-set! p (input-text p)))
       (prompt-recalled-set! p k)
       (set-input! p (cond [(fx= k -1) default] [(fx= k 0) (prompt-typed p)] [else (list-ref entries (fx- k 1))]))])))

(commands:define-command (previous-history [n (commands:prefix-number)])
  "Replaces the input with the history entry N older than the one shown."
  (%recall! (%innermost 'minibuffer:previous-history) n 'minibuffer:previous-history))

(commands:define-command (next-history [n (commands:prefix-number)])
  "Replaces the input with the history entry N newer, ending at what was typed, then the prompt's default."
  (%recall! (%innermost 'minibuffer:next-history) (- n) 'minibuffer:next-history))

(commands:define-command (mouse-set-point [event (keys:command-event)])
  "Selects the innermost prompt's view and puts point at the click, kept within the input."
  (let* ([p (%innermost 'minibuffer:mouse-set-point)] [v (shown-in p)]
         [at (and (keys:event? event) (views:posn-point (keys:event-end event)))])
    (layout:select! v)
    (let-values ([(s e) (input-range p)])
      (views:set-point! v (if at (fxmax s (fxmin e at)) e)))))

(commands:define-command (select-prompt)
  "Selects the view showing the innermost prompt."
  (layout:select! (shown-in (%innermost 'minibuffer:select-prompt))))

(define (%keep-buffer b) (not (eq? b buffer)))

(define (%hide-echo-area hidden?)
  (or (and (bottom-prompt) #t) (hidden?)))

;; Cleared before the key's command runs, as the echo area's message is,
;; so a message from that command shows.
(define (%clear-on-key press client key)
  (when (string? key) (clear-messages!))
  (press client key))

(define (%unload)
  (for-each
    (lambda (p)
      (end-prompt! p)
      (signal-task (prompt-task p) (quit-condition)))
    prompts)
  (let ([v (bar-view)])
    (when v (layout:delete-part! (layout:view-node v))))
  (remove-hook! buffers:kill-queries %keep-buffer)
  (buffers:kill! buffer))

(modes:set-major-mode mode buffer)
(at-bottom buffer)
(narrow-views! #f)
(keys:bind! keymap "RET" exit)
(keys:bind! keymap "M-p" previous-history)
(keys:bind! keymap "M-n" next-history)
(keys:bind! keymap "<down-mouse-1>" keys:ignore)
(keys:bind! keymap "<mouse-1>" mouse-set-point)
(keys:remap! keymap keys:keyboard-quit abort)
(keys:bind! y-or-n-keymap "y" answer-yes)
(keys:bind! y-or-n-keymap "Y" answer-yes)
(keys:bind! y-or-n-keymap "SPC" answer-yes)
(keys:bind! y-or-n-keymap "n" answer-no)
(keys:bind! y-or-n-keymap "N" answer-no)
(keys:bind! y-or-n-keymap "DEL" answer-no)
(keys:bind! y-or-n-keymap "<delete>" answer-no)
(keys:bind! y-or-n-keymap "<printing-char>" %reject-y-or-n-answer)
(keys:remap! y-or-n-keymap exit %reject-y-or-n-answer)
;; select-prompt is of use only outside the prompt, so M-x offers it
;; everywhere.
(for-each
  (lambda (command) (table-set! commands:command-modes command (list mode)))
  (list exit abort previous-history next-history mouse-set-point))
(table-set! commands:command-modes answer-yes (list y-or-n-mode))
(table-set! commands:command-modes answer-no (list y-or-n-mode))
(add-hook! keys:find-keymaps %prompt-keymaps 40)
(set-option! ask:line-reader %ask-line)
(set-option! ask:number-reader read-number)
(set-option! ask:yes-or-no-reader ask-yes-or-no)
(set-option! ask:y-or-n-reader ask-y-or-n)
(table-set! web:stylesheets 'minibuffer "minibuffer/minibuffer.css")
(add-hook! buffers:after-edit %input-edited)
(add-hook! buffers:kill-queries %keep-buffer)
(advice-add! echo-area:hidden? %hide-echo-area)
(advice-add! keys:press! %clear-on-key)
(on-unload %unload)

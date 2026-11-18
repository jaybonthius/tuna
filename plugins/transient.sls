#!tuna
(import (keys) (commands) (views) (buffers) (document) (layout) (layout-float) (ui) (faces) (web) (haml))

(define-table keymap
  "The keys of every open menu, searched after the top menu's keymap.")

(define-table staying-commands
  "Commands, as keys, that run without closing the open menus, though no menu binds them.")

(define %main-thread (get-thread-id))

(define (%check-main-thread who)
  (unless (fx= (get-thread-id) %main-thread)
    (assertion-violation who "not on the main thread")))

(define (%check-menu who menu)
  (unless (table? menu)
    (assertion-violation who "not a table" menu)))

(define (%check-heading who heading)
  (unless (or (not heading) (string? heading) (procedure? heading))
    (assertion-violation who "neither a string, a procedure nor #f" heading)))

(define (%check-entry-parts who key description)
  (unless (string? key)
    (assertion-violation who "not a string" key))
  (unless (or (string? description) (procedure? description))
    (assertion-violation who "neither a string nor a procedure" description)))

(define (%warn text)
  (raise-continuable (condition (make-warning) (make-message-condition text))))

(define-record-type (%settings %make-settings %settings?)
  (sealed #t)
  (fields title option incompatible))

(define-table %menus)

(define-record-type (%showing %make-showing %showing?)
  (sealed #t)
  (fields menu view-id (mutable arguments) (mutable reported) (mutable warned) (mutable drawn)))

(define %stack '())

(define (%initial-arguments menu view)
  (let ([settings (table-ref %menus menu #f)])
    (if (and settings (%settings-option settings))
        (views:call-with-view view (lambda () (list-copy ((%settings-option settings)))))
        '())))

;; A view leaves the layout in one batch and is dropped as it ends, so a
;; view that is no longer shown counts as gone.
(define (%live-view id)
  (let ([v (views:find id)])
    (and v (or (layout:view-node v) (layout:popup-node v)) v)))

(define (%menu-view s) (%live-view (%showing-view-id s)))

;; A menu defined in the configuration or at the REPL outlives this
;; module, whose definitions then raise, so its unload action does
;; nothing once this module has unloaded.
(define %registered '())

(define (%checked-title title)
  (unless (or (string? title) (procedure? title))
    (assertion-violation 'transient:define-menu "neither a string nor a procedure" title))
  title)

(define (%checked-option option)
  (unless (option? option)
    (assertion-violation 'transient:define-menu "not an option" option))
  option)

(define (%register-menu! menu title option incompatible)
  (unless (for-all (lambda (set) (and (list? set) (for-all string? set))) incompatible)
    (assertion-violation 'transient:define-menu "not a list of lists of strings" incompatible))
  (table-set! %menus menu (%make-settings title option incompatible))
  (let ([registered (box menu)])
    (set! %registered (cons registered %registered))
    (on-unload
      (lambda ()
        (let ([m (unbox registered)])
          (when m
            (set! %registered (remq registered %registered))
            (%close-menu! m)))))))

(define-syntax define-menu
  (lambda (x)
    (syntax-case x ()
      [(_ id doc clause ...)
       (and (identifier? #'id) (string? (syntax->datum #'doc)))
       (let loop ([clauses #'(clause ...)] [seen '()] [title #'#f] [option #'#f] [incompatible #''()])
         (if (null? clauses)
             #`(begin
                 (define-table id doc)
                 (define-values () (begin (%register-menu! id #,title #,option #,incompatible) (values))))
             (let* ([c (car clauses)]
                    [name (syntax-case c () [(k . _) (identifier? #'k) (syntax->datum #'k)] [_ #f])])
               (when (or (not name) (memq name seen))
                 (syntax-violation 'transient:define-menu "an unknown or repeated clause" x c))
               (let ([seen (cons name seen)] [rest (cdr clauses)])
                 (case name
                   [(title)
                    (syntax-case c () [(_ e) (loop rest seen #'(%checked-title e) option incompatible)]
                      [_ (syntax-violation 'transient:define-menu "expected (title title-expr)" x c)])]
                   [(arguments)
                    (syntax-case c () [(_ e) (loop rest seen title #'(%checked-option e) incompatible)]
                      [_ (syntax-violation 'transient:define-menu "expected (arguments option-expr)" x c)])]
                   [(incompatible)
                    (syntax-case c ()
                      [(_ (a ...) ...) (loop rest seen title option #'(list (list a ...) ...))]
                      [_ (syntax-violation 'transient:define-menu "expected (incompatible (argument-string ...) ...)" x c)])]
                   [else (syntax-violation 'transient:define-menu "an unknown or repeated clause" x c)])))))]
      [_ (syntax-violation 'transient:define-menu "expected (transient:define-menu id doc-string clause ...)" x)])))

(define-record-type (%entry %make-entry entry?)
  (sealed #t)
  (fields key description type command command-arguments argument reader))

(define (command key description command . command-arguments)
  (%check-entry-parts 'transient:command key description)
  (unless (commands:command? command)
    (assertion-violation 'transient:command "not a command" command))
  (%make-entry key description 'command command command-arguments #f #f))

(define (staying-command key description command . command-arguments)
  (%check-entry-parts 'transient:staying-command key description)
  (unless (commands:command? command)
    (assertion-violation 'transient:staying-command "not a command" command))
  (%make-entry key description 'staying command command-arguments #f #f))

(define (switch key description argument)
  (%check-entry-parts 'transient:switch key description)
  (unless (string? argument)
    (assertion-violation 'transient:switch "not a string" argument))
  (%make-entry key description 'switch #f '() argument #f))

(define (valued-switch key description argument reader)
  (%check-entry-parts 'transient:valued-switch key description)
  (unless (string? argument)
    (assertion-violation 'transient:valued-switch "not a string" argument))
  (unless (procedure? reader)
    (assertion-violation 'transient:valued-switch "not a procedure" reader))
  (%make-entry key description 'valued #f '() argument reader))

;; Each entry and computed group is a table entry of the module that
;; added it, keyed by its menu and its key or heading, so unloading that
;; module brings back what it replaced.
(define-record-type (%placed %make-placed %placed?)
  (sealed #t)
  (fields heading entry order))

(define-record-type (%computed %make-computed %computed?)
  (sealed #t)
  (fields heading procedure order))

(define-table %entries)

(define-table %computed-groups)

(define %order 0)

(define (%next-order!)
  (set! %order (fx+ %order 1))
  %order)

(define (add! menu heading . entries)
  (%check-main-thread 'transient:add!)
  (%check-menu 'transient:add! menu)
  (%check-heading 'transient:add! heading)
  (for-each (lambda (e) (unless (entry? e) (assertion-violation 'transient:add! "not an entry" e))) entries)
  (for-each
    (lambda (e)
      (keys:bind! menu (%entry-key e) press)
      (table-set! %entries (cons menu (%entry-key e)) (%make-placed heading e (%next-order!))))
    entries))

(define (add-computed! menu heading entries)
  (%check-main-thread 'transient:add-computed!)
  (%check-menu 'transient:add-computed! menu)
  (%check-heading 'transient:add-computed! heading)
  (unless (procedure? entries)
    (assertion-violation 'transient:add-computed! "not a procedure" entries))
  (table-set! %computed-groups (cons menu heading) (%make-computed heading entries (%next-order!))))

(define (remove! menu key)
  (%check-main-thread 'transient:remove!)
  (%check-menu 'transient:remove! menu)
  (unless (string? key)
    (assertion-violation 'transient:remove! "not a string" key))
  (table-remove! %entries (cons menu key))
  (keys:unbind! menu key))

(define (%prefix? prefix s)
  (let ([n (string-length prefix)])
    (and (fx<= n (string-length s)) (string=? prefix (substring s 0 n)))))

(define (%valued-in argument-list argument)
  (find (lambda (a) (%prefix? argument a)) argument-list))

(define (%member-matches? member argument)
  (or (string=? member argument)
      (and (fx> (string-length member) 0)
           (char=? (string-ref member (fx- (string-length member) 1)) #\=)
           (%prefix? member argument))))

(define (%put-in! s argument)
  (let* ([settings (table-ref %menus (%showing-menu s) #f)]
         [sets (if settings (%settings-incompatible settings) '())]
         [excluded (fold-left
                     (lambda (acc set)
                       (if (exists (lambda (m) (%member-matches? m argument)) set)
                           (append (remp (lambda (m) (%member-matches? m argument)) set) acc)
                           acc))
                     '() sets)])
    (%showing-arguments-set! s
      (append (remp (lambda (a) (exists (lambda (m) (%member-matches? m a)) excluded)) (%showing-arguments s))
              (list argument)))))

(define %chosen (make-thread-parameter #f))

(define (arguments menu)
  (%check-menu 'transient:arguments menu)
  (let ([chosen (%chosen)])
    (if (and chosen (eq? (car chosen) menu))
        (list-copy (cdr chosen))
        (let ([settings (table-ref %menus menu #f)])
          (if (and settings (%settings-option settings))
              (list-copy ((%settings-option settings)))
              '())))))

(define (argument-value argument-list argument)
  (unless (and (list? argument-list) (for-all string? argument-list))
    (assertion-violation 'transient:argument-value "not a list of strings" argument-list))
  (unless (string? argument)
    (assertion-violation 'transient:argument-value "not a string" argument))
  (let ([a (%valued-in argument-list argument)])
    (and a (substring a (string-length argument) (string-length a)))))

(define (%draw-root node view)
  (haml (:div.transient-menu (views:draw-children view node))))

(define (%draw-title node view)
  (haml (:h1.transient-title (document:node-attribute node 'text ""))))

(define (%draw-group node view)
  (haml (:section.transient-group (views:draw-children view node))))

(define (%draw-heading node view)
  (haml (:h2.transient-heading (document:node-attribute node 'text ""))))

(define (%draw-entry node view)
  (let ([argument (document:node-attribute node 'argument #f)] [in (document:node-attribute node 'in 'none)])
    (haml
      (:button.ui-button.transient-entry
        ([type "button"] [tabindex "-1"] [aria-pressed (case in [(#t) "true"] [(#f) "false"] [else #f])])
        (:kbd.transient-key ([data-face (symbol->string faces:keyword)]) (document:node-attribute node 'key ""))
        " "
        (ui:label (document:node-attribute node 'description ""))
        (when argument
          " "
          (:span.transient-argument ([data-face (and (not (eq? in #t)) (symbol->string faces:shadow))]) argument))))))

(define-table %root-keys)

(define-table %entry-keys)

(buffers:define-kind %root (content nodes) (whole) (keymap %root-keys) (draw %draw-root))

(buffers:define-kind %title (content atom) (draw %draw-title))

(buffers:define-kind %group (content nodes) (draw %draw-group))

(buffers:define-kind %heading (content atom) (draw %draw-heading))

(buffers:define-kind %entry-atom (content atom) (keymap %entry-keys) (draw %draw-entry))

(define %entry-atom-kind (vector-ref (%entry-atom '()) 0))

(define (%report-once! s procedure c)
  (unless (memq procedure (%showing-reported s))
    (%showing-reported-set! s (cons procedure (%showing-reported s)))
    (report c)))

(define (%warn-once! s key text)
  (unless (member key (%showing-warned s))
    (%showing-warned-set! s (cons key (%showing-warned s)))
    (report (condition (make-warning) (make-who-condition 'transient:add-computed!) (make-message-condition text)))))

(define (%call s who procedure check what)
  (guard (c [(not (quit-condition? c)) (%report-once! s procedure c) #f])
    (let ([v (procedure)])
      (unless (check v)
        (assertion-violation who what v))
      v)))

(define (%text s who v)
  (if (procedure? v)
      (%call s who v string? "a title, heading or description that is not a string")
      v))

(define (%entry-maker e)
  (case (%entry-type e)
    [(command) 'transient:command]
    [(staying) 'transient:staying-command]
    [(switch) 'transient:switch]
    [else 'transient:valued-switch]))

(define (%entry-in? s e)
  (case (%entry-type e)
    [(switch) (and (member (%entry-argument e) (%showing-arguments s)) #t)]
    [(valued) (and (%valued-in (%showing-arguments s) (%entry-argument e)) #t)]
    [else 'none]))

(define (%entry-datum s e description)
  (let ([in (%entry-in? s e)])
    (%entry-atom
      (append
        (list (cons 'key (%entry-key e)) (cons 'description description))
        (if (eq? in 'none)
            '()
            (list (cons 'argument (or (and (eq? (%entry-type e) 'valued) (%valued-in (%showing-arguments s) (%entry-argument e)))
                                      (%entry-argument e)))
                  (cons 'in in)))))))

;; keys offers no predicate for the keys its <printing-char> stands for.
(define (%printing-key? key)
  (and (fx= (string-length key) 1)
       (let ([c (string-ref key 0)])
         (not (or (char=? c #\space) (eq? (char-general-category c) 'Cc))))))

(define (%item-order item)
  (if (%placed? item) (%placed-order item) (%computed-order item)))

(define (%item-heading item)
  (if (%placed? item) (%placed-heading item) (%computed-heading item)))

(define (%items menu)
  (list-sort
    (lambda (a b) (fx< (%item-order a) (%item-order b)))
    (append
      (fold-left
        (lambda (acc e)
          (let ([k (car e)])
            (if (and (eq? (car k) menu) (eq? (table-ref menu (cdr k) #f) press))
                (cons (cdr e) acc)
                acc)))
        '() (table-entries %entries))
      (fold-left
        (lambda (acc e) (if (eq? (car (car e)) menu) (cons (cdr e) acc) acc))
        '() (table-entries %computed-groups)))))

(define (%grouped items)
  (let loop ([items items] [groups '()])
    (if (null? items)
        (reverse (map (lambda (g) (cons (car g) (reverse (cdr g)))) groups))
        (let* ([item (car items)] [heading (%item-heading item)] [g (assoc heading groups)])
          (if g
              (begin (set-cdr! g (cons item (cdr g))) (loop (cdr items) groups))
              (loop (cdr items) (cons (list heading item) groups)))))))

(define (%binding-description binding)
  (if (table? binding)
      (or (documentation binding) "")
      (symbol->string (commands:command-name binding))))

(define (%build s)
  (let* ([menu (%showing-menu s)] [settings (table-ref %menus menu #f)]
         [title (and settings (%settings-title settings)
                     (%text s 'transient:define-menu (%settings-title settings)))]
         [drawn '()])
    (define (entry-datum e)
      (let ([description (%text s (%entry-maker e) (%entry-description e))])
        (and description
             (begin
               (set! drawn (cons (cons (%entry-key e) e) drawn))
               (%entry-datum s e description)))))
    (define (computed-datum e)
      (let ([key (%entry-key e)])
        (cond
          [(not (%printing-key? key))
           (%warn-once! s key (format "the computed entry ~a is left out: its key is not one printing character" key))
           #f]
          [(or (table-ref menu key #f) (table-ref keymap key #f) (assoc key drawn))
           (%warn-once! s key (format "the computed entry ~a is left out: the menu has its key" key))
           #f]
          [else (entry-datum e)])))
    (define (group-datums items)
      (let loop ([items items] [acc '()])
        (cond
          [(null? items) (reverse acc)]
          [(%placed? (car items))
           (let ([d (entry-datum (%placed-entry (car items)))])
             (loop (cdr items) (if d (cons d acc) acc)))]
          [else
           (let each ([es (or (%call s 'transient:add-computed! (%computed-procedure (car items))
                                     (lambda (v) (and (list? v) (for-all entry? v)))
                                     "a computed group that is not a list of entries")
                              '())]
                      [acc acc])
             (if (null? es)
                 (loop (cdr items) acc)
                 (let ([d (computed-datum (car es))])
                   (each (cdr es) (if d (cons d acc) acc)))))])))
    (let loop ([groups (%grouped (%items menu))] [acc '()])
      (if (pair? groups)
          (let* ([g (car groups)]
                 [heading (and (car g)
                               (%text s (if (%placed? (cadr g)) 'transient:add! 'transient:add-computed!) (car g)))])
            (if (and (car g) (not heading))
                (loop (cdr groups) acc)
                (let ([datums (group-datums (cdr g))])
                  (loop (cdr groups)
                        (if (null? datums)
                            acc
                            (cons (apply %group '() (if heading (cons (%heading (list (cons 'text heading))) datums) datums))
                                  acc))))))
          (let ([last (let each ([bs (keys:bindings menu)] [acc '()])
                        (cond
                          [(null? bs) (reverse acc)]
                          [(let ([b (cdar bs)]) (or (eq? b press) (not (or (table? b) (commands:command? b)))))
                           (each (cdr bs) acc)]
                          [else
                           (set! drawn (cons (car bs) drawn))
                           (each (cdr bs)
                                 (cons (%entry-atom (list (cons 'key (caar bs)) (cons 'description (%binding-description (cdar bs)))))
                                       acc))]))])
            (values (apply %root '()
                      (append (if title (list (%title (list (cons 'text title)))) '())
                              (reverse acc)
                              (if (null? last) '() (list (apply %group '() last)))))
                    drawn))))))

(define %buffer
  (let ([b (or (buffers:find " *transient*") (buffers:make " *transient*" (%root '())))])
    (let ([doc (buffers:document b)])
      (unless (equal? (document:datums doc) (list (%root '())))
        (buffers:splice! b 0 (document:length doc) (document:from-datum (%root '())))))
    b))

(define (%write! datum)
  (let ([doc (buffers:document %buffer)])
    (unless (equal? (document:datums doc) (list datum))
      (buffers:splice! %buffer 0 (document:length doc) (document:from-datum datum)))))

(define %popup-id #f)

(define (%popup-view) (and %popup-id (%live-view %popup-id)))

(define (%display-action b) (layout-float:display-palette b 'content))

(define (%display!)
  (unless (%popup-view)
    (let ([v (as-module (this-module) (layout:display-buffer %buffer %display-action))])
      (set! %popup-id (views:id v)))))

(define (%hide!)
  (let ([v (%popup-view)])
    (set! %popup-id #f)
    (when v
      (let ([node (or (layout:view-node v) (layout:popup-node v))])
        (when node (layout:delete-part! node)))))
  (%write! (%root '())))

(define (%draw!)
  (unless (null? %stack)
    (let* ([s (car %stack)] [v (%menu-view s)])
      (if v
          (let-values ([(datum drawn) (views:call-with-view v (lambda () (%build s)))])
            (%showing-drawn-set! s drawn)
            (%write! datum))
          (%close-all!)))))

(define (%close-all!)
  (set! %stack '())
  (%hide!))

(define (%close! s)
  (set! %stack (remq s %stack))
  (if (null? %stack) (%hide!) (%draw!)))

(define (%close-menu! menu)
  (let ([shown (filter (lambda (s) (eq? (%showing-menu s) menu)) %stack)])
    (unless (null? shown)
      (set! %stack (filter (lambda (s) (not (memq s shown))) %stack))
      (if (null? %stack) (%hide!) (%draw!)))))

(define (show! menu)
  (%check-main-thread 'transient:show!)
  (%check-menu 'transient:show! menu)
  (unless (and (pair? %stack) (eq? (%showing-menu (car %stack)) menu))
    (let ([v (layout:selected-view)])
      (set! %stack (cons (%make-showing menu (views:id v) (%initial-arguments menu v) '() '() '()) %stack))
      (%draw!)
      (%display!))))

(define (buffer? b)
  (unless (buffers:buffer? b)
    (assertion-violation 'transient:buffer? "not a buffer" b))
  (eq? b %buffer))

;; A chosen command's task may pause, as at a valued switch's prompt;
;; keys meanwhile run in other tasks, and go to the prompt, not the
;; menus. A chosen command that escapes ends its run without saying so,
;; so its own task, or a task that has finished, holds no choice open.
(define-record-type (%choice %make-choice %choice?)
  (sealed #t)
  (fields task (mutable ended?)))

(define %choice-running #f)

(define (%running?)
  (let ([c %choice-running])
    (and c (not (%choice-ended? c))
         (let ([t (%choice-task c)])
           (and t (not (eq? t (current-task))) (not (task-done? t)))))))

(define (%keymaps client posn)
  (if (and (not posn) (pair? %stack) (not (%running?)))
      (list (%showing-menu (car %stack)) keymap)
      '()))

(define (%leave command)
  (when (and (pair? %stack) (keys:command-keys) (not (%running?))
             (not (eq? command press)) (not (eq? command quit)) (not (eq? command %keep-prefix))
             (not (table-ref staying-commands command #f)))
    (%close-all!)))

(define (%pressed-key)
  (let ([e (keys:command-event)])
    (if (keys:event? e)
        (let* ([posn (keys:event-start e)] [v (views:posn-view posn)] [p (views:posn-point posn)])
          (and v p (eq? (views:buffer v) %buffer)
               (let ([doc (buffers:document %buffer)])
                 (and (fx< p (document:length doc))
                      (let ([t (document:token doc p)])
                        (and (document:node? t) (document:atom? t) (eq? (document:node-kind t) %entry-atom-kind)
                             (document:node-attribute t 'key #f)))))))
        (keys:command-keys))))

(define (%run-command menu argument-list e)
  (parameterize ([%chosen (cons menu argument-list)])
    (apply commands:run (%entry-command e) (%entry-command-arguments e))))

(define (%act! s e)
  (case (%entry-type e)
    [(command)
     (let ([argument-list (list-copy (%showing-arguments s))])
       (%close-all!)
       (%run-command (%showing-menu s) argument-list e))]
    [(staying) (%run-command (%showing-menu s) (list-copy (%showing-arguments s)) e)]
    [(switch)
     (let ([argument (%entry-argument e)])
       (if (member argument (%showing-arguments s))
           (%showing-arguments-set! s (remove argument (%showing-arguments s)))
           (%put-in! s argument)))]
    [(valued)
     (let* ([argument (%entry-argument e)] [have (%valued-in (%showing-arguments s) argument)])
       (if have
           (%showing-arguments-set! s (remove have (%showing-arguments s)))
           (let* ([d (%entry-description e)]
                  [answer ((%entry-reader e) (string-append (if (procedure? d) (d) d) ": "))])
             (unless (string? answer)
               (assertion-violation 'transient:press "a reader returned what is not a string" answer))
             (unless (string=? answer "")
               (%put-in! s (string-append argument answer))))))]))

(commands:define-command (press)
  "Runs, in the menu's view, the entry the top menu drew for the keys that ran it, or for the entry clicked."
  (cond
    [(null? %stack) (%warn "no menu is open")]
    [(%running?) (%warn "a command chosen in a menu is running")]
    [else
     (let* ([s (car %stack)] [key (%pressed-key)] [drawn (and key (assoc key (%showing-drawn s)))]
            [v (%menu-view s)])
       (cond
         [(not v) (%close-all!)]
         [(and drawn (entry? (cdr drawn)))
          (let ([c (%make-choice (current-task) #f)])
            (set! %choice-running c)
            (views:call-with-view v (lambda () (%act! s (cdr drawn))))
            (%choice-ended?-set! c #t)
            (%draw!))]
         [(and drawn (table? (cdr drawn))) (show! (cdr drawn))]
         [drawn
          (%close-all!)
          (views:call-with-view v (lambda () (commands:run (cdr drawn))))]
         [else (%warn (format "~a is not in this menu" (or key "the key")))]))]))

(commands:define-command (%keep-prefix)
  "Keeps the prefix argument for the click that follows a press on an entry."
  (keys:set-prefix-argument! (commands:prefix-argument)))

(commands:define-command (quit)
  "Closes the top menu; the one below, if any, shows again with its arguments as they were."
  (unless (null? %stack)
    (%close! (car %stack))))

(define (%keep-buffer b) (not (eq? b %buffer)))

(define %quit (record-constructor (record-constructor-descriptor &quit)))

;; A chosen command paused at a prompt would resume into this module's
;; definitions, which raise once it has unloaded.
(define (%quit-chosen!)
  (let ([c %choice-running])
    (when (and c (not (%choice-ended? c)))
      (let ([t (%choice-task c)])
        (when (and t (not (eq? t (current-task))) (not (task-done? t)))
          (signal-task t (%quit)))))))

(define (%unload)
  (for-each (lambda (registered) (set-box! registered #f)) %registered)
  (%quit-chosen!)
  (%close-all!)
  (remove-hook! buffers:kill-queries %keep-buffer)
  (buffers:kill! %buffer))

(keys:bind! keymap "C-g" quit)
(keys:bind! keymap "ESC" quit)
(keys:bind! keymap "<printing-char>" press)
(keys:remap! keymap keys:keyboard-quit quit)
(keys:bind! %root-keys "<down-mouse-1>" keys:ignore)
(keys:bind! %root-keys "<mouse-1>" keys:ignore)
(keys:bind! %root-keys "<drag-mouse-1>" keys:ignore)
(keys:bind! %root-keys "<mouse-2>" keys:ignore)
(keys:bind! %root-keys "<mouse-3>" keys:ignore)
(keys:bind! %entry-keys "<down-mouse-1>" %keep-prefix)
(keys:bind! %entry-keys "<mouse-1>" press)
(keys:bind! %entry-keys "<mouse-2>" press)
(keys:bind! %entry-keys "<drag-mouse-1>" keys:ignore)
(for-each (lambda (c) (table-set! staying-commands c))
          (list keys:universal-argument keys:digit-argument keys:negative-argument keys:ignore keys:undefined))
(table-set! commands:command-modes press '())
(table-set! commands:command-modes quit '())
(table-set! commands:command-modes %keep-prefix '())
(table-set! web:stylesheets 'transient "transient/transient.css")
(add-hook! keys:find-keymaps %keymaps -50)
(add-hook! commands:before-command %leave)
(add-hook! buffers:kill-queries %keep-buffer)
(advice-add! batch-ended
  (lambda (ended)
    (guard (c [#t (report c)]) (as-module (this-module) (%draw!)))
    (ended)))
(on-unload %unload)

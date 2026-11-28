#!tuna
(import (projects) (markdown) (ask) (buffers) (document) (views) (layout) (keys) (commands) (modes)
        (status-line) (ui) (kill-ring) (files) (editing) (faces) (web) (haml) (hooks) (options) (tables) (saved))

(define %self (current-owner))

(tables:define-table sources "Each source's name to its description, from chat:define-source.")

(tables:define-table block-kinds "The kinds that fold, each a kind's constructor.")

(tables:define-table status-menus "Each source's name to the command a click on its chats' status segment runs.")

(options:define-option default-source #f (lambda (v) (or (not v) (symbol? v)))
  "The source chat:toggle and chat:add-region start a conversation with when the project has no chat; #f for the source of the chat used last.")

(options:define-option thinking-shown? #f boolean? "Whether an agent's finished thinking stays unfolded.")

(tables:define-table keymap "Keys anywhere in a chat.")

(tables:define-table prompt-keymap "Keys in a chat's prompt.")

(tables:define-table transcript-keymap "Keys in the conversation above a chat's prompt.")

(tables:define-table question-keymap "Keys in one of an agent's questions.")

(tables:define-table answers-keymap "Keys on a question's list of answers.")

(tables:define-table status-keymap "Clicks on a chat's status segment.")

(hooks:define-hook %mode-hook)

(modes:define-major-mode mode (lighter "Chat") (keymap keymap) (hook %mode-hook) (plugin-only #t))

(define (%tail) (options:set-local! views:tail #t))

(define-enumeration delivery (next-step turn-end) %deliveries)

(define-enumeration level (info warning error) %levels)

(define-enumeration text-state (streaming live history) %text-states)

(define-condition-type &refused &error %make-refused refused?)

(define (refuse message)
  (unless (string? message)
    (assertion-violation 'chat:refuse "not a string" message))
  (raise (condition (%make-refused) (make-message-condition message))))

;; A source's procedures are called through the expressions that name
;; them, so advice on a source plugin's definitions reaches every chat.
(define-record-type (%source %make-source %source?)
  (sealed #t)
  (fields conversation? conversations title mode directory session start items item-key draw-item activity
          working? history drafts send cancel item-text location questions question-id draw-question answer
          cancel-question queue follow-up send-now take-queue refused? status commands above below kill fork
          last-reply))

(define (%checked-source s)
  (unless (symbol? (%source-mode s))
    (assertion-violation 'chat:source "not a mode" (%source-mode s)))
  (unless (saved:saved? (%source-history s))
    (assertion-violation 'chat:source "not saved data" (%source-history s)))
  (unless (saved:saved? (%source-drafts s))
    (assertion-violation 'chat:source "not saved data" (%source-drafts s)))
  s)

(define (%check-clause clause v)
  (unless (procedure? v)
    (assertion-violation 'chat:source (string-append "not a procedure for the " (symbol->string clause) " clause") v)))

(define (%check-title v)
  (unless (or (string? v) (procedure? v))
    (assertion-violation 'chat:source "not a string or a procedure for the title clause" v)))

;; Clause names are compared as symbols, so a source plugin whose own
;; definitions are named drafts or send can still write (drafts drafts).
(define-syntax source
  (lambda (x)
    (define fields
      '(conversation? conversations title mode directory session start items item-key draw-item activity
        working? history drafts send cancel item-text location questions question-id draw-question answer
        cancel-question queue follow-up send-now take-queue refused? status commands above below kill fork
        last-reply))
    (define plain-values '(mode history drafts))
    (define required
      '(conversation? conversations title mode directory session start items item-key draw-item activity
        working? history drafts send cancel))
    (define question-clauses '(questions question-id draw-question answer cancel-question))
    (define (invalid c) (syntax-violation 'chat:source "invalid clause" x c))
    (define (field-value name k e)
      (with-syntax ([k k] [e e])
        (cond
          [(memq name plain-values) #'e]
          [(eq? name 'title)
           #'(begin
               (%check-title e)
               (lambda (c) (let ([t e]) (if (procedure? t) (t c) t))))]
          [else
           #'(begin
               (%check-clause 'k e)
               (lambda arguments (apply e arguments)))])))
    (syntax-case x ()
      [(_ clause ...)
       (let loop ([clauses #'(clause ...)] [given '()])
         (if (null? clauses)
             (let ([missing (find (lambda (n) (not (assq n given))) required)]
                   [questions (filter (lambda (n) (assq n given)) question-clauses)])
               (when missing
                 (syntax-violation 'chat:source
                   (string-append "the " (symbol->string missing) " clause is required") x))
               (unless (or (null? questions) (= (length questions) (length question-clauses)))
                 (syntax-violation 'chat:source "the question clauses are given all or none" x))
               (with-syntax ([(e ...) (map (lambda (n)
                                             (let ([a (assq n given)])
                                               (if a (field-value n (cadr a) (cddr a)) #'#f)))
                                           fields)])
                 #'(%checked-source (%make-source e ...))))
             (let ([c (car clauses)])
               (syntax-case c ()
                 [(k e)
                  (identifier? #'k)
                  (let ([name (syntax->datum #'k)])
                    (unless (memq name fields) (invalid c))
                    (when (assq name given)
                      (syntax-violation 'chat:source "clause given twice" x c))
                    (loop (cdr clauses) (cons (cons* name #'k #'e) given)))]
                 [_ (invalid c)]))))]
      [_ (syntax-violation 'chat:source "expected (chat:source clause ...)" x)])))

(define-syntax define-source
  (lambda (x)
    (syntax-case x ()
      [(_ id clause ...)
       (identifier? #'id)
       #'(define-public id (%define-source! 'id (source clause ...)))]
      [_ (syntax-violation 'chat:define-source "expected (chat:define-source id clause ...)" x)])))

(define (%refuse-edits node edit) #f)

(define (%attribute node name) (document:node-attribute node name #f))

(define (%symbol-text v) (and v (symbol->string v)))

(define (%draw-chat node view)
  (haml (:div.chat (views:draw-children view node))))

(define (%draw-transcript node view)
  (haml (:div.chat-transcript (views:draw-children view node))))

(define (%draw-user-message node view)
  (haml (:div.chat-user-message (views:draw-children view node))))

(define (%draw-reply node view)
  (haml (:div.chat-reply ([data-stop (%symbol-text (%attribute node 'stop))]) (views:draw-children view node))))

(define (%draw-thinking node view)
  (haml (:div.chat-thinking ([data-open (%attribute node 'open)]) (views:draw-children view node))))

(define (%draw-tool-call node view)
  (haml (:div.chat-tool-call ([data-state (%symbol-text (%attribute node 'state))] [data-open (%attribute node 'open)])
          (views:draw-children view node))))

(define (%level-face level)
  (case level
    [(error) (symbol->string faces:error)]
    [(warning) (symbol->string faces:warning)]
    [else #f]))

(define (%draw-notice node view)
  (let ([level (%attribute node 'level)])
    (haml (:div.chat-notice ([data-level (%symbol-text level)] [data-face (%level-face level)])
            (views:draw-children view node)))))

(define (%draw-header node view)
  (haml (:div.chat-header (views:draw-children view node))))

(define (%draw-name node view)
  (haml (:span.chat-name (views:draw-children view node))))

(define (%draw-detail node view)
  (haml (:span.chat-detail (views:draw-children view node))))

(define (%draw-output node view)
  (haml (:div.chat-output (views:draw-children view node))))

(define (%draw-diff node view)
  (haml (:div.chat-diff (views:draw-children view node))))

(define (%draw-removed node view)
  (haml (:div.chat-removed ([data-face (symbol->string faces:diff.minus)]) (views:draw-children view node))))

(define (%draw-added node view)
  (haml (:div.chat-added ([data-face (symbol->string faces:diff.plus)]) (views:draw-children view node))))

(define (%draw-questions node view)
  (haml (:div.chat-questions (views:draw-children view node))))

(define (%draw-question node view)
  (haml (:div.chat-question (views:draw-children view node))))

(define (%draw-message node view)
  (haml (:div.chat-message (views:draw-children view node))))

(define (%draw-answers node view)
  (haml (:div.chat-answers (views:draw-children view node))))

(define (%draw-field node view)
  (haml (:div.chat-field ([data-lines (%attribute node 'lines)]) (views:draw-children view node))))

(define (%draw-actions node view)
  (haml (:div.chat-actions (views:draw-children view node))))

(define (%draw-queue node view)
  (haml (:div.chat-queue (views:draw-children view node))))

(define (%draw-queued node view)
  (haml (:div.chat-queued ([data-delivery (%symbol-text (%attribute node 'delivery))]) (views:draw-children view node))))

(define (%draw-tag node view)
  (haml (:span.chat-tag (views:draw-children view node))))

(define (%draw-source-parts node view)
  (haml (:div.chat-source-parts ([data-placement (%symbol-text (%attribute node 'placement))])
          (views:draw-children view node))))

(define (%draw-prompt node view)
  (haml (:div.chat-prompt (views:draw-children view node))))

;; A deletion puts back the line breaks it keeps, so only an edit that
;; adds one adds a line.
(define (%field-edit? node edit)
  (or (%attribute node 'lines)
      (<= (%line-breaks (buffers:edit-inserted edit)) (%line-breaks (buffers:edit-removed edit)))))

(define (%line-breaks piece)
  (let ([doc (buffers:piece-document piece)])
    (- (document:line doc (document:length doc)) 1)))

(buffers:define-kind %chat (content nodes) (consent %refuse-edits) (draw %draw-chat))
(buffers:define-kind transcript (content nodes) (consent %refuse-edits) (keymap transcript-keymap) (draw %draw-transcript))
(buffers:define-kind %item (content nodes) (consent %refuse-edits))
(buffers:define-kind user-message (content nodes) (consent %refuse-edits) (draw %draw-user-message))
(buffers:define-kind reply (content nodes) (consent %refuse-edits) (draw %draw-reply))
(buffers:define-kind thinking (content nodes) (consent %refuse-edits) (draw %draw-thinking))
(buffers:define-kind tool-call (content nodes) (consent %refuse-edits) (draw %draw-tool-call))
(buffers:define-kind notice (consent %refuse-edits) (draw %draw-notice))
(buffers:define-kind header (consent %refuse-edits) (draw %draw-header))
(buffers:define-kind name (inline) (consent %refuse-edits) (draw %draw-name))
(buffers:define-kind detail (inline) (consent %refuse-edits) (draw %draw-detail))
(buffers:define-kind output (consent %refuse-edits) (draw %draw-output))
(buffers:define-kind diff (content nodes) (consent %refuse-edits) (draw %draw-diff))
(buffers:define-kind removed (consent %refuse-edits) (draw %draw-removed))
(buffers:define-kind added (consent %refuse-edits) (draw %draw-added))
(buffers:define-kind %questions (content nodes) (consent %refuse-edits) (draw %draw-questions))
(buffers:define-kind question (content nodes) (consent %refuse-edits) (keymap question-keymap) (draw %draw-question))
(buffers:define-kind message (consent %refuse-edits) (draw %draw-message))
(buffers:define-kind answers (content nodes) (consent %refuse-edits) (keymap answers-keymap) (draw %draw-answers))
(buffers:define-kind field (isolating) (consent %field-edit?) (draw %draw-field))
(buffers:define-kind actions (stops children) (consent %refuse-edits) (draw %draw-actions))
(buffers:define-kind queue (content nodes) (consent %refuse-edits) (draw %draw-queue))
(buffers:define-kind %queued (consent %refuse-edits) (draw %draw-queued))
(buffers:define-kind %tag (inline) (consent %refuse-edits) (draw %draw-tag))
(buffers:define-kind %source-parts (content nodes) (consent %refuse-edits) (draw %draw-source-parts))
(buffers:define-kind prompt (isolating) (keymap prompt-keymap) (draw %draw-prompt))

;; The transcript holds Markdown's kinds, which take edits as text does.
(buffers:define-layer %read-only (read-only))

;; A buffer outlives this module's reloads; the marks on its root find it
;; again.

(define %buffers (make-eq-hashtable))

(define %claims (make-weak-eq-hashtable))

(define %used '())

(define %dirty '())

(define %drafts-changed? #f)

(define %draft-sessions (make-weak-eq-hashtable))

(define %folds (make-hashtable equal-hash equal?))

;; Questions are numbered in the order they are first drawn: two drawn
;; in one millisecond would tie on the clock, and the older must still
;; come first.
(define %question-seen (make-hashtable equal-hash equal?))

(define %questions-drawn 0)

(define %own-notices (make-eq-hashtable))

(define %written-transcripts (make-weak-eq-hashtable))

(define %item-datums (make-weak-eq-hashtable))

(define %datums-version 0)

(define %history-place (make-eq-hashtable))

(define (%exported-symbol id)
  (let ([owner (owner-name (current-owner))])
    (if (member owner '((init) (repl)))
        id
        (string->symbol
          (call-with-string-output-port
            (lambda (p)
              (let loop ([parts owner])
                (display (car parts) p)
                (unless (null? (cdr parts))
                  (put-char p #\/)
                  (loop (cdr parts))))
              (put-char p #\:)
              (display id p)))))))

(define (%source-entries) (tables:entries sources))

(define (%entry-of c)
  (find (lambda (entry) ((%source-conversation? (cdr entry)) c)) (%source-entries)))

(define (%check-conversation who c)
  (or (%entry-of c) (assertion-violation who "not a chat" c)))

(define (conversation? v) (and (%entry-of v) #t))

(define (%live? entry c)
  (and (memq c ((%source-conversations (cdr entry)))) #t))

(define (%live-entries)
  (apply append
    (map (lambda (entry) (map (lambda (c) (cons entry c)) ((%source-conversations (cdr entry)))))
         (%source-entries))))

(define (%title entry c) ((%source-title (cdr entry)) c))

(define (%mark-dirty! c)
  (unless (memq c %dirty)
    (set! %dirty (cons c %dirty))))

(define (%use! c)
  (set! %used (cons c (remq c %used))))

(define (%folder-name dir)
  (let* ([d (%without-slash dir)] [i (let loop ([i (string-length d)])
                                        (cond [(fx= i 0) 0] [(char=? (string-ref d (fx- i 1)) #\/) i] [else (loop (fx- i 1))]))])
    (if (fx= i (string-length d)) d (substring d i (string-length d)))))

(define (%without-slash dir)
  (if (and (fx> (string-length dir) 1) (char=? (string-ref dir (fx- (string-length dir) 1)) #\/))
      (%without-slash (substring dir 0 (fx- (string-length dir) 1)))
      dir))

(define (%with-slash dir)
  (if (and (fx> (string-length dir) 0) (char=? (string-ref dir (fx- (string-length dir) 1)) #\/))
      dir
      (string-append dir "/")))

;; projects:find walks a folder upward as text, and buffer names and
;; references are taken from it as text, so a chat started in a folder
;; written with .. would otherwise fall in another project.
(define (%directory entry c)
  (files:expanded-path ((%source-directory (cdr entry)) c)))

(define (%session entry c) ((%source-session (cdr entry)) c))

(define (%buffer-name entry c)
  (let ([base (string-append "*" (string-downcase (%title entry c)) ": " (%folder-name (%directory entry c)) "*")])
    (let loop ([n 1])
      (let ([name (if (fx= n 1) base (string-append base "<" (number->string n) ">"))])
        (if (buffers:find name) (loop (fx+ n 1)) name)))))

(define (%drafts entry) ((%source-drafts (cdr entry))))

(define (%draft-of entry c)
  (let ([session (%session entry c)])
    (cond [(and session (assoc session (%drafts entry))) => cdr] [else ""])))

(define (%marks entry c)
  (let ([session (%session entry c)])
    (if session
        (list (cons 'source (car entry)) (cons 'session session))
        (list (cons 'source (car entry))))))

(define (%make-buffer! entry c)
  (let ([b (buffers:make (%buffer-name entry c)
             (%chat (%marks entry c) (transcript '()) (%questions '()) (queue '())
                    (%source-parts '((placement . above))) (prompt '() (%draft-of entry c) "\n")
                    (%source-parts '((placement . below)))))])
    (modes:set-major-mode (%source-mode (cdr entry)) b)
    b))

(define (%root b) (document:token (buffers:document b) 0))

(define (%chat-root? b)
  (let ([doc (buffers:document b)])
    (and (fx> (document:length doc) 0)
         (let ([root (%root b)]) (and (document:node? root) (eq? (document:node-kind root) 'chat:%chat))))))

(define (%claimant b)
  (let ([c (hashtable-ref %claims b #f)])
    (and c (let ([entry (%entry-of c)]) (and entry (%live? entry c) c)))))

(define (%marked-buffer entry c)
  (let ([session (%session entry c)])
    (and session
         (find (lambda (b)
                 (and (%chat-root? b)
                      (eq? (%attribute (%root b) 'source) (car entry))
                      (equal? (%attribute (%root b) 'session) session)
                      (not (%claimant b))))
               (buffers:all)))))

(define (%claim! c b session)
  (let-values ([(conversations buffers) (hashtable-entries %buffers)])
    (vector-for-each (lambda (other other-buffer)
                       (when (and (eq? other-buffer b) (not (eq? other c)))
                         (hashtable-delete! %buffers other)))
                     conversations buffers))
  (hashtable-set! %buffers c b)
  (hashtable-set! %claims b c)
  (unless (hashtable-contains? %draft-sessions c)
    (hashtable-set! %draft-sessions c session)))

(define (%buffer-of entry c)
  (let ([b (hashtable-ref %buffers c #f)])
    (if (and b (buffers:live? b))
        b
        (let ([b (or (%marked-buffer entry c) (%make-buffer! entry c))])
          (%claim! c b (%session entry c))
          b))))

;; A source's buffers are found when it is defined, before its code runs
;; again, so a conversation that moves to another session after a reload
;; of chat is still found by the session its buffer was marked with.
(define (%define-source! id s)
  (let ([name (%exported-symbol id)])
    (tables:set! sources name s)
    (for-each (lambda (c)
                (let ([entry (cons name s)])
                  (%buffer-of entry c)
                  (%mark-dirty! c)))
              ((%source-conversations s)))
    name))

(define (buffer c)
  (%buffer-of (%check-conversation 'chat:buffer c) c))

(define (conversation-of b)
  (unless (buffers:buffer? b)
    (assertion-violation 'chat:conversation-of "not a buffer" b))
  (let ([c (%claimant b)])
    (and c (eq? (hashtable-ref %buffers c #f) b) c)))

(define (current)
  (let* ([v (views:current)] [b (and v (views:buffer v))])
    (and b (conversation-of b))))

(define (%current-conversation who)
  (or (current) (error who "not in a chat")))

(define (activity c)
  ((%source-activity (cdr (%check-conversation 'chat:activity c))) c))

(define (commands c)
  (let ([commands (%source-commands (cdr (%check-conversation 'chat:commands c)))])
    (if commands (commands c) '())))

(define (%children node)
  (let ([acc '()])
    (document:for-each-child node (fx+ (document:node-start node) 1) (fx- (document:node-end node) 1)
      (lambda (c at) (when (document:node? c) (set! acc (cons c acc)))))
    (reverse acc)))

(define (%child-of node kinds)
  (find (lambda (c) (memq (document:node-kind c) kinds)) (%children node)))

(define (%part b kind . attributes)
  (find (lambda (c)
          (and (eq? (document:node-kind c) kind)
               (for-all (lambda (a) (equal? (%attribute c (car a)) (cdr a))) attributes)))
        (%children (%root b))))

(define (%prompt-node b) (%part b 'chat:prompt))

(define (%prompt-start b) (fx+ (document:node-start (%prompt-node b)) 1))

(define (%prompt-end b) (fx- (document:node-end (%prompt-node b)) 2))

(define (%prompt-text b)
  (document:text (buffers:document b) (%prompt-start b) (%prompt-end b)))

(define (%set-prompt-text! b text)
  (let ([n (%prompt-node b)])
    (buffers:splice! b (fx+ (document:node-start n) 1) (fx- (document:node-end n) 1)
                     (document:from-datum (string-append text "\n")))
    (set! %drafts-changed? #t)))

(define (prompt-start c)
  (%prompt-start (buffer c)))

(define (prompt-end c)
  (%prompt-end (buffer c)))

(define (%enclosing-of b position kinds)
  (let ([doc (buffers:document b)])
    (let loop ([n (document:enclosing doc position)])
      (cond
        [(not n) #f]
        [(memq (document:node-kind n) kinds) n]
        [else (loop (document:enclosing doc (document:node-start n)))]))))

(define (%place)
  (let ([e (keys:command-event)])
    (if (and (keys:event? e) (keys:event-start e))
        (values (views:posn-view (keys:event-start e)) (views:posn-point (keys:event-start e)))
        (let ([v (views:current)]) (values v (and v (views:point v)))))))

;; Finished text is converted once and kept while its string lives. A
;; weak table hands its procedures the broken-weak-pair object once a key
;; is collected, so they take any value.
(define %block-cache
  (make-weak-hashtable (lambda (s) (if (string? s) (string-hash s) 0))
                       (lambda (a b) (and (string? a) (string? b) (string=? a b)))))

(define %converting (make-hashtable string-hash string=?))

(define %waiting-texts '())

(define (%finished-blocks text now?)
  (or (hashtable-ref %block-cache text #f)
      (if now?
          (let ([blocks (markdown:blocks text)])
            (hashtable-set! %block-cache text blocks)
            blocks)
          (begin
            (unless (hashtable-contains? %converting text)
              (hashtable-set! %converting text #t)
              (set! %waiting-texts (cons text %waiting-texts)))
            (%plain-blocks text)))))

(define (%plain-blocks text)
  (if (string=? text "")
      '()
      (list (list 'markdown:paragraph '((key . 0))
                  (if (char=? (string-ref text (fx- (string-length text) 1)) #\newline) text (string-append text "\n"))))))

;; History is converted on a thread of this plugin's own, which posts the
;; blocks back, since a long session's Markdown takes seconds.
(define (%convert-waiting!)
  (unless (null? %waiting-texts)
    (let ([texts %waiting-texts])
      (set! %waiting-texts '())
      (fork-task
        (lambda (restore)
          (let ([results (map (lambda (text)
                                (guard (c [#t (list text (%plain-blocks text) c)])
                                  (list text (markdown:blocks text) #f)))
                              texts)])
            (spawn-task
              (lambda (restore)
                (for-each (lambda (r)
                            (hashtable-delete! %converting (car r))
                            (hashtable-set! %block-cache (car r) (cadr r))
                            (when (caddr r) (report (caddr r))))
                          results)
                (%datums-changed!)
                (for-each (lambda (p) (%mark-dirty! (cdr p))) (%live-entries))))))))))

(define (%rekey blocks prefix)
  (map (lambda (b)
         (if (pair? b)
             (let ([key (cond [(assq 'key (cadr b)) => cdr] [else #f])])
               (cons (car b) (cons (cons (cons 'key (cons prefix key)) (remp (lambda (a) (eq? (car a) 'key)) (cadr b)))
                                   (cddr b))))
             b))
       blocks))

(define (markdown-blocks text state key)
  (unless (string? text)
    (assertion-violation 'chat:markdown-blocks "not a string" text))
  (unless (enum-set-member? state %text-states-universe)
    (assertion-violation 'chat:markdown-blocks "not a text state" state))
  (%rekey (case state
            [(streaming) (markdown:unfinished-blocks text)]
            [(live) (%finished-blocks text #t)]
            [else (%finished-blocks text #f)])
          key))

(define %text-states-universe (enum-set-universe (%text-states streaming)))

(define (%line s) (if (and (fx> (string-length s) 0) (char=? (string-ref s (fx- (string-length s) 1)) #\newline)) s (string-append s "\n")))

(define (%join strings separator)
  (if (null? strings)
      '()
      (cons (car strings) (apply append (map (lambda (s) (list separator s)) (cdr strings))))))

;; Places restart at 0 in a new session, so a fold is the session's.
(define (%fold-key entry c item-key part-key)
  (list c (%session entry c) item-key part-key))

(define (%open? entry c item-key part-key default)
  (let ([v (hashtable-ref %folds (%fold-key entry c item-key part-key) 'unset)])
    (if (eq? v 'unset) default v)))

;; An item's datum is made again only when the item, the folds or the
;; converted text change: making every item's datum at each batch took
;; most of a batch for a long session.
(define (%datums-changed!) (set! %datums-version (fx+ %datums-version 1)))

(define (%item-datum entry c item)
  (let ([s (cdr entry)])
    (let ([k ((%source-item-key s) item)])
      ((%source-draw-item s) c item (lambda (part-key default) (%open? entry c k part-key default))))))

(define (%cached-item-datum entry c item)
  (let ([cached (hashtable-ref %item-datums item #f)] [shown? (thinking-shown?)])
    (if (and cached (fx= (vector-ref cached 0) %datums-version) (eq? (vector-ref cached 1) shown?))
        (vector-ref cached 2)
        (let ([d (%item-datum entry c item)])
          (hashtable-set! %item-datums item (vector %datums-version shown? d))
          d))))

(define (%notice-datum? d) (and (pair? d) (eq? (car d) 'chat:notice)))

(define (%transcript-datums entry c)
  (let ([own (reverse (hashtable-ref %own-notices c '()))])
    (let loop ([items ((%source-items (cdr entry)) c)] [own own] [n 0] [acc '()])
      (cond
        [(and (pair? own) (<= (car (car own)) n))
         (loop items (cdr own) n (cons (cdr (car own)) acc))]
        [(null? items) (append (reverse acc) (map cdr own))]
        [else
         (let ([d (%cached-item-datum entry c (car items))])
           (loop (cdr items) own (if (%notice-datum? d) n (fx+ n 1)) (if d (cons d acc) acc)))]))))

;; A notice of the chat's own, such as a refusal, is not among the
;; agent's items, so it is placed after the item it came after.
(define (%notice! entry c level text)
  (let* ([count (fold-left (lambda (n i) (if (%notice-datum? (%cached-item-datum entry c i)) n (fx+ n 1)))
                           0 ((%source-items (cdr entry)) c))]
         [own (hashtable-ref %own-notices c '())]
         [key (cons 'own (length own))])
    (hashtable-set! %own-notices c
      (cons (cons count (notice (list (cons 'key key) (cons 'level level)) (%line text))) own))
    (%mark-dirty! c)))

(define (notice! c level text)
  (let ([entry (%check-conversation 'chat:notice! c)])
    (unless (enum-set-member? level (enum-set-universe (%levels info)))
      (assertion-violation 'chat:notice! "not a level" level))
    (unless (string? text)
      (assertion-violation 'chat:notice! "not a string" text))
    (%notice! entry c level text)))

(define (%question-id entry q) ((%source-question-id (cdr entry)) q))

(define (%question-node-of b id)
  (find (lambda (n) (equal? (%attribute n 'key) id)) (%children (%part b 'chat:%questions))))

(define (%question-of entry c node)
  (let ([questions (%source-questions (cdr entry))] [id (%attribute node 'key)])
    (and questions (find (lambda (q) (equal? (%question-id entry q) id)) (questions c)))))

(define (%answer-field answer name) (cond [(assq name answer) => cdr] [else #f]))

(define (%question-datum entry c q)
  (let ([d ((%source-draw-question (cdr entry)) c q)])
    (unless (and (pair? d) (eq? (car d) 'chat:question))
      (assertion-violation 'chat:source "not a chat:question datum from the draw-question clause" d))
    (cons* (car d)
           (cons (cons 'key (%question-id entry q)) (remp (lambda (a) (eq? (car a) 'key)) (cadr d)))
           (map (lambda (part)
                  (if (and (pair? part) (eq? (car part) 'chat:answers))
                      (list (car part) (cadr part) (ui:list '((key . options))))
                      part))
                (cddr d)))))

(define (%show-answers! entry c b q node)
  (let* ([answers-node (%child-of node '(chat:answers))] [list-node (and answers-node (%child-of answers-node '(ui:list)))])
    (when list-node
      (let ([answers (list->vector (%attribute answers-node 'answers))])
        (ui:set-rows! b list-node (vector-length answers)
          (lambda (i) (ui:label (%answer-field (vector-ref answers i) 'label)))
          (lambda (i) ((%source-answer (cdr entry)) c q (%answer-field (vector-ref answers i) 'value))))))))

;; A question's node is written once and removed once, never rewritten,
;; so what is typed in its field stays, through a reload of the source too.
(define (%write-questions! entry c b)
  (let* ([questions ((%source-questions (cdr entry)) c)] [ids (map (lambda (q) (%question-id entry q)) questions)])
    (let remove ()
      (let ([gone (find (lambda (n) (not (member (%attribute n 'key) ids))) (%children (%part b 'chat:%questions)))])
        (when gone
          (hashtable-delete! %question-seen (cons (car entry) (%attribute gone 'key)))
          (buffers:splice! b (document:node-start gone) (document:node-end gone) (document:from-datum))
          (remove))))
    (for-each
      (lambda (q id)
        (unless (hashtable-contains? %question-seen (cons (car entry) id))
          (set! %questions-drawn (fx+ %questions-drawn 1))
          (hashtable-set! %question-seen (cons (car entry) id) %questions-drawn))
        (unless (%question-node-of b id)
          (let ([at (fx- (document:node-end (%part b 'chat:%questions)) 1)])
            (buffers:splice! b at at (document:from-datum (%question-datum entry c q)))
            (%show-answers! entry c b q (%question-node-of b id)))))
      questions ids)))

(define (%tag-text d) (if (eq? d (delivery next-step)) "Steer" "Follow-up"))

(define (%queue-datums entry c)
  (let ([queue (%source-queue (cdr entry))])
    (if queue
        (map (lambda (p) (%queued (list (cons 'delivery (car p))) (%tag '() (%tag-text (car p))) " " (%line (cdr p))))
             (queue c))
        '())))

(define (%parts-datums entry c placement)
  (let ([parts (if (eq? placement 'above) (%source-above (cdr entry)) (%source-below (cdr entry)))])
    (if parts (parts c) '())))

(define (%datum-key datum) (cdr (assq 'key (cadr datum))))

(define (%wrap datum) (%item (list (cons 'key (%datum-key datum))) datum))

;; What a buffer's transcript was last written with: each item's datum
;; and its length in the document, so a rewrite finds and touches only the
;; items that changed. Reconciling the whole transcript reads all of it,
;; which takes seconds for a long session.
(define-record-type (%written %make-written %written?)
  (sealed #t)
  (fields (immutable datums %written-datums) (immutable lengths %written-lengths)))

(define (%node-length doc at) (fx- (document:node-end (document:token doc at)) at))

(define (%measure-items! lengths doc from at)
  (let loop ([j from] [at at])
    (when (fx< j (vector-length lengths))
      (let ([n (%node-length doc at)])
        (vector-set! lengths j n)
        (loop (fx+ j 1) (fx+ at n))))))

;; Each item sits in an %item node whose attributes never change, so one
;; item is reconciled alone, its own attributes included.
(define (%write-transcript! entry c b)
  (let* ([t (%part b 'chat:transcript)] [first (fx+ (document:node-start t) 1)]
         [new (list->vector (%transcript-datums entry c))] [lengths (make-vector (vector-length new) 0)]
         [old (hashtable-ref %written-transcripts b #f)])
    (hashtable-delete! %written-transcripts b)
    (if old
        (let* ([old-datums (%written-datums old)] [old-lengths (%written-lengths old)]
               [shared (let loop ([j 0])
                         (if (and (fx< j (vector-length old-datums)) (fx< j (vector-length new))
                                  (equal? (%datum-key (vector-ref old-datums j)) (%datum-key (vector-ref new j))))
                             (loop (fx+ j 1))
                             j))]
               [starts (let ([v (make-vector (fx+ shared 1))])
                         (let loop ([j 0] [at first])
                           (vector-set! v j at)
                           (if (fx= j shared) v (loop (fx+ j 1) (fx+ at (vector-ref old-lengths j))))))])
          (unless (and (fx= shared (vector-length old-datums)) (fx= shared (vector-length new)))
            (buffers:splice! b (vector-ref starts shared) (fx- (document:node-end t) 1)
              (apply document:from-datum
                (let loop ([j (fx- (vector-length new) 1)] [acc '()])
                  (if (fx< j shared) acc (loop (fx- j 1) (cons (%wrap (vector-ref new j)) acc))))))
            (%measure-items! lengths (buffers:document b) shared (vector-ref starts shared)))
          ;; From the last, so an item's edits move no item still to come.
          (do ([j (fx- shared 1) (fx- j 1)]) ((fx< j 0))
            (let ([at (vector-ref starts j)])
              (cond
                [(equal? (vector-ref old-datums j) (vector-ref new j))
                 (vector-set! lengths j (vector-ref old-lengths j))]
                [else
                 (buffers:reconcile! b (document:token (buffers:document b) at) (list (vector-ref new j)))
                 (vector-set! lengths j (%node-length (buffers:document b) at))]))))
        (begin
          (buffers:reconcile! b t (map %wrap (vector->list new)))
          (%measure-items! lengths (buffers:document b) 0 first)))
    (hashtable-set! %written-transcripts b (%make-written new lengths))))

;; reconcile! enters a node's children only, so the root's marks are
;; rewritten by putting a new opening in place of its own.
;; Folds are the session's, so a conversation that goes on in another
;; session with the same items draws them again with that session's folds.
(define (%write-marks! entry c b)
  (let ([marks (%marks entry c)] [root (%root b)])
    (unless (and (eq? (%attribute root 'source) (car entry))
                 (equal? (%attribute root 'session) (%session entry c)))
      (%datums-changed!)
      (buffers:splice! b 0 1 (document:slice (document:from-datum (%chat marks)) 0 1)))))

;; The conversation is rebuilt from the source's records, so its rewrites
;; are no history of the prompt's.
(define (%rewrite! entry c b)
  (buffers:with-silent-edits b
    (%write-marks! entry c b)
    (%write-transcript! entry c b)
    (when (%source-questions (cdr entry))
      (%write-questions! entry c b))
    (buffers:reconcile! b (%part b 'chat:queue) (%queue-datums entry c))
    (buffers:reconcile! b (%part b 'chat:%source-parts '(placement . above)) (%parts-datums entry c 'above))
    (buffers:reconcile! b (%part b 'chat:%source-parts '(placement . below)) (%parts-datums entry c 'below))
    (let ([t (%part b 'chat:transcript)])
      (buffers:set-spans! (buffers:layer b %read-only) 0 (document:length (buffers:document b))
        (list (list (document:node-start t) (document:node-end t) '()))))))

(define (%end! c)
  (let ([b (hashtable-ref %buffers c #f)])
    (hashtable-delete! %buffers c)
    (set! %used (remq c %used))
    (when (and b (eq? (hashtable-ref %claims b #f) c))
      (hashtable-delete! %claims b)
      (when (buffers:live? b)
        (spawn-task (lambda (restore) (when (buffers:live? b) (buffers:kill! b))))))))

(define (%redraw-dirty!)
  (let ([dirty %dirty])
    (set! %dirty '())
    (for-each
      (lambda (c)
        (let ([entry (%entry-of c)])
          (cond
            [(not entry)]
            [(%live? entry c) (%rewrite! entry c (%buffer-of entry c))]
            [else (%end! c)])))
      dirty)
    (%convert-waiting!)
    (for-each (lambda (p) (%take-draft! (car p) (cdr p))) (%live-entries))
    (let ([changed? %drafts-changed?])
      (set! %drafts-changed? #f)
      (for-each
        (lambda (entry)
          (let ([live ((%source-conversations (cdr entry)))])
            (when (or changed? (exists (lambda (c) (%draft-moved? entry c)) live))
              (let ([updated (fold-left
                               (lambda (ds c)
                                 (let ([b (hashtable-ref %buffers c #f)])
                                   (if (and b (buffers:live? b)) (%drafts-updated entry ds c (%prompt-text b)) ds)))
                               (%drafts entry) live)])
                (unless (equal? updated (%drafts entry))
                  (saved:set! (%source-drafts (cdr entry)) updated))))))
        (%source-entries)))))

;; A draft is its session's, read back when the session is opened again,
;; so it outlives the chat. The prompt keeps its text when its chat moves
;; to another session, so the draft moves too: the session left keeping
;; it would show text already sent or deleted when opened again.
(define (%drafts-updated entry ds c text)
  (let ([id (%session entry c)] [left (hashtable-ref %draft-sessions c #f)])
    (if (not id)
        ds
        (begin
          (hashtable-set! %draft-sessions c id)
          (let ([others (remp (lambda (d) (or (string=? (car d) id) (equal? (car d) left))) ds)])
            (if (string=? text "") others (cons (cons id text) others)))))))

(define (%draft-moved? entry c)
  (let ([left (hashtable-ref %draft-sessions c #f)])
    (and left (not (equal? left (%session entry c))))))

;; The session a chat moves into may keep a draft, as a killed chat's.
;; Saving the prompt over it would lose that text, so the draft joins the
;; prompt as a refused message does.
(define (%moved-draft entry c)
  (and (%draft-moved? entry c) (%session entry c) (assoc (%session entry c) (%drafts entry))))

(define (%take-draft! entry c)
  (let ([b (hashtable-ref %buffers c #f)] [d (%moved-draft entry c)])
    (when (and b (buffers:live? b) d)
      (%put-back! b (cdr d)))))

(define (%project-folder folder)
  (cond
    [(projects:find folder) => projects:root]
    [else (%with-slash folder)]))

(define (%chat-buffer-directory b)
  (let ([c (conversation-of b)])
    (and c (%directory (%entry-of c) c))))

(define (folder-for b)
  (unless (buffers:buffer? b)
    (assertion-violation 'chat:folder-for "not a buffer" b))
  (or (%chat-buffer-directory b) (%project-folder (files:directory b))))

(define (%project-of b)
  (%project-folder (files:directory b)))

(define (%in-project? project)
  (lambda (p) (string=? (%project-folder (%directory (car p) (cdr p))) project)))

(define (%check-source-name who v)
  (unless (and (symbol? v) (tables:ref sources v #f))
    (assertion-violation who "not a loaded source" v))
  v)

(define (%ordered-for b name)
  (let* ([live (filter (lambda (p) (or (not name) (eq? (car (car p)) name))) (%live-entries))]
         [used (filter values (map (lambda (c) (find (lambda (p) (eq? (cdr p) c)) live)) %used))]
         [ordered (append used (reverse (filter (lambda (p) (not (memq (cdr p) %used))) live)))])
    (if b
        (let-values ([(in out) (partition (%in-project? (%project-of b)) ordered)])
          (append in out))
        ordered)))

(define chats-for
  (case-lambda
    [(b) (chats-for b #f)]
    [(b name)
     (unless (or (not b) (buffers:buffer? b))
       (assertion-violation 'chat:chats-for "not a buffer or #f" b))
     (map cdr (%ordered-for b (and name (%check-source-name 'chat:chats-for name))))]))

(define (%last-in b name)
  (find (%in-project? (%project-of b)) (%ordered-for b name)))

(define (show! c)
  (let* ([entry (%check-conversation 'chat:show! c)] [b (%buffer-of entry c)])
    (%mark-dirty! c)
    (%use! c)
    (layout:switch-to-buffer b)
    (views:set-point! (layout:selected-view) (%prompt-end b))))

(define (changed! c)
  (%check-conversation 'chat:changed! c)
  (%mark-dirty! c))

(define (set-prompt! c text)
  (let ([entry (%check-conversation 'chat:set-prompt! c)])
    (unless (string? text)
      (assertion-violation 'chat:set-prompt! "not a string" text))
    (%set-prompt-text! (%buffer-of entry c) text)))

(define (add-to-prompt! c text)
  (let ([entry (%check-conversation 'chat:add-to-prompt! c)])
    (unless (string? text)
      (assertion-violation 'chat:add-to-prompt! "not a string" text))
    (let* ([b (%buffer-of entry c)] [current (%prompt-text b)])
      (%set-prompt-text! b (cond [(string=? current "") text]
                                 [(char=? (string-ref current (fx- (string-length current) 1)) #\newline)
                                  (string-append current text)]
                                 [else (string-append current "\n" text)])))))

(define (%joined text current)
  (if (string=? current "") text (string-append text "\n" current)))

(define (%put-back! b text)
  (%set-prompt-text! b (%joined text (%prompt-text b))))

(define (put-back! c text)
  (let ([entry (%check-conversation 'chat:put-back! c)])
    (unless (string? text)
      (assertion-violation 'chat:put-back! "not a string" text))
    (%put-back! (%buffer-of entry c) text)))

(define (%current-buffer)
  (let ([v (views:current)])
    (if v (views:buffer v) (error 'chat "no view is current"))))

(define (%default-source-name)
  (let ([chosen (default-source)])
    (cond
      [(and chosen (tables:ref sources chosen #f)) chosen]
      [(and (pair? %used) (%entry-of (car %used))) => car]
      [(pair? (%source-entries)) (car (car (%source-entries)))]
      [else (error 'chat "no chat source is loaded")])))

(define (%start! name folder)
  ((%source-start (tables:ref sources name #f)) folder))

(define open
  (case-lambda
    [(name) (open name #f)]
    [(name new?)
     (%check-source-name 'chat:open name)
     (let* ([b (%current-buffer)] [last (and (not new?) (%last-in b name))])
       (show! (if last (cdr last) (%start! name (folder-for b)))))]))

(commands:define-command (toggle)
  "Shows the chat used last in the current buffer's project, or removes the view showing it."
  (let* ([b (%current-buffer)] [last (%last-in b #f)]
         [v (and last (layout:find-view (%buffer-of (car last) (cdr last))))])
    (cond
      [(not v) (show! (if last (cdr last) (%start! (%default-source-name) (folder-for b))))]
      [(layout:deletion-refusal (layout:view-node v))
       (let ([skip? (views:skipped-buffer-predicate)])
         (options:with ([views:skipped-buffer-predicate (lambda (view o reason) (or (skip? view o reason) (conversation-of o)))])
           (views:replace-buffer! v)
           (void)))]
      [else (layout:delete-part! (layout:view-node v))])))

(define (%relative dir path)
  (let ([d (string-append (%without-slash dir) "/")])
    (if (and (fx>= (string-length path) (string-length d)) (string=? (substring path 0 (string-length d)) d))
        (substring path (string-length d) (string-length path))
        path)))

(define (%region-text entry c b start end)
  (let* ([doc (buffers:document b)] [path (files:path b)]
         [first (document:line doc start)]
         [last (document:line doc (if (and (fx> end start) (eqv? (document:token doc (fx- end 1)) #\newline))
                                      (fx- end 1)
                                      end))])
    (if (and path (not (buffers:modified? b)))
        (string-append (%relative (%directory entry c) path) ":" (number->string first)
                       (if (fx= first last) "" (string-append "-" (number->string last))))
        (string-append "```" (buffers:name b) " lines " (number->string first) "-" (number->string last) "\n"
                       (%line (buffers:text-between doc start end)) "```"))))

(define (region-text c b start end)
  (let ([entry (%check-conversation 'chat:region-text c)])
    (unless (buffers:buffer? b)
      (assertion-violation 'chat:region-text "not a buffer" b))
    (unless (and (fixnum? start) (fixnum? end) (fx<= 0 start end (document:length (buffers:document b))))
      (assertion-violation 'chat:region-text "not a start and an end in the buffer" start end))
    (%region-text entry c b start end)))

(commands:define-command (add-region)
  "Adds the region to the prompt of the chat used last in its project, and shows the chat; asks to start one when there is none."
  (let* ([v (views:current)] [b (views:buffer v)] [mark (views:mark v)])
    (unless mark
      (error 'chat:add-region "the region is empty"))
    (let ([c (cond
               [(%last-in b #f) => cdr]
               [else
                (let* ([name (%default-source-name)] [folder (folder-for b)])
                  (and (ask:y-or-n? (string-append "Start a " (%title (cons name (tables:ref sources name #f)) #f)
                                                   " chat in " (files:abbreviated-path folder) "? "))
                       (%start! name folder)))])])
      (when c
        (add-to-prompt! c (%region-text (%entry-of c) c b (fxmin mark (views:point v)) (fxmax mark (views:point v))))
        (show! c)))))

(define (%waiting-questions)
  (apply append
    (map (lambda (p)
           (let ([questions (%source-questions (cdr (car p)))])
             (if questions (map (lambda (q) (list (car p) (cdr p) q)) (questions (cdr p))) '())))
         (%live-entries))))

(define (%seen w)
  (hashtable-ref %question-seen (cons (car (car w)) (%question-id (car w) (caddr w))) +inf.0))

(commands:define-command (next-question)
  "Shows the chat whose question has waited longest, point where it is answered: at the end of its field's text, on its first answer or on its first button."
  (let ([waiting (%waiting-questions)])
    (when (null? waiting)
      (error 'chat:next-question "no question waits"))
    (let* ([oldest (fold-left (lambda (best w) (if (< (%seen w) (%seen best)) w best)) (car waiting) (cdr waiting))]
           [entry (car oldest)] [c (cadr oldest)] [b (%buffer-of entry c)])
      (%rewrite! entry c b)
      (show! c)
      (let* ([n (%question-node-of b (%question-id entry (caddr oldest)))]
             [answer (and n (%child-of n '(chat:field chat:answers chat:actions)))])
        (when answer
          (views:set-point! (layout:selected-view)
            (case (document:node-kind answer)
              [(chat:field) (fx- (document:node-end answer) 2)]
              [(chat:answers)
               (let ([rows (%child-of answer '(ui:list))])
                 (fx+ (document:node-start (or rows answer)) 1))]
              [else (fx+ (document:node-start answer) 1)])))))))

(define (%remember! entry text)
  (let ([history (%source-history (cdr entry))])
    (saved:set! history (cons text (remove text (history))))))

(define (%trimmed s)
  (let loop ([i 0])
    (cond
      [(and (fx< i (string-length s)) (char-whitespace? (string-ref s i))) (loop (fx+ i 1))]
      [else
       (let back ([j (string-length s)])
         (if (and (fx> j i) (char-whitespace? (string-ref s (fx- j 1)))) (back (fx- j 1)) (substring s i j)))])))

(define (%condition-text c) (if (message-condition? c) (condition-message c) ""))

(define (%submit! who deliver)
  (let* ([c (%current-conversation who)] [entry (%entry-of c)] [b (%buffer-of entry c)] [text (%prompt-text b)])
    (unless (string=? (%trimmed text) "")
      (%remember! entry text)
      (hashtable-delete! %history-place b)
      (buffers:with-silent-edits b (%set-prompt-text! b ""))
      (%use! c)
      (let ([source-refused? (%source-refused? (cdr entry))])
        (guard (e [(refused? e)
                   (%put-back! b text)
                   (%notice! entry c (level warning) (%condition-text e))]
                  [(and source-refused? (source-refused? e))
                   (%put-back! b text)
                   (%notice! entry c (level warning)
                     (string-append (%title entry c) " refused the prompt: " (%condition-text e)))])
          (deliver (cdr entry) c text))))))

(commands:define-command (send)
  "Moves the prompt's text into the prompt history and sends it to the agent; while the agent works, it reads the text at its next step."
  (%submit! 'chat:send (lambda (s c text) ((%source-send s) c text))))

(commands:define-command (follow-up)
  "Moves the prompt's text into the prompt history and sends it to the agent; while the agent works, held until its turn ends."
  (%submit! 'chat:follow-up (lambda (s c text) ((or (%source-follow-up s) (%source-send s)) c text))))

(commands:define-command (send-now)
  "Moves the prompt's text into the prompt history and sends it to the agent; while the agent works, into its running turn at once."
  (let* ([c (%current-conversation 'chat:send-now)] [entry (%entry-of c)] [s (cdr entry)])
    (when (and ((%source-working? s) c) (not (%source-send-now s))
               (not (string=? (%trimmed (%prompt-text (%buffer-of entry c))) "")))
      (error 'chat:send-now (string-append (%title entry c) " takes no text into a running turn")))
    (%submit! 'chat:send-now
      (lambda (s c text)
        ((if ((%source-working? s) c) (%source-send-now s) (%source-send s)) c text)))))

(define (%put-back-all! entry c texts)
  (unless (null? texts)
    (%put-back! (%buffer-of entry c) (apply string-append (%join texts "\n")))))

(commands:define-command (cancel)
  "Stops the agent's turn and its questions; what was queued comes back to the prompt."
  (let* ([c (%current-conversation 'chat:cancel)] [entry (%entry-of c)])
    (%put-back-all! entry c ((%source-cancel (cdr entry)) c))))

(commands:define-command (take-queue)
  "Brings what the agent has queued back to the prompt."
  (let* ([c (%current-conversation 'chat:take-queue)] [entry (%entry-of c)] [take (%source-take-queue (cdr entry))])
    (when take
      (%put-back-all! entry c (take c)))))

(define (%recall! who step)
  (let* ([c (%current-conversation who)] [entry (%entry-of c)] [b (%buffer-of entry c)]
         [history ((%source-history (cdr entry)))]
         [place (if (memq (commands:last-command) (list previous-prompt next-prompt))
                    (hashtable-ref %history-place b #f)
                    #f)]
         [index (fx+ (if place (car place) -1) step)]
         [typed (if place (cdr place) (%prompt-text b))])
    (cond
      [(fx< index -1) (error who "no later prompt")]
      [(fx>= index (length history)) (error who "no earlier prompt")]
      [else
       (hashtable-set! %history-place b (cons index typed))
       (%set-prompt-text! b (if (fx= index -1) typed (list-ref history index)))
       (views:set-point! (views:current) (%prompt-end b))])))

(commands:define-command (previous-prompt)
  "Puts an earlier prompt from the prompt history in the prompt."
  (%recall! 'chat:previous-prompt 1))

(commands:define-command (next-prompt)
  "Puts a later prompt from the prompt history in the prompt, and at the end what was typed."
  (%recall! 'chat:next-prompt -1))

(define (%block-kind-names)
  (map (lambda (e) (buffers:kind-name (buffers:constructor-kind (car e)))) (tables:entries block-kinds)))

(define (%item-node-of b node)
  (let ([doc (buffers:document b)])
    (let loop ([n node])
      (let ([parent (document:enclosing doc (document:node-start n))])
        (cond
          [(not parent) #f]
          [(eq? (document:node-kind parent) 'chat:%item) n]
          [else (loop parent)])))))

(define (%fold-place b block)
  (let ([item (%item-node-of b block)])
    (if (eq? item block)
        (cons (%attribute block 'key) 0)
        (cons (%attribute item 'key) (%attribute block 'key)))))

(commands:define-command (toggle-block)
  "Folds or unfolds the block at point."
  (let* ([c (%current-conversation 'chat:toggle-block)] [entry (%entry-of c)] [v (views:current)] [b (views:buffer v)]
         [block (%enclosing-of b (views:point v) (%block-kind-names))])
    (unless block
      (error 'chat:toggle-block "no block is at point"))
    (let ([place (%fold-place b block)])
      (hashtable-set! %folds (%fold-key entry c (car place) (cdr place)) (not (%attribute block 'open)))
      (%datums-changed!)
      (%rewrite! entry c b))))

(commands:define-command (toggle-all-blocks)
  "Folds every block when any is unfolded, else unfolds every one."
  (let* ([c (%current-conversation 'chat:toggle-all-blocks)] [entry (%entry-of c)] [b (%buffer-of entry c)]
         [kinds (%block-kind-names)]
         [blocks (let walk ([nodes (%children (%part b 'chat:transcript))])
                   (apply append
                     (map (lambda (n)
                            (append (if (memq (document:node-kind n) kinds) (list n) '())
                                    (if (document:atom? n) '() (walk (%children n)))))
                          nodes)))]
         [open? (not (exists (lambda (n) (%attribute n 'open)) blocks))])
    (for-each
      (lambda (n)
        (let ([place (%fold-place b n)])
          (hashtable-set! %folds (%fold-key entry c (car place) (cdr place)) open?)))
      blocks)
    (%datums-changed!)
    (%rewrite! entry c b)))

(commands:define-command (toggle-thinking)
  "Shows the agents' finished thinking in every chat, or folds it."
  (options:set! thinking-shown? (not (thinking-shown?)))
  (ask:message (if (thinking-shown?) "Finished thinking is shown" "Finished thinking is folded")))

(define (%item-at entry c b position)
  (let ([wrapper (%enclosing-of b position '(chat:%item))])
    (and wrapper
         (let ([key (%attribute wrapper 'key)] [item-key (%source-item-key (cdr entry))])
           (find (lambda (i) (equal? (item-key i) key)) ((%source-items (cdr entry)) c))))))

(define (%path-line-at b position)
  (let* ([doc (buffers:document b)] [line (document:line doc position)]
         [start (document:line-start doc line)]
         [end (let loop ([p position]) (if (or (fx>= p (document:length doc)) (eqv? (document:token doc p) #\newline)) p (loop (fx+ p 1))))]
         [text (document:text doc start end)] [at (string-length (document:text doc start position))])
    (let* ([word-start (let loop ([i at]) (if (and (fx> i 0) (not (char-whitespace? (string-ref text (fx- i 1))))) (loop (fx- i 1)) i))]
           [word-end (let loop ([i at]) (if (and (fx< i (string-length text)) (not (char-whitespace? (string-ref text i)))) (loop (fx+ i 1)) i))]
           [word (%strip-punctuation (substring text word-start word-end))]
           [colon (let loop ([i 0]) (cond [(fx= i (string-length word)) #f] [(char=? (string-ref word i) #\:) i] [else (loop (fx+ i 1))]))])
      (and colon (fx> colon 0)
           (let ([n (let loop ([i (fx+ colon 1)])
                      (if (and (fx< i (string-length word)) (char-numeric? (string-ref word i))) (loop (fx+ i 1)) i))])
             (and (fx> n (fx+ colon 1))
                  (cons (substring word 0 colon) (string->number (substring word (fx+ colon 1) n)))))))))

(define (%strip-punctuation word)
  (let loop ([s word])
    (cond
      [(and (fx> (string-length s) 0) (memv (string-ref s 0) '(#\( #\[ #\` #\" #\')))
       (loop (substring s 1 (string-length s)))]
      [(and (fx> (string-length s) 0) (memv (string-ref s (fx- (string-length s) 1)) '(#\) #\] #\` #\" #\' #\. #\, #\;)))
       (loop (substring s 0 (fx- (string-length s) 1)))]
      [else s])))

(define (%absolute dir path)
  (if (and (fx> (string-length path) 0) (char=? (string-ref path 0) #\/))
      path
      (string-append (%without-slash dir) "/" path)))

(define (%visit! entry c path line)
  (let ([b (files:visit (%absolute (%directory entry c) path))])
    (layout:switch-to-buffer b)
    (views:set-point! (layout:selected-view) (editing:line-position b line))))

(commands:define-command (visit)
  "Opens the file of the tool call at point at its line, or the path:line at point."
  (let*-values ([(c) (%current-conversation 'chat:visit)] [(entry) (%entry-of c)] [(v position) (%place)]
                [(b) (views:buffer v)])
    (let ([location (%source-location (cdr entry))] [block (%enclosing-of b position (%block-kind-names))])
      (cond
        [(and location block
              (let ([item (%item-at entry c b position)])
                (and item (location c item (%attribute block 'key)))))
         => (lambda (place) (%visit! entry c (car place) (cdr place)))]
        [(%path-line-at b position) => (lambda (p) (%visit! entry c (car p) (cdr p)))]
        [else (error 'chat:visit "no file is at point")]))))

;; The status line asks on every draw, and reading every item back from
;; the document takes a long chat milliseconds; the record of what was
;; written gives each item's kind and length.
(define (%message-starts b transcript)
  (let ([written (hashtable-ref %written-transcripts b #f)])
    (if written
        (let ([datums (%written-datums written)] [lengths (%written-lengths written)])
          (let loop ([j 0] [at (fx+ (document:node-start transcript) 1)] [acc '()])
            (if (fx= j (vector-length datums))
                (reverse acc)
                (loop (fx+ j 1) (fx+ at (vector-ref lengths j))
                      (if (eq? (car (vector-ref datums j)) 'chat:user-message) (cons (fx+ at 1) acc) acc)))))
        '())))

(define (describe-message transcript view)
  (unless (and (views:view? view) (views:buffer view))
    (assertion-violation 'chat:describe-message "not a view showing a buffer" view))
  (unless (and (document:node? transcript) (eq? (document:node-kind transcript) 'chat:transcript))
    (assertion-violation 'chat:describe-message "not a chat's conversation" transcript))
  (let* ([p (views:point view)] [starts (%message-starts (views:buffer view) transcript)]
         [k (length (filter (lambda (s) (fx<= s p)) starts))])
    (and (fx> k 0) (format "message ~a of ~a" k (length starts)))))

(define (%describe-nothing node view) #f)

(commands:define-command (next-message)
  "Moves point to your next message."
  (let* ([v (views:current)] [b (views:buffer v)] [p (views:point v)]
         [next (find (lambda (s) (fx> s p)) (%message-starts b (%part b 'chat:transcript)))])
    (unless next (error 'chat:next-message "no later message"))
    (views:set-point! v (fx+ next 1))))

(commands:define-command (previous-message)
  "Moves point to your previous message."
  (let* ([v (views:current)] [b (views:buffer v)] [p (views:point v)]
         [here (%enclosing-of b p '(chat:user-message))]
         [before (filter (lambda (s) (fx< s (if here (document:node-start here) p))) (%message-starts b (%part b 'chat:transcript)))])
    (when (null? before) (error 'chat:previous-message "no earlier message"))
    (views:set-point! v (fx+ (car (last-pair before)) 1))))

(commands:define-command (fork)
  "Goes on in a copy of the conversation, as the agent forks it, from the item at point."
  (let*-values ([(c) (%current-conversation 'chat:fork)] [(entry) (%entry-of c)] [(v position) (%place)])
    (let ([fork (%source-fork (cdr entry))])
      (unless fork
        (error 'chat:fork (string-append (%title entry c) " cannot fork")))
      (fork c (%item-at entry c (views:buffer v) position)))))

(commands:define-command (copy-message)
  "Copies the message at point, as Markdown, to the kill ring."
  (let*-values ([(c) (%current-conversation 'chat:copy-message)] [(entry) (%entry-of c)] [(v position) (%place)])
    (let ([item-text (%source-item-text (cdr entry))])
      (unless item-text (error 'chat:copy-message "nothing to copy"))
      (let* ([item (%item-at entry c (views:buffer v) position)] [text (and item (item-text item))])
        (unless (string? text) (error 'chat:copy-message "no message is at point"))
        (kill-ring:push! (list text))))))

(define (%last-drawn-reply entry c item-text)
  (let loop ([items (reverse ((%source-items (cdr entry)) c))])
    (cond
      [(null? items) #f]
      [(let ([d (%cached-item-datum entry c (car items))]) (and (pair? d) (eq? (car d) 'chat:reply)))
       (item-text (car items))]
      [else (loop (cdr items))])))

(commands:define-command (copy-last-reply)
  "Copies the agent's last reply to the kill ring."
  (let* ([c (%current-conversation 'chat:copy-last-reply)] [entry (%entry-of c)]
         [last-reply (%source-last-reply (cdr entry))] [item-text (%source-item-text (cdr entry))]
         [text (cond
                 [last-reply (last-reply c)]
                 [item-text (%last-drawn-reply entry c item-text)]
                 [else (error 'chat:copy-last-reply "nothing to copy")])])
    (unless text (error 'chat:copy-last-reply (string-append (%title entry c) " has not replied yet")))
    (kill-ring:push! (list text))))

(define (%question-at who)
  (let*-values ([(c) (%current-conversation who)] [(entry) (%entry-of c)] [(v position) (%place)] [(b) (views:buffer v)])
    (let* ([node (%enclosing-of b position '(chat:question))] [q (and node (%question-of entry c node))])
      (unless q (error who "no question is at point"))
      (values entry c b v position node q))))

(define (%field-text b field)
  (document:text (buffers:document b) (fx+ (document:node-start field) 1) (fx- (document:node-end field) 2)))

(define (%button-labels b node)
  (let ([doc (buffers:document b)])
    (let walk ([nodes (%children node)])
      (apply append
        (map (lambda (n)
               (cond
                 [(eq? (document:node-kind n) 'chat:answer-button)
                  (list (document:text doc (fx+ (document:node-start n) 1) (fx- (document:node-end n) 1)))]
                 [(document:atom? n) '()]
                 [else (walk (%children n))]))
             nodes)))))

(define (%or-list words)
  (cond
    [(null? words) ""]
    [(null? (cdr words)) (car words)]
    [else (string-append (apply string-append (%join (list-head words (fx- (length words) 1)) ", "))
                         " or " (car (last-pair words)))]))

(commands:define-command (answer)
  "Answers the question at point: with its field's text, the answer at point, or the button pushed."
  (let-values ([(entry c b v position node q) (%question-at 'chat:answer)])
    (let ([field (%child-of node '(chat:field))]
          [button (%enclosing-of b position '(chat:answer-button))]
          [answers (%child-of node '(chat:answers))])
      ((%source-answer (cdr entry)) c q
        (cond
          [field (%field-text b field)]
          [button (%attribute button 'value)]
          [answers
           (let* ([rows (%child-of answers '(ui:list))] [row (and rows (ui:selected-row rows v))])
             (unless row (error 'chat:answer "no answer is at point"))
             (%answer-field (list-ref (%attribute answers 'answers) row) 'value))]
          [else (error 'chat:answer (string-append "push " (%or-list (%button-labels b node))))])))))

(commands:define-command (answer-by-key)
  "Answers the question at point with its answer whose key is the key typed."
  (let-values ([(entry c b v position node q) (%question-at 'chat:answer-by-key)])
    (let* ([char (keys:typed-char)] [key (if char (string char) "")]
           [answers (%child-of node '(chat:answers))]
           [chosen (and answers (find (lambda (a) (equal? (%answer-field a 'key) key)) (%attribute answers 'answers)))])
      (unless chosen (error 'chat:answer-by-key (string-append "no answer on " key)))
      ((%source-answer (cdr entry)) c q (%answer-field chosen 'value)))))

(commands:define-command (cancel-question)
  "Cancels the question at point."
  (let-values ([(entry c b v position node q) (%question-at 'chat:cancel-question)])
    ((%source-cancel-question (cdr entry)) c q)))

(ui:define-button answer-button answer)

(ui:define-button cancel-button cancel-question)

(define (files-edited! c paths)
  (let ([entry (%check-conversation 'chat:files-edited! c)])
    (unless (and (list? paths) (for-all string? paths))
      (assertion-violation 'chat:files-edited! "not a list of paths" paths))
    (for-each
      (lambda (path)
        (let ([b (files:buffer-visiting path)])
          (when b
            (if (buffers:modified? b)
                (%notice! entry c (level warning)
                  (string-append (buffers:name b) " has unsaved changes, so " (%title entry c)
                                 "'s edit of its file is not shown in it"))
                (spawn-task (lambda (restore) (files:revert-from-file b)))))))
      paths)))

(define (show-status view)
  (let* ([b (views:buffer view)] [c (and b (conversation-of b))])
    (and c
         (let* ([s (cdr (%entry-of c))] [status (%source-status s)])
           (if status (status c) ((%source-activity s) c))))))

(define (show-waiting view)
  (let ([waiting (%waiting-questions)])
    (and (pair? waiting)
         (let* ([n (length waiting)]
                [one-source? (for-all (lambda (w) (eq? (car (car w)) (car (car (car waiting))))) waiting)]
                [who (if one-source? (%title (car (car waiting)) (cadr (car waiting))) "Agents")])
           (haml (:span.chat-waiting ([title (string-append who (if one-source? " waits" " wait")
                                                            " for an answer; click to go to the question")])
                   (cond
                     [(fx= n 1) (string-append who " asks")]
                     [one-source? (string-append who " asks " (number->string n) " questions")]
                     [else (string-append who " ask " (number->string n) " questions")])))))))

(commands:define-command (status-menu [event (keys:command-event)])
  "Selects the view whose status segment was clicked and shows the menu of its chat's source."
  (unless (keys:event? event)
    (assertion-violation 'chat:status-menu "not an event" event))
  (let* ([node (views:posn-node (keys:event-end event))] [v (and node (layout:part-view node))]
         [b (and v (views:buffer v))] [c (and b (conversation-of b))]
         [command (and c (tables:ref status-menus (car (%entry-of c)) #f))])
    ;; This binding shadows layout's left click, which selects the clicked
    ;; window, so it selects the window too, as a click elsewhere on the
    ;; line does.
    (when (and v (not (layout:locked? (layout:view-node v))))
      (layout:select! v))
    (when command
      (views:call-with-view v (lambda () (commands:run command))))))

(tables:define-table %waiting-keymap "Clicks on the count of the agents' questions.")

(status-line:define-segment status (show show-status) (keymap status-keymap))

(status-line:define-segment waiting (show show-waiting) (keymap %waiting-keymap))

(define (%chat-edited b edit)
  (when (and (not (buffers:edit-silent? edit)) (conversation-of b))
    (set! %drafts-changed? #t)))

(define (%draft-kept? b) (and (conversation-of b) #t))

(define (%chat-buffer-killed b)
  (let ([c (conversation-of b)])
    (when c
      (let* ([entry (%entry-of c)] [d (%moved-draft entry c)] [text (%prompt-text b)])
        (saved:set! (%source-drafts (cdr entry))
          (%drafts-updated entry (%drafts entry) c (if d (%joined (cdr d) text) text)))
        (hashtable-delete! %buffers c)
        (hashtable-delete! %claims b)
        (let ([kill (%source-kill (cdr entry))])
          (when kill (kill c)))))))

(define (%option-changed option value)
  (when (eq? option thinking-shown?)
    (for-each (lambda (p) (%mark-dirty! (cdr p))) (%live-entries))))

(keys:bind! %waiting-keymap "<mouse-1>" next-question)
(keys:bind! %waiting-keymap "<down-mouse-1>" keys:ignore)
(keys:bind! %waiting-keymap "<drag-mouse-1>" keys:ignore)
(keys:bind! status-keymap "<mouse-1>" status-menu)

(tables:set! status-line:segments status (status-line:right 30))
(tables:set! status-line:segments waiting (status-line:left 60))

(keys:bind! prompt-keymap "RET" send)
(keys:bind! prompt-keymap "C-c C-c" send)
(keys:bind! prompt-keymap "M-RET" follow-up)
(keys:bind! prompt-keymap "C-RET" send-now)
(keys:bind! prompt-keymap "S-RET" editing:newline)
(keys:bind! prompt-keymap "M-p" previous-prompt)
(keys:bind! prompt-keymap "M-n" next-prompt)
(keys:bind! prompt-keymap "M-<up>" take-queue)
(keys:bind! transcript-keymap "TAB" toggle-block)
(keys:bind! transcript-keymap "RET" visit)
(keys:bind! transcript-keymap "n" next-message)
(keys:bind! transcript-keymap "p" previous-message)
(keys:bind! transcript-keymap "f" fork)
(keys:bind! transcript-keymap "w" copy-message)
(keys:bind! question-keymap "RET" answer)
(keys:bind! question-keymap "S-RET" editing:newline)
(keys:bind! question-keymap "C-c C-k" cancel-question)
(keys:bind! answers-keymap "<printing-char>" answer-by-key)
(keys:bind! keymap "C-c C-k" cancel)
(keys:bind! keymap "C-c C-o" toggle-all-blocks)

(for-each (lambda (command) (tables:set! commands:command-modes command (list mode)))
  (list send follow-up send-now cancel take-queue previous-prompt next-prompt toggle-block toggle-all-blocks
        toggle-thinking visit next-message previous-message fork copy-message copy-last-reply answer
        answer-by-key cancel-question))

(tables:set! block-kinds thinking)
(tables:set! block-kinds tool-call)

(tables:set! views:position-describers %chat %describe-nothing)
(tables:set! views:position-describers transcript describe-message)
(tables:set! views:position-describers prompt views:describe-line)
(tables:set! web:stylesheets 'chat "chat/chat.css")

(hooks:add! %mode-hook %tail)
(hooks:add! buffers:after-edit %chat-edited)
(hooks:add! buffers:killed %chat-buffer-killed)
(hooks:add! files:directory-finders %chat-buffer-directory)
(hooks:add! files:unsaved-kept %draft-kept?)
(hooks:add! options:changed %option-changed)

(advice-add! batch-ended
  (lambda (ended)
    (guard (c [#t (report c)])
      (call-as-owner %self (lambda () (%redraw-dirty!))))
    (ended)))

(tables:set! commands:region-commands add-region #t)

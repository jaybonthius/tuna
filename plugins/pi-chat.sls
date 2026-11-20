#!tuna
(import (pi) (processes) (projects) (markdown) (ask) (buffers) (document) (views) (layout) (keys) (commands) (modes)
        (status-line) (ui) (kill-ring) (files) (editing) (faces) (web) (haml))

(define-saved prompt-history '() (lambda (v) (and (list? v) (for-all string? v))))

(define-saved drafts '()
  (lambda (v) (and (list? v) (for-all (lambda (d) (and (pair? d) (string? (car d)) (string? (cdr d)))) v))))

(define-option thinking-shown? #f boolean? "Whether Pi's finished thinking stays unfolded.")

(define-table slash-commands
  "Pi's own terminal commands typed at the prompt's start: each name, such as \"/compact\", to a procedure of the chat and the text after the name.")

(define-table keymap "Keys anywhere in a Pi chat.")

(define-table prompt-keymap "Keys in a chat's prompt.")

(define-table transcript-keymap "Keys in the conversation above a chat's prompt.")

(define-table dialog-keymap "Keys in one of Pi's questions.")

(define-hook %mode-hook)

(modes:define-major-mode mode (lighter "Pi") (keymap keymap) (hook %mode-hook))

(define (%refuse-edits node edit) #f)

(define (%attribute node name) (document:node-attribute node name #f))

(define (%symbol-text v) (and v (symbol->string v)))

(define (%draw-chat node view)
  (haml (:div.pi-chat (views:draw-children view node))))

(define (%draw-transcript node view)
  (haml (:div.pi-chat-transcript (views:draw-children view node))))

(define (%draw-user-message node view)
  (haml (:div.pi-chat-user-message (views:draw-children view node))))

(define (%draw-reply node view)
  (haml (:div.pi-chat-reply ([data-stop (%symbol-text (%attribute node 'stop))]) (views:draw-children view node))))

(define (%draw-thinking node view)
  (haml (:div.pi-chat-thinking ([data-open (%attribute node 'open)]) (views:draw-children view node))))

(define (%draw-tool-call node view)
  (haml (:div.pi-chat-tool-call ([data-state (%symbol-text (%attribute node 'state))] [data-open (%attribute node 'open)])
          (views:draw-children view node))))

(define (%draw-summary node view)
  (haml (:div.pi-chat-summary ([data-open (%attribute node 'open)]) (views:draw-children view node))))

(define (%draw-extension-message node view)
  (haml (:div.pi-chat-extension-message ([data-open (%attribute node 'open)]) (views:draw-children view node))))

(define (%level-face level)
  (case level
    [(error) (symbol->string faces:error)]
    [(warning) (symbol->string faces:warning)]
    [else #f]))

(define (%draw-notice node view)
  (let ([level (%attribute node 'level)])
    (haml (:div.pi-chat-notice ([data-level (%symbol-text level)] [data-face (%level-face level)])
            (views:draw-children view node)))))

(define (%draw-header node view)
  (haml (:div.pi-chat-header (views:draw-children view node))))

(define (%draw-name node view)
  (haml (:span.pi-chat-name (views:draw-children view node))))

(define (%draw-detail node view)
  (haml (:span.pi-chat-detail (views:draw-children view node))))

(define (%draw-output node view)
  (haml (:div.pi-chat-output (views:draw-children view node))))

(define (%draw-diff node view)
  (haml (:div.pi-chat-diff (views:draw-children view node))))

(define (%draw-removed node view)
  (haml (:div.pi-chat-removed ([data-face (symbol->string faces:diff.minus)]) (views:draw-children view node))))

(define (%draw-added node view)
  (haml (:div.pi-chat-added ([data-face (symbol->string faces:diff.plus)]) (views:draw-children view node))))

(define (%draw-dialogs node view)
  (haml (:div.pi-chat-dialogs (views:draw-children view node))))

(define (%draw-dialog node view)
  (haml (:div.pi-chat-dialog ([data-method (%symbol-text (%attribute node 'method))]) (views:draw-children view node))))

(define (%draw-dialog-text node view)
  (haml (:div.pi-chat-dialog-text (views:draw-children view node))))

(define (%draw-field node view)
  (haml (:div.pi-chat-field ([data-lines (%attribute node 'lines)]) (views:draw-children view node))))

(define (%draw-actions node view)
  (haml (:div.pi-chat-actions (views:draw-children view node))))

(define (%draw-queue node view)
  (haml (:div.pi-chat-queue (views:draw-children view node))))

(define (%draw-queued node view)
  (haml (:div.pi-chat-queued ([data-kind (%symbol-text (%attribute node 'kind))]) (views:draw-children view node))))

(define (%draw-tag node view)
  (haml (:span.pi-chat-tag (views:draw-children view node))))

(define (%draw-widgets node view)
  (haml (:div.pi-chat-widgets ([data-placement (%symbol-text (%attribute node 'placement))]) (views:draw-children view node))))

(define (%draw-widget node view)
  (haml (:div.pi-chat-widget (views:draw-children view node))))

(define (%draw-prompt node view)
  (haml (:div.pi-chat-prompt (views:draw-children view node))))

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
(buffers:define-kind summary (content nodes) (consent %refuse-edits) (draw %draw-summary))
(buffers:define-kind extension-message (content nodes) (consent %refuse-edits) (draw %draw-extension-message))
(buffers:define-kind notice (consent %refuse-edits) (draw %draw-notice))
(buffers:define-kind %header (consent %refuse-edits) (draw %draw-header))
(buffers:define-kind %name (inline) (consent %refuse-edits) (draw %draw-name))
(buffers:define-kind %detail (inline) (consent %refuse-edits) (draw %draw-detail))
(buffers:define-kind %output (consent %refuse-edits) (draw %draw-output))
(buffers:define-kind %diff (content nodes) (consent %refuse-edits) (draw %draw-diff))
(buffers:define-kind %removed (consent %refuse-edits) (draw %draw-removed))
(buffers:define-kind %added (consent %refuse-edits) (draw %draw-added))
(buffers:define-kind %dialogs (content nodes) (consent %refuse-edits) (draw %draw-dialogs))
(buffers:define-kind dialog (content nodes) (consent %refuse-edits) (keymap dialog-keymap) (draw %draw-dialog))
(buffers:define-kind %dialog-text (consent %refuse-edits) (draw %draw-dialog-text))
(buffers:define-kind %field (isolating) (consent %field-edit?) (draw %draw-field))
(buffers:define-kind %actions (stops children) (consent %refuse-edits) (draw %draw-actions))
(buffers:define-kind queue (content nodes) (consent %refuse-edits) (draw %draw-queue))
(buffers:define-kind %queued (consent %refuse-edits) (draw %draw-queued))
(buffers:define-kind %tag (inline) (consent %refuse-edits) (draw %draw-tag))
(buffers:define-kind %widgets (content nodes) (consent %refuse-edits) (draw %draw-widgets))
(buffers:define-kind widget (consent %refuse-edits) (draw %draw-widget))
(buffers:define-kind prompt (isolating) (keymap prompt-keymap) (draw %draw-prompt))

;; The transcript holds Markdown's kinds, which take edits as text does.
(buffers:define-layer %read-only (read-only))

;; A buffer outlives this module's reloads; the link from the chat's
;; process finds it again.

(define %buffers (make-eq-hashtable))

(define %used '())

(define %dirty '())

(define %drafts-changed? #f)

(define %draft-sessions (make-weak-eq-hashtable))

(define %folds (make-hashtable equal-hash equal?))

(define %dialog-seen (make-hashtable string-hash string=?))

(define %own-notices (make-eq-hashtable))

(define %unfinished-tools (make-weak-eq-hashtable))

(define %written-transcripts (make-weak-eq-hashtable))

(define %item-datums (make-weak-eq-hashtable))

(define %datums-version 0)

(define %history-place (make-eq-hashtable))

(define (%mark-dirty! chat)
  (unless (memq chat %dirty)
    (set! %dirty (cons chat %dirty))))

(define (%use! chat)
  (set! %used (cons chat (remq chat %used))))

(define (%check-chat who v)
  (unless (pi:chat? v)
    (assertion-violation who "not a chat" v)))

(define (%folder-name dir)
  (let* ([d (%without-slash dir)] [i (let loop ([i (string-length d)])
                                        (cond [(fx= i 0) 0] [(char=? (string-ref d (fx- i 1)) #\/) i] [else (loop (fx- i 1))]))])
    (if (fx= i (string-length d)) d (substring d i (string-length d)))))

(define (%without-slash dir)
  (if (and (fx> (string-length dir) 1) (char=? (string-ref dir (fx- (string-length dir) 1)) #\/))
      (%without-slash (substring dir 0 (fx- (string-length dir) 1)))
      dir))

(define (%buffer-name chat)
  (let ([base (string-append "*pi: " (%folder-name (%chat-directory chat)) "*")])
    (let loop ([n 1])
      (let ([name (if (fx= n 1) base (string-append base "<" (number->string n) ">"))])
        (if (buffers:find name) (loop (fx+ n 1)) name)))))

(define (%draft-of chat)
  (cond [(assoc (pi:chat-session-id chat) (drafts)) => cdr] [else ""]))

(define (%make-buffer! chat)
  (let ([b (buffers:make (%buffer-name chat)
             (%chat '() (transcript '()) (%dialogs '()) (queue '()) (%widgets '((placement . above)))
                    (prompt '() (%draft-of chat) "\n") (%widgets '((placement . below)))))])
    (modes:set-major-mode mode b)
    b))

;; Each chat's buffer is its process's, so killing it ends Pi at once.
(define (%buffer-of chat)
  (let* ([process (pi:chat-process chat)]
         [b (or (let ([b (hashtable-ref %buffers chat #f)]) (and b (buffers:live? b) b))
                (and process (processes:buffer process))
                (%make-buffer! chat))])
    (hashtable-set! %buffers chat b)
    ;; A reload of this plugin starts the table empty while chats keep
    ;; their buffers and prompts, so a chat's entry is made when its buffer
    ;; is first found, not only when made.
    (unless (hashtable-contains? %draft-sessions chat)
      (hashtable-set! %draft-sessions chat (pi:chat-session-id chat)))
    (when (and process (not (eq? (processes:buffer process) b)))
      (processes:set-buffer! process b))
    b))

(define (buffer chat)
  (%check-chat 'pi-chat:buffer chat)
  (%buffer-of chat))

(define (chat-of b)
  (unless (buffers:buffer? b)
    (assertion-violation 'pi-chat:chat-of "not a buffer" b))
  (find (lambda (chat) (eq? (hashtable-ref %buffers chat #f) b)) (pi:chats)))

(define (current-chat)
  (let* ([v (views:current)] [b (and v (views:buffer v))])
    (and b (chat-of b))))

(define (%current-chat who)
  (or (current-chat) (error who "not in a Pi chat")))

(define (%children node)
  (let ([acc '()])
    (document:for-each-child node (fx+ (document:node-start node) 1) (fx- (document:node-end node) 1)
      (lambda (c at) (when (document:node? c) (set! acc (cons c acc)))))
    (reverse acc)))

(define (%child-of node kinds)
  (find (lambda (c) (memq (document:node-kind c) kinds)) (%children node)))

(define (%root b) (document:token (buffers:document b) 0))

(define (%part b kind . attributes)
  (find (lambda (c)
          (and (eq? (document:node-kind c) kind)
               (for-all (lambda (a) (equal? (%attribute c (car a)) (cdr a))) attributes)))
        (%children (%root b))))

(define (%prompt-node b) (%part b 'pi-chat:prompt))

(define (%prompt-start b) (fx+ (document:node-start (%prompt-node b)) 1))

(define (%prompt-end b) (fx- (document:node-end (%prompt-node b)) 2))

(define (%prompt-text b)
  (document:text (buffers:document b) (%prompt-start b) (%prompt-end b)))

(define (%set-prompt-text! b text)
  (let ([n (%prompt-node b)])
    (buffers:splice! b (fx+ (document:node-start n) 1) (fx- (document:node-end n) 1)
                     (document:from-datum (string-append text "\n")))
    (set! %drafts-changed? #t)))

(define (prompt-start chat)
  (%check-chat 'pi-chat:prompt-start chat)
  (%prompt-start (%buffer-of chat)))

(define (prompt-end chat)
  (%check-chat 'pi-chat:prompt-end chat)
  (%prompt-end (%buffer-of chat)))

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

;; Text that arrives with a long history is converted on a thread of this
;; plugin's own, which posts the blocks back; until then it shows as one
;; paragraph of its plain text.
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

(define (%convert-waiting!)
  (unless (null? %waiting-texts)
    (let ([texts %waiting-texts])
      (set! %waiting-texts '())
      (fork-thread
        (lambda ()
          (let ([results (map (lambda (text)
                                (guard (c [#t (list text (%plain-blocks text) c)])
                                  (list text (markdown:blocks text) #f)))
                              texts)])
            (post!
              (lambda ()
                (for-each (lambda (r)
                            (hashtable-delete! %converting (car r))
                            (hashtable-set! %block-cache (car r) (cadr r))
                            (when (caddr r) (report (caddr r))))
                          results)
                (%datums-changed!)
                (for-each %mark-dirty! (pi:chats))))))))))

(define (%rekey blocks prefix)
  (map (lambda (b)
         (if (pair? b)
             (let ([key (cond [(assq 'key (cadr b)) => cdr] [else #f])])
               (cons (car b) (cons (cons (cons 'key (cons prefix key)) (remp (lambda (a) (eq? (car a) 'key)) (cadr b)))
                                   (cddr b))))
             b))
       blocks))

(define (%line s) (if (and (fx> (string-length s) 0) (char=? (string-ref s (fx- (string-length s) 1)) #\newline)) s (string-append s "\n")))

(define (%first-line s)
  (let loop ([i 0])
    (cond [(fx= i (string-length s)) s] [(char=? (string-ref s i) #\newline) (substring s 0 i)] [else (loop (fx+ i 1))])))

(define (%last-line s)
  (let* ([s (let trim ([n (string-length s)])
              (if (and (fx> n 0) (char=? (string-ref s (fx- n 1)) #\newline)) (trim (fx- n 1)) (substring s 0 n)))])
    (let loop ([i (string-length s)])
      (cond [(fx= i 0) s] [(char=? (string-ref s (fx- i 1)) #\newline) (substring s i (string-length s))] [else (loop (fx- i 1))]))))

(define (%line-count s)
  (fold-left (lambda (n c) (if (char=? c #\newline) (fx+ n 1) n)) 1 (string->list s)))

;; Places restart at 0 in a new session, so a fold is the session's.
(define (%fold-key chat item-key part-key)
  (list chat (pi:chat-session-id chat) item-key part-key))

(define (%open? chat item-key part-key default)
  (let ([v (hashtable-ref %folds (%fold-key chat item-key part-key) 'unset)])
    (if (eq? v 'unset) default v)))

(define (%argument arguments name)
  (let ([a (and (pair? arguments) (assoc name arguments))])
    (and a (string? (cdr a)) (cdr a))))

(define (%main-argument call)
  (let ([arguments (pi:tool-call-arguments call)])
    (or (%argument arguments "command") (%argument arguments "path")
        (let ([s (find (lambda (a) (and (pair? a) (string? (cdr a)))) (if (list? arguments) arguments '()))])
          (and s (cdr s)))
        "")))

(define (%seconds s)
  (cond
    [(< s 1/10) (string-append (number->string (exact (round (* s 1000)))) " ms")]
    [(< s 10) (string-append (number->string (/ (round (* (inexact s) 10)) 10)) " s")]
    [else (string-append (number->string (exact (round s))) " s")]))

(define (%tool-header call)
  (let ([details (filter values
                   (list (and (pi:tool-call-duration call) (%seconds (pi:tool-call-duration call)))
                         (and (fx> (pi:tool-call-images call) 0)
                              (string-append (number->string (pi:tool-call-images call))
                                             (if (fx= (pi:tool-call-images call) 1) " image" " images")))
                         (let ([state (pi:tool-call-state call)])
                           (cond
                             [(eq? state (pi:tool-state failed)) "failed"]
                             [(eq? state (pi:tool-state running)) "running"]
                             [else #f]))))])
    (%header '() (%name '() (pi:tool-call-name call)) " " (%first-line (%main-argument call))
             (if (null? details) "" (%detail '() (apply string-append " · " (%join details " · "))))
             "\n")))

(define (%join strings separator)
  (if (null? strings)
      '()
      (cons (car strings) (apply append (map (lambda (s) (list separator s)) (cdr strings))))))

(define (%edit-diff call)
  (let ([edits (let ([a (and (pair? (pi:tool-call-arguments call)) (assoc "edits" (pi:tool-call-arguments call)))])
                 (if (and a (vector? (cdr a))) (vector->list (cdr a)) '()))])
    (apply %diff '((key . diff))
      (apply append
        (map (lambda (e)
               (append (map (lambda (l) (%removed '() (%line l))) (%lines (or (%argument e "oldText") "")))
                       (map (lambda (l) (%added '() (%line l))) (%lines (or (%argument e "newText") "")))))
             edits)))))

(define (%lines s)
  (let loop ([i 0] [start 0] [acc '()])
    (cond
      [(fx= i (string-length s)) (reverse (if (fx< start i) (cons (substring s start i) acc) acc))]
      [(char=? (string-ref s i) #\newline) (loop (fx+ i 1) (fx+ i 1) (cons (substring s start i) acc))]
      [else (loop (fx+ i 1) start acc)])))

(define (%tool-datum chat item-key j call)
  (let* ([open? (%open? chat item-key j #f)] [output (pi:tool-call-output call)]
         [body (cond
                 [(and open? (equal? (pi:tool-call-name call) "edit")) (list (%edit-diff call))]
                 [(and open? (not (string=? output ""))) (list (%output '((key . output)) (%line output)))]
                 [(and (eq? (pi:tool-call-state call) (pi:tool-state running)) (not (string=? output "")))
                  (list (%output '((key . last)) (%line (%last-line output))))]
                 [else '()])])
    (apply tool-call (list (cons 'key j) (cons 'state (pi:tool-call-state call)) (cons 'open open?))
      (%tool-header call) body)))

(define (%reply-datum chat item now?)
  (let* ([k (pi:item-key item)] [pending? (eq? (pi:reply-stop item) (pi:stop pending))] [parts (pi:reply-parts item)]
         [last-part (and (pair? parts) (car (last-pair parts)))])
    (apply reply (list (cons 'key k) (cons 'stop (pi:reply-stop item)))
      (append
        (let loop ([parts parts] [j 0] [acc '()])
          (if (null? parts)
              (apply append (reverse acc))
              (let ([p (car parts)])
                (loop (cdr parts) (fx+ j 1)
                      (cons
                        (cond
                          [(pi:text? p)
                           (%rekey (if pending?
                                       (markdown:unfinished-blocks (pi:text-string p))
                                       (%finished-blocks (pi:text-string p) now?))
                                   j)]
                          [(pi:thinking? p)
                           (let* ([streaming? (and pending? (eq? p last-part))]
                                  [open? (%open? chat k j (or streaming? (thinking-shown?)))])
                             (list (apply thinking (list (cons 'key j) (cons 'open open?))
                                     (%header '() (if streaming? "Thinking…\n" "Thinking\n"))
                                     (if open?
                                         (if streaming?
                                             (markdown:unfinished-blocks (pi:thinking-string p))
                                             (%finished-blocks (pi:thinking-string p) now?))
                                         '()))))]
                          [else (list (%tool-datum chat k j p))])
                        acc)))))
        (let ([stop (pi:reply-stop item)])
          (if (memq stop (list (pi:stop error) (pi:stop aborted)))
              (list (notice '((key . stopped) (level . error))
                            (string-append (if (eq? stop (pi:stop error)) "Failed" "Stopped")
                                           (let ([e (pi:reply-error item)]) (if e (string-append ": " e) "")) "\n")))
              '()))))))

(define (%item-datum chat item)
  (let ([k (pi:item-key item)] [now? (not (pi:item-entry-id item))])
    (cond
      [(pi:user-message? item)
       (apply user-message (list (cons 'key k))
         (let ([images (pi:user-message-images item)])
           (append (%finished-blocks (pi:user-message-text item) now?)
                   (if (fx> images 0)
                       (list (notice '((key . images) (level . info))
                                     (string-append (number->string images) (if (fx= images 1) " image\n" " images\n"))))
                       '()))))]
      [(pi:reply? item) (%reply-datum chat item now?)]
      [(pi:shell-command? item)
       (let ([open? (%open? chat k 0 #f)] [output (pi:shell-command-output item)])
         (apply tool-call (list (cons 'key k) (cons 'state (pi:tool-state done)) (cons 'open open?))
           (%header '() (%name '() "!") " " (%first-line (pi:shell-command-line item))
                    (let ([exit (pi:shell-command-exit item)])
                      (if (and (number? exit) (not (= exit 0)))
                          (%detail '() (string-append " · exit " (number->string exit)))
                          ""))
                    "\n")
           (if (and open? (not (string=? output ""))) (list (%output '((key . output)) (%line output))) '())))]
      [(pi:summary? item)
       (let ([open? (%open? chat k 0 #f)])
         (apply summary (list (cons 'key k) (cons 'open open?))
           (%header '()
             (if (eq? (pi:summary-kind item) 'compaction) "Pi summarised the conversation" "Pi summarised a branch left behind")
             (let ([tokens (pi:summary-tokens-before item)])
               (if (number? tokens) (%detail '() (string-append " · " (number->string tokens) " tokens before")) ""))
             "\n")
           (if open? (%finished-blocks (pi:summary-text item) now?) '())))]
      [(pi:extension-message? item)
       (let* ([text (pi:extension-message-text item)] [open? (%open? chat k 0 (fx<= (%line-count text) 12))])
         (apply extension-message (list (cons 'key k) (cons 'open open?))
           (%header '() (%name '() (pi:extension-message-type item)) "\n")
           (if open? (%finished-blocks text now?) '())))]
      [(pi:notice? item)
       (notice (list (cons 'key k) (cons 'level (pi:notice-level item))) (%line (pi:notice-text item)))]
      [else #f])))

;; An item's datum is made again only when the item, the folds or the
;; converted text change: making every item's datum at each batch took
;; most of a batch for a long session.
(define (%datums-changed!) (set! %datums-version (fx+ %datums-version 1)))

(define (%cached-item-datum chat item)
  (let ([cached (hashtable-ref %item-datums item #f)] [shown? (thinking-shown?)])
    (if (and cached (fx= (vector-ref cached 0) %datums-version) (eq? (vector-ref cached 1) shown?))
        (vector-ref cached 2)
        (let ([d (%item-datum chat item)])
          (hashtable-set! %item-datums item (vector %datums-version shown? d))
          d))))

(define (%transcript-datums chat)
  (let* ([items (pi:chat-transcript chat)]
         [own (reverse (hashtable-ref %own-notices chat '()))]
         [datums
          (let loop ([items items] [own own] [n 0] [acc '()])
            (cond
              [(and (pair? own) (<= (car (car own)) n))
               (loop items (cdr own) n (cons (cdr (car own)) acc))]
              [(null? items) (append (reverse acc) (map cdr own))]
              [else
               (let ([d (%cached-item-datum chat (car items))])
                 (loop (cdr items) own (if (pi:notice? (car items)) n (fx+ n 1)) (if d (cons d acc) acc)))]))])
    (if (eq? (pi:chat-activity chat) (pi:activity exited))
        (append datums
                (list (notice '((key . exited) (level . error)) (%restart-button '() "Restart Pi") "\n")))
        datums)))

;; A notice of the chat's own, such as a refusal, is not among Pi's
;; items, so it is placed after the item it came after.
(define (%chat-notice! chat level text)
  (let* ([count (fold-left (lambda (n i) (if (pi:notice? i) n (fx+ n 1))) 0 (pi:chat-transcript chat))]
         [own (hashtable-ref %own-notices chat '())]
         [key (cons 'own (length own))])
    (hashtable-set! %own-notices chat
      (cons (cons count (notice (list (cons 'key key) (cons 'level level)) (%line text))) own))
    (%mark-dirty! chat)))

(define (%dialog-datum d)
  (let ([method (pi:dialog-method d)] [title (pi:dialog-title d)])
    (apply dialog (list (cons 'key (pi:dialog-id d)) (cons 'method method))
      (%header '() title
        (if (and (eq? method (pi:method input)) (pi:dialog-text d))
            (%detail '() (string-append " · " (pi:dialog-text d)))
            "")
        "\n")
      (append
        (if (pi:dialog-message d) (list (%dialog-text '() (%line (pi:dialog-message d)))) '())
        (cond
          [(eq? method (pi:method select)) (list (ui:list '((key . options))))]
          [(eq? method (pi:method input)) (list (%field '((key . field)) "\n"))]
          [(eq? method (pi:method editor)) (list (%field '((key . field) (lines . #t)) (or (pi:dialog-text d) "") "\n"))]
          [else '()])
        (list
          (cond
            [(eq? method (pi:method confirm))
             (%actions '() (%answer-button '((value . #t)) "Yes") " " (%answer-button '((value . #f)) "No") "\n")]
            [(eq? method (pi:method select)) (%actions '() (%cancel-button '() "Cancel") "\n")]
            [else (%actions '() (%answer-button '((value . field)) "Answer") " " (%cancel-button '() "Cancel") "\n")]))))))

(define (%dialog-node-of b d)
  (let ([id (pi:dialog-id d)])
    (find (lambda (n) (equal? (%attribute n 'key) id)) (%children (%part b 'pi-chat:%dialogs)))))

(define (%dialog-at chat node)
  (let ([id (%attribute node 'key)])
    (find (lambda (d) (equal? (pi:dialog-id d) id)) (pi:chat-dialogs chat))))

(define (%show-options! chat b d)
  (let ([list-node (%child-of (%dialog-node-of b d) '(ui:list))])
    (when list-node
      (ui:set-rows! b list-node (list->vector (pi:dialog-options d)) ui:label
        (lambda (option) (pi:answer! chat d option))
        (max 1 (length (pi:dialog-options d)))))))

;; A question's node is written once and removed once, never rewritten,
;; so what is typed in its field stays, through a reload of pi too.
(define (%write-dialogs! chat b)
  (let ([ids (map pi:dialog-id (pi:chat-dialogs chat))])
    (let remove ()
      (let ([gone (find (lambda (n) (not (member (%attribute n 'key) ids))) (%children (%part b 'pi-chat:%dialogs)))])
        (when gone
          (hashtable-delete! %dialog-seen (%attribute gone 'key))
          (buffers:splice! b (document:node-start gone) (document:node-end gone) (document:from-datum))
          (remove))))
    (for-each
      (lambda (d)
        (unless (hashtable-contains? %dialog-seen (pi:dialog-id d))
          (hashtable-set! %dialog-seen (pi:dialog-id d) (real-time)))
        (unless (%dialog-node-of b d)
          (let ([at (fx- (document:node-end (%part b 'pi-chat:%dialogs)) 1)])
            (buffers:splice! b at at (document:from-datum (%dialog-datum d)))
            (when (eq? (pi:dialog-method d) (pi:method select)) (%show-options! chat b d)))))
      (pi:chat-dialogs chat))))

(define (%queue-datums chat)
  (let-values ([(steering follow-ups) (pi:chat-queue chat)])
    (append
      (map (lambda (text) (%queued '((kind . steer)) (%tag '() "Steer") " " (%line text))) steering)
      (map (lambda (text) (%queued '((kind . follow-up)) (%tag '() "Follow-up") " " (%line text))) follow-ups))))

(define (%widget-datums chat placement)
  (map (lambda (w)
         (widget (list (cons 'key (pi:widget-key w)))
                 (apply string-append (map %line (if (null? (pi:widget-lines w)) '("") (pi:widget-lines w))))))
       (filter (lambda (w) (eq? (pi:widget-placement w) placement)) (pi:chat-widgets chat))))

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
(define (%write-transcript! chat b)
  (let* ([t (%part b 'pi-chat:transcript)] [first (fx+ (document:node-start t) 1)]
         [new (list->vector (%transcript-datums chat))] [lengths (make-vector (vector-length new) 0)]
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

;; Point in the prompt or a question stays in view as Pi writes above it,
;; as at a terminal's prompt; views follows point only where it is set.
(define (%follow-prompt! b)
  (let ([below (document:node-start (%part b 'pi-chat:%dialogs))])
    (for-each
      (lambda (v)
        (when (fx>= (views:point v) below)
          (views:set-point! v (views:point v))))
      (views:showing b))))

;; The conversation is rebuilt from Pi's records, so its rewrites are no
;; history of the prompt's.
(define (%rewrite! chat b)
  (buffers:with-silent-edits b
    (%write-transcript! chat b)
    (%write-dialogs! chat b)
    (buffers:reconcile! b (%part b 'pi-chat:queue) (%queue-datums chat))
    (buffers:reconcile! b (%part b 'pi-chat:%widgets '(placement . above)) (%widget-datums chat 'above))
    (buffers:reconcile! b (%part b 'pi-chat:%widgets '(placement . below)) (%widget-datums chat 'below))
    (let ([t (%part b 'pi-chat:transcript)])
      (buffers:set-spans! (buffers:layer b %read-only) 0 (document:length (buffers:document b))
        (list (list (document:node-start t) (document:node-end t) '())))))
  (%follow-prompt! b))

(define (%redraw-dirty!)
  (let ([dirty %dirty] [live (pi:chats)])
    (set! %dirty '())
    (for-each
      (lambda (chat)
        (cond
          [(memq chat live)
           (let ([b (%buffer-of chat)])
             (%revert-edited! chat)
             (%rewrite! chat b))]
          [else
           (let ([b (hashtable-ref %buffers chat #f)])
             (hashtable-delete! %buffers chat)
             (set! %used (remq chat %used))
             (when (and b (buffers:live? b))
               (spawn-task (lambda () (when (buffers:live? b) (buffers:kill! b))))))]))
      dirty)
    (%convert-waiting!)
    (for-each %take-draft! live)
    (when (or %drafts-changed? (exists %draft-moved? live))
      (set! %drafts-changed? #f)
      (set-saved! drafts
        (fold-left
          (lambda (ds chat)
            (let ([b (hashtable-ref %buffers chat #f)])
              (if (and b (buffers:live? b)) (%drafts-updated ds chat (%prompt-text b)) ds)))
          (drafts) live)))))

;; A draft is its session's, read back when the session is opened again,
;; so it outlives the chat. The prompt keeps its text when its chat moves
;; to another session, so the draft moves too: the session left keeping
;; it would show text already sent or deleted when opened again.
(define (%drafts-updated ds chat text)
  (let ([id (pi:chat-session-id chat)] [left (hashtable-ref %draft-sessions chat #f)])
    (hashtable-set! %draft-sessions chat id)
    (let ([others (remp (lambda (d) (or (string=? (car d) id) (equal? (car d) left))) ds)])
      (if (string=? text "") others (cons (cons id text) others)))))

(define (%draft-moved? chat)
  (let ([left (hashtable-ref %draft-sessions chat #f)])
    (and left (not (equal? left (pi:chat-session-id chat))))))

;; The session a chat moves into may keep a draft, as a killed chat's.
;; Saving the prompt over it would lose that text, so the draft joins the
;; prompt as a refused message does.
(define (%moved-draft chat)
  (and (%draft-moved? chat) (assoc (pi:chat-session-id chat) (drafts))))

(define (%take-draft! chat)
  (let ([b (hashtable-ref %buffers chat #f)] [d (%moved-draft chat)])
    (when (and b (buffers:live? b) d)
      (%put-back! chat b (cdr d)))))

(define (%tool-calls chat)
  (apply append
    (map (lambda (item) (if (pi:reply? item) (filter pi:tool-call? (pi:reply-parts item)) '()))
         (pi:chat-transcript chat))))

;; Only a call seen unfinished is an edit Pi makes now: one done when
;; first seen ended before this chat was followed, in an earlier Tuna, an
;; earlier load of pi, or a session opened again.
(define (%revert-edited! chat)
  (let ([unfinished (or (hashtable-ref %unfinished-tools chat #f)
                        (let ([h (make-hashtable string-hash string=?)])
                          (hashtable-set! %unfinished-tools chat h)
                          h))])
    (for-each
      (lambda (call)
        (when (member (pi:tool-call-name call) '("edit" "write"))
          (let ([id (pi:tool-call-id call)] [state (pi:tool-call-state call)])
            (cond
              [(memq state (list (pi:tool-state called) (pi:tool-state running)))
               (hashtable-set! unfinished id #t)]
              [(hashtable-contains? unfinished id)
               (hashtable-delete! unfinished id)
               (when (eq? state (pi:tool-state done))
                 (%revert-visiting! chat call))]))))
      (%tool-calls chat))))

(define (%revert-visiting! chat call)
  (let* ([path (%argument (pi:tool-call-arguments call) "path")]
         [b (and path (files:buffer-visiting (%absolute (%chat-directory chat) path)))])
    (when b
      (if (buffers:modified? b)
          (%chat-notice! chat 'warning
            (string-append (buffers:name b) " has unsaved changes, so Pi's edit of its file is not shown in it"))
          (spawn-task (lambda () (files:revert-from-file b)))))))

(define (%absolute dir path)
  (if (and (fx> (string-length path) 0) (char=? (string-ref path 0) #\/))
      path
      (string-append (%without-slash dir) "/" path)))

(define (%with-slash dir)
  (if (and (fx> (string-length dir) 0) (char=? (string-ref dir (fx- (string-length dir) 1)) #\/))
      dir
      (string-append dir "/")))

(define (%project-folder folder)
  (cond
    [(projects:find folder) => projects:root]
    [else (%with-slash folder)]))

;; projects:find walks a folder upward as text, and buffer names and
;; references are taken from it as text, so a chat started in a folder
;; written with .. would otherwise fall in another project.
(define (%chat-directory chat)
  (files:expanded-path (pi:chat-directory chat)))

(define (%chat-buffer-directory b)
  (let ([chat (chat-of b)])
    (and chat (%chat-directory chat))))

(define (folder-for b)
  (unless (buffers:buffer? b)
    (assertion-violation 'pi-chat:folder-for "not a buffer" b))
  (or (%chat-buffer-directory b) (%project-folder (files:directory b))))

(define (%project-of b)
  (%project-folder (files:directory b)))

(define (%in-project? project)
  (lambda (c) (string=? (%project-folder (%chat-directory c)) project)))

(define (chats-for b)
  (unless (buffers:buffer? b)
    (assertion-violation 'pi-chat:chats-for "not a buffer" b))
  (let ([ordered (append (filter (lambda (c) (memq c (pi:chats))) %used)
                         (filter (lambda (c) (not (memq c %used))) (reverse (pi:chats))))])
    (let-values ([(in out) (partition (%in-project? (%project-of b)) ordered)])
      (append in out))))

(define (%last-chat-in b)
  (find (%in-project? (%project-of b)) (chats-for b)))

(define (show! chat)
  (%check-chat 'pi-chat:show! chat)
  (let ([b (%buffer-of chat)])
    (%mark-dirty! chat)
    (%use! chat)
    (layout:switch-to-buffer b)
    (views:set-point! (layout:selected-view) (%prompt-end b))))

(define (set-prompt! chat text)
  (%check-chat 'pi-chat:set-prompt! chat)
  (unless (string? text)
    (assertion-violation 'pi-chat:set-prompt! "not a string" text))
  (%set-prompt-text! (%buffer-of chat) text))

(define (add-to-prompt! chat text)
  (%check-chat 'pi-chat:add-to-prompt! chat)
  (unless (string? text)
    (assertion-violation 'pi-chat:add-to-prompt! "not a string" text))
  (let* ([b (%buffer-of chat)] [current (%prompt-text b)])
    (%set-prompt-text! b (cond [(string=? current "") text]
                               [(char=? (string-ref current (fx- (string-length current) 1)) #\newline)
                                (string-append current text)]
                               [else (string-append current "\n" text)]))))

(define (%current-buffer)
  (let ([v (views:current)])
    (if v (views:buffer v) (error 'pi-chat "no view is current"))))

(commands:define-command (open [new? (and (commands:prefix-argument) #t)])
  "Shows the chat used last in the current buffer's project, point in its prompt, starting one when there is none; with C-u, always a new one."
  (let ([b (%current-buffer)])
    (show! (or (and (not new?) (%last-chat-in b)) (pi:start (folder-for b))))))

(commands:define-command (toggle)
  "Shows the chat used last in the current buffer's project, or removes the view showing it."
  (let* ([b (%current-buffer)] [chat (%last-chat-in b)] [v (and chat (layout:find-view (%buffer-of chat)))])
    (cond
      [(not v) (show! (or chat (pi:start (folder-for b))))]
      [(not (layout:deletable? (layout:view-node v)))
       (let ([other (find (lambda (o) (and (not (chat-of o)) (not (buffers:internal-name? (buffers:name o)))))
                          (reverse (buffers:all)))])
         (when other (views:set-buffer! v other)))]
      [else (layout:delete-part! (layout:view-node v))])))

(define (%region-text chat b start end)
  (let* ([doc (buffers:document b)] [path (files:path b)]
         [first (document:line doc start)]
         [last (document:line doc (if (and (fx> end start) (eqv? (document:token doc (fx- end 1)) #\newline))
                                      (fx- end 1)
                                      end))])
    (if (and path (not (buffers:modified? b)))
        (string-append (%relative (%chat-directory chat) path) ":" (number->string first)
                       (if (fx= first last) "" (string-append "-" (number->string last))))
        (string-append "```" (buffers:name b) " lines " (number->string first) "-" (number->string last) "\n"
                       (%line (buffers:text-between doc start end)) "```"))))

(define (region-text chat b start end)
  (%check-chat 'pi-chat:region-text chat)
  (unless (buffers:buffer? b)
    (assertion-violation 'pi-chat:region-text "not a buffer" b))
  (unless (and (fixnum? start) (fixnum? end) (fx<= 0 start end (document:length (buffers:document b))))
    (assertion-violation 'pi-chat:region-text "not a start and an end in the buffer" start end))
  (%region-text chat b start end))

(define (%relative dir path)
  (let ([d (string-append (%without-slash dir) "/")])
    (if (and (fx>= (string-length path) (string-length d)) (string=? (substring path 0 (string-length d)) d))
        (substring path (string-length d) (string-length path))
        path)))

(commands:define-command (add-region)
  "Adds the region to the prompt of the chat used last in its project, and shows the chat; asks to start one when there is none."
  (let* ([v (views:current)] [b (views:buffer v)] [mark (views:mark v)])
    (unless mark
      (error 'pi-chat:add-region "the region is empty"))
    (let ([chat (or (%last-chat-in b)
                    (let ([folder (folder-for b)])
                      (and (ask:y-or-n? (string-append "Start a Pi chat in " (files:abbreviated-path folder) "? "))
                           (pi:start folder))))])
      (when chat
        (add-to-prompt! chat (%region-text chat b (fxmin mark (views:point v)) (fxmax mark (views:point v))))
        (show! chat)))))

(commands:define-command (next-dialog)
  "Shows the chat whose question has waited longest, point where it is answered: at the end of its field's text, on its first option or on its first button."
  (let ([waiting (apply append (map (lambda (chat) (map (lambda (d) (cons chat d)) (pi:chat-dialogs chat))) (pi:chats)))])
    (when (null? waiting)
      (error 'pi-chat:next-dialog "no question waits"))
    (let* ([oldest (fold-left (lambda (best p)
                                (if (< (hashtable-ref %dialog-seen (pi:dialog-id (cdr p)) +inf.0)
                                       (hashtable-ref %dialog-seen (pi:dialog-id (cdr best)) +inf.0))
                                    p
                                    best))
                              (car waiting) (cdr waiting))]
           [chat (car oldest)] [b (%buffer-of chat)])
      (%rewrite! chat b)
      (show! chat)
      (let* ([n (%dialog-node-of b (cdr oldest))]
             [answer (and n (%child-of n '(pi-chat:%field ui:list pi-chat:%actions)))])
        (when answer
          (views:set-point! (layout:selected-view)
            (if (eq? (document:node-kind answer) 'pi-chat:%field)
                (fx- (document:node-end answer) 2)
                (fx+ (document:node-start answer) 1))))))))

(define (%remember! text)
  (set-saved! prompt-history (cons text (remove text (prompt-history)))))

(define (%trimmed s)
  (let loop ([i 0])
    (cond
      [(and (fx< i (string-length s)) (char-whitespace? (string-ref s i))) (loop (fx+ i 1))]
      [else
       (let back ([j (string-length s)])
         (if (and (fx> j i) (char-whitespace? (string-ref s (fx- j 1)))) (back (fx- j 1)) (substring s i j)))])))

;; Pi's terminal commands, which reach the model as text when sent
;; through a prompt.
(define %terminal-commands
  '("/settings" "/model" "/thinking" "/scoped-models" "/login" "/logout" "/llama" "/new" "/resume" "/name"
    "/session" "/tree" "/fork" "/clone" "/compact" "/import" "/copy" "/export" "/share" "/bug" "/trust" "/mcp"
    "/reload" "/hotkeys" "/changelog" "/quit"))

(define (%slash-name text)
  (if (and (fx> (string-length text) 1) (char=? (string-ref text 0) #\/))
      (let loop ([i 1])
        (if (or (fx= i (string-length text)) (char-whitespace? (string-ref text i)))
            (values (substring text 0 i) (%trimmed (substring text i (string-length text))))
            (loop (fx+ i 1))))
      (values #f #f)))

(define (%joined text current)
  (if (string=? current "") text (string-append text "\n" current)))

(define (%put-back! chat b text)
  (%set-prompt-text! b (%joined text (%prompt-text b))))

(define (%submit! chat tell!)
  (let* ([b (%buffer-of chat)] [text (%prompt-text b)])
    (unless (string=? (%trimmed text) "")
      (%remember! text)
      (hashtable-delete! %history-place b)
      (buffers:with-silent-edits b (%set-prompt-text! b ""))
      (%use! chat)
      (let-values ([(name argument) (%slash-name text)])
        (cond
          [(and name (table-ref slash-commands name #f)) => (lambda (run) (run chat argument))]
          [(and name (member name %terminal-commands)
                (not (exists (lambda (c) (string=? (string-append "/" (pi:slash-command-name c)) name))
                             (pi:chat-commands chat))))
           (%put-back! chat b text)
           (%chat-notice! chat 'warning (string-append name " is a command of Pi's terminal, which a chat cannot run"))]
          [else
           (guard (c [(pi:refused? c)
                      (%put-back! chat b text)
                      (%chat-notice! chat 'warning
                        (string-append "Pi refused the prompt: " (if (message-condition? c) (condition-message c) "")))])
             (tell! chat text))])))))

(commands:define-command (send)
  "Moves the prompt's text into the prompt history and sends it to Pi; while Pi works, as a steer read after its current tool calls."
  (%submit! (%current-chat 'pi-chat:send) pi:send!))

(commands:define-command (follow-up)
  "Moves the prompt's text into the prompt history and sends it to Pi; while Pi works, queued until Pi finishes."
  (%submit! (%current-chat 'pi-chat:follow-up) pi:follow-up!))

(commands:define-command (abort)
  "Stops Pi; what was queued comes back to the prompt."
  (let* ([chat (%current-chat 'pi-chat:abort)] [texts (pi:abort! chat)])
    (unless (null? texts)
      (%put-back! chat (%buffer-of chat) (apply string-append (%join texts "\n"))))))

(commands:define-command (take-queue)
  "Brings what Pi has queued back to the prompt."
  (let* ([chat (%current-chat 'pi-chat:take-queue)] [texts (pi:take-queue! chat)])
    (unless (null? texts)
      (%put-back! chat (%buffer-of chat) (apply string-append (%join texts "\n"))))))

(define (%recall! who step)
  (let* ([chat (%current-chat who)] [b (%buffer-of chat)] [history (prompt-history)]
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
  (%recall! 'pi-chat:previous-prompt 1))

(commands:define-command (next-prompt)
  "Puts a later prompt from the prompt history in the prompt, and at the end what was typed."
  (%recall! 'pi-chat:next-prompt -1))

(define %block-kinds '(pi-chat:thinking pi-chat:tool-call pi-chat:summary pi-chat:extension-message))

(define (%item-node-of b node)
  (let ([doc (buffers:document b)])
    (let loop ([n node])
      (let ([parent (document:enclosing doc (document:node-start n))])
        (cond
          [(not parent) #f]
          [(eq? (document:node-kind parent) 'pi-chat:%item) n]
          [else (loop parent)])))))

(define (%fold-place b block)
  (let ([item (%item-node-of b block)])
    (if (eq? item block)
        (cons (%attribute block 'key) 0)
        (cons (%attribute item 'key) (%attribute block 'key)))))

(commands:define-command (toggle-block)
  "Folds or unfolds the tool call, thinking, summary or extension message at point."
  (let* ([chat (%current-chat 'pi-chat:toggle-block)] [v (views:current)] [b (views:buffer v)]
         [block (%enclosing-of b (views:point v) %block-kinds)])
    (unless block
      (error 'pi-chat:toggle-block "no block is at point"))
    (let ([place (%fold-place b block)])
      (hashtable-set! %folds (%fold-key chat (car place) (cdr place)) (not (%attribute block 'open)))
      (%datums-changed!)
      (%rewrite! chat b))))

(commands:define-command (toggle-all-blocks)
  "Folds every block when any is unfolded, else unfolds every one."
  (let* ([chat (%current-chat 'pi-chat:toggle-all-blocks)] [b (%buffer-of chat)]
         [blocks (let walk ([nodes (%children (%part b 'pi-chat:transcript))])
                   (apply append
                     (map (lambda (n)
                            (append (if (memq (document:node-kind n) %block-kinds) (list n) '())
                                    (if (document:atom? n) '() (walk (%children n)))))
                          nodes)))]
         [open? (not (exists (lambda (n) (%attribute n 'open)) blocks))])
    (for-each
      (lambda (n)
        (let ([place (%fold-place b n)])
          (hashtable-set! %folds (%fold-key chat (car place) (cdr place)) open?)))
      blocks)
    (%datums-changed!)
    (%rewrite! chat b)))

(define (%item-at chat b position)
  (let ([node (%enclosing-of b position '(pi-chat:user-message pi-chat:reply pi-chat:summary pi-chat:extension-message
                                          pi-chat:notice pi-chat:tool-call))])
    (and node
         (let* ([item-node (%item-node-of b node)] [key (and item-node (%attribute item-node 'key))])
           (find (lambda (i) (equal? (pi:item-key i) key)) (pi:chat-transcript chat))))))

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

(define (%visit! chat path line)
  (let ([b (files:visit (%absolute (%chat-directory chat) path))])
    (layout:switch-to-buffer b)
    (views:set-point! (layout:selected-view) (editing:line-position b line))))

(commands:define-command (visit)
  "Opens the file of the tool call at point at its line, or the path:line at point."
  (let*-values ([(chat) (%current-chat 'pi-chat:visit)] [(v position) (%place)] [(b) (views:buffer v)])
    (let ([call-node (%enclosing-of b position '(pi-chat:tool-call))])
      (cond
        [(and call-node
              (let* ([item (%item-at chat b position)] [j (%attribute call-node 'key)])
                (and (pi:reply? item)
                     (let ([part (and (fixnum? j) (fx< j (length (pi:reply-parts item))) (list-ref (pi:reply-parts item) j))])
                       (and (pi:tool-call? part) (%argument (pi:tool-call-arguments part) "path") part)))))
         => (lambda (call)
              (let* ([arguments (pi:tool-call-arguments call)] [offset (and (pair? arguments) (assoc "offset" arguments))])
                (%visit! chat (%argument arguments "path") (if (and offset (fixnum? (cdr offset))) (cdr offset) 1))))]
        [(%path-line-at b position) => (lambda (p) (%visit! chat (car p) (cdr p)))]
        [else (error 'pi-chat:visit "no file is at point")]))))

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
                      (if (eq? (car (vector-ref datums j)) 'pi-chat:user-message) (cons (fx+ at 1) acc) acc)))))
        '())))

(define (describe-message transcript view)
  (unless (and (views:view? view) (views:buffer view))
    (assertion-violation 'pi-chat:describe-message "not a view showing a buffer" view))
  (unless (and (document:node? transcript) (eq? (document:node-kind transcript) 'pi-chat:transcript))
    (assertion-violation 'pi-chat:describe-message "not a chat's conversation" transcript))
  (let* ([p (views:point view)] [starts (%message-starts (views:buffer view) transcript)]
         [k (length (filter (lambda (s) (fx<= s p)) starts))])
    (and (fx> k 0) (format "message ~a of ~a" k (length starts)))))

(define (%describe-nothing node view) #f)

(commands:define-command (next-message)
  "Moves point to your next message."
  (let* ([v (views:current)] [b (views:buffer v)] [p (views:point v)]
         [next (find (lambda (s) (fx> s p)) (%message-starts b (%part b 'pi-chat:transcript)))])
    (unless next (error 'pi-chat:next-message "no later message"))
    (views:set-point! v (fx+ next 1))))

(commands:define-command (previous-message)
  "Moves point to your previous message."
  (let* ([v (views:current)] [b (views:buffer v)] [p (views:point v)]
         [here (%enclosing-of b p '(pi-chat:user-message))]
         [before (filter (lambda (s) (fx< s (if here (document:node-start here) p))) (%message-starts b (%part b 'pi-chat:transcript)))])
    (when (null? before) (error 'pi-chat:previous-message "no earlier message"))
    (views:set-point! v (fx+ (car (last-pair before)) 1))))

(define (%ask-while-working chat question)
  (or (not (pi:chat-working? chat)) (ask:y-or-n? question)))

(commands:define-command (fork-here)
  "Goes on in a new session from before your message at point, that message in the prompt."
  (let*-values ([(chat) (%current-chat 'pi-chat:fork-here)] [(v position) (%place)] [(b) (views:buffer v)])
    (let ([item (%item-at chat b position)])
      (unless (pi:user-message? item)
        (error 'pi-chat:fork-here "no message of yours is at point"))
      (unless (pi:item-entry-id item)
        (error 'pi-chat:fork-here "Pi has not saved this message yet"))
      (when (%ask-while-working chat "Pi is working; stop it and fork? ")
        (let ([text (pi:fork! chat (pi:item-entry-id item))])
          (%set-prompt-text! b text)
          (views:set-point! v (%prompt-end b)))))))

(define (%item-markdown item)
  (cond
    [(pi:user-message? item) (pi:user-message-text item)]
    [(pi:reply? item)
     (apply string-append
       (%join (map (lambda (p) (if (pi:text? p) (pi:text-string p) ""))
                   (filter pi:text? (pi:reply-parts item)))
              "\n\n"))]
    [(pi:summary? item) (pi:summary-text item)]
    [(pi:extension-message? item) (pi:extension-message-text item)]
    [(pi:notice? item) (pi:notice-text item)]
    [(pi:shell-command? item) (pi:shell-command-output item)]
    [else ""]))

(commands:define-command (copy-message)
  "Copies the message at point, as Markdown, to the kill ring."
  (let*-values ([(chat) (%current-chat 'pi-chat:copy-message)] [(v position) (%place)])
    (let ([item (%item-at chat (views:buffer v) position)])
      (unless item (error 'pi-chat:copy-message "no message is at point"))
      (kill-ring:push! (list (%item-markdown item))))))

(define (%dialog-of-point who)
  (let*-values ([(chat) (%current-chat who)] [(v position) (%place)] [(b) (views:buffer v)])
    (let* ([node (%enclosing-of b position '(pi-chat:dialog))] [d (and node (%dialog-at chat node))])
      (unless d (error who "no question is at point"))
      (values chat b v position node d))))

(define (%field-text b dialog-node)
  (let ([field (%child-of dialog-node '(pi-chat:%field))])
    (if field
        (document:text (buffers:document b) (fx+ (document:node-start field) 1) (fx- (document:node-end field) 2))
        "")))

(commands:define-command (answer)
  "Answers the question at point: the option at point, the button pushed, or the text typed."
  (let-values ([(chat b v position node d) (%dialog-of-point 'pi-chat:answer)])
    (let ([button (%enclosing-of b position '(pi-chat:%answer-button))]
          [list-node (%child-of node '(ui:list))])
      (cond
        [(eq? (pi:dialog-method d) (pi:method confirm))
         (unless button (error 'pi-chat:answer "push Yes or No"))
         (pi:answer! chat d (eq? (%attribute button 'value) #t))]
        [(eq? (pi:dialog-method d) (pi:method select))
         (let ([row (and list-node (ui:selected-row list-node v))])
           (unless row (error 'pi-chat:answer "no option is at point"))
           (pi:answer! chat d (list-ref (pi:dialog-options d) row)))]
        [else (pi:answer! chat d (%field-text b node))]))))

(commands:define-command (cancel-dialog)
  "Cancels the question at point."
  (let-values ([(chat b v position node d) (%dialog-of-point 'pi-chat:cancel-dialog)])
    (pi:cancel! chat d)))

(define (%new-session chat)
  (when (%ask-while-working chat "Pi is working; stop it and start a new session? ")
    (pi:new-session! chat)))

(commands:define-command (new-session)
  "Goes on in a new session; asks first while Pi works."
  (%new-session (%current-chat 'pi-chat:new-session)))

(commands:define-command (rename-session [name (ask:line "Session name: ")])
  "Names the session."
  (pi:set-session-name! (%current-chat 'pi-chat:rename-session) name))

(commands:define-command (clone)
  "Goes on in a copy of the session."
  (pi:clone! (%current-chat 'pi-chat:clone)))

(commands:define-command (compact [instructions (ask:line "Compaction instructions (empty for none): ")])
  "Summarises the conversation, with INSTRUCTIONS for the summary."
  (pi:compact! (%current-chat 'pi-chat:compact) instructions))

(commands:define-command (toggle-auto-compaction)
  "Turns Pi's own compaction on or off."
  (let ([chat (%current-chat 'pi-chat:toggle-auto-compaction)])
    (pi:set-auto-compaction! chat (not (pi:chat-auto-compaction? chat)))
    (%tell (if (pi:chat-auto-compaction? chat) "Pi compacts on its own" "Pi no longer compacts on its own"))))

(define (%tell text)
  (raise-continuable (condition (make-warning) (make-message-condition text))))

(commands:define-command (toggle-thinking)
  "Shows Pi's finished thinking in every chat, or folds it."
  (set-option! thinking-shown? (not (thinking-shown?)))
  (%tell (if (thinking-shown?) "Pi's finished thinking is shown" "Pi's finished thinking is folded")))

(define (%export chat path)
  (%tell (string-append "Exported the session to " (pi:export-html! chat path))))

(commands:define-command (export-html)
  "Writes the session as HTML and says where."
  (%export (%current-chat 'pi-chat:export-html) #f))

(define (%copy-last-reply chat)
  (let ([text (pi:last-reply chat)])
    (unless text (error 'pi-chat:copy-last-reply "Pi has not replied yet"))
    (kill-ring:push! (list text))))

(commands:define-command (copy-last-reply)
  "Copies Pi's last reply to the kill ring."
  (%copy-last-reply (%current-chat 'pi-chat:copy-last-reply)))

(commands:define-command (restart)
  "Restarts Pi on the chat's session; refused while Pi works."
  (pi:restart! (%current-chat 'pi-chat:restart)))

(commands:define-command (stop)
  "Ends Pi and kills the chat, asking first while Pi works."
  (let ([chat (%current-chat 'pi-chat:stop)])
    (when (%ask-while-working chat "Pi is working; stop it and end the chat? ")
      (pi:stop! chat))))

(ui:define-button %restart-button restart)

(ui:define-button %answer-button answer)

(ui:define-button %cancel-button cancel-dialog)

(define (%percent share) (string-append (number->string (exact (round (* 100 share)))) "%"))

(define (%cost dollars)
  (let* ([cents (exact (round (* 100 dollars)))] [whole (quotient cents 100)] [rest (remainder cents 100)])
    (string-append "$" (number->string whole) "." (if (< rest 10) "0" "") (number->string rest))))

(define (%activity-text chat)
  (let ([activity (pi:chat-activity chat)])
    (if (eq? activity (pi:activity running))
        (let ([running (filter (lambda (c) (eq? (pi:tool-call-state c) (pi:tool-state running))) (%tool-calls chat))])
          (if (null? running) "running" (string-append "running " (pi:tool-call-name (car (last-pair running))))))
        (symbol->string activity))))

(define (show-status view)
  (let ([chat (chat-of (views:buffer view))])
    (and chat
         (let-values ([(steering follow-ups) (pi:chat-queue chat)])
           (let* ([model (pi:chat-model chat)] [usage (pi:chat-usage chat)]
                  [queued (fx+ (length steering) (length follow-ups))])
             (apply string-append
               (%join
                 (filter values
                   (append
                     (list (and model (pi:model-name model))
                           (pi:chat-thinking-level chat)
                           (%activity-text chat)
                           (and usage (pi:usage-context-share usage) (%percent (pi:usage-context-share usage)))
                           (and usage (%cost (pi:usage-cost usage)))
                           (and (fx> queued 0) (string-append (number->string queued) " queued")))
                     (map cdr (pi:chat-statuses chat))))
                 " · ")))))))

(define (show-waiting view)
  (let ([n (fold-left (lambda (n chat) (fx+ n (length (pi:chat-dialogs chat)))) 0 (pi:chats))])
    (and (fx> n 0)
         (haml (:span.pi-chat-waiting ([title "Pi waits for an answer; click to go to the question"])
                 (if (fx= n 1) "Pi asks" (string-append "Pi asks " (number->string n) " questions")))))))

(define-table %waiting-keys "Clicks on the count of Pi's questions.")

(status-line:define-segment status (show show-status))

(status-line:define-segment waiting (show show-waiting) (keymap %waiting-keys))

(define (%chat-changed chat) (%mark-dirty! chat))

(define (%chat-edited b edit)
  (when (and (not (buffers:edit-silent? edit)) (chat-of b))
    (set! %drafts-changed? #t)))

(define (%draft-kept? b) (and (chat-of b) #t))

(define (%chat-buffer-killed b)
  (let ([chat (chat-of b)])
    (when chat
      (let ([d (%moved-draft chat)] [text (%prompt-text b)])
        (set-saved! drafts (%drafts-updated (drafts) chat (if d (%joined (cdr d) text) text))))
      (hashtable-delete! %buffers chat)
      (pi:stop! chat))))

(define (%option-changed option value)
  (when (eq? option thinking-shown?)
    (for-each %mark-dirty! (pi:chats))))

(define (%editor-text chat text)
  (let ([b (%buffer-of chat)])
    (%set-prompt-text! b text)
    (%mark-dirty! chat)))

(table-set! slash-commands "/new" (lambda (chat argument) (%new-session chat)))
(table-set! slash-commands "/name"
  (lambda (chat argument)
    (if (string=? argument "")
        (%tell (or (pi:chat-session-name chat) "The session has no name"))
        (pi:set-session-name! chat argument))))
(table-set! slash-commands "/compact" (lambda (chat argument) (pi:compact! chat argument)))
(table-set! slash-commands "/clone" (lambda (chat argument) (pi:clone! chat)))
(table-set! slash-commands "/copy" (lambda (chat argument) (%copy-last-reply chat)))
(table-set! slash-commands "/export"
  (lambda (chat argument) (%export chat (if (string=? argument "") #f argument))))

(keys:bind! %waiting-keys "<mouse-1>" next-dialog)
(keys:bind! %waiting-keys "<down-mouse-1>" keys:ignore)
(keys:bind! %waiting-keys "<drag-mouse-1>" keys:ignore)

(table-set! status-line:segments status (status-line:right 30))
(table-set! status-line:segments waiting (status-line:left 60))

(keys:bind! prompt-keymap "RET" send)
(keys:bind! prompt-keymap "C-c C-c" send)
(keys:bind! prompt-keymap "M-RET" follow-up)
(keys:bind! prompt-keymap "S-RET" editing:newline)
(keys:bind! prompt-keymap "M-p" previous-prompt)
(keys:bind! prompt-keymap "M-n" next-prompt)
(keys:bind! prompt-keymap "M-<up>" take-queue)
(keys:bind! transcript-keymap "TAB" toggle-block)
(keys:bind! transcript-keymap "RET" visit)
(keys:bind! transcript-keymap "n" next-message)
(keys:bind! transcript-keymap "p" previous-message)
(keys:bind! transcript-keymap "f" fork-here)
(keys:bind! transcript-keymap "w" copy-message)
(keys:bind! dialog-keymap "RET" answer)
(keys:bind! dialog-keymap "S-RET" editing:newline)
(keys:bind! dialog-keymap "C-c C-k" cancel-dialog)
(keys:bind! keymap "C-c C-k" abort)
(keys:bind! keymap "C-c C-o" toggle-all-blocks)
(keys:bind! keymap "C-c C-n" new-session)

(table-set! commands:command-modes send (list mode))
(table-set! commands:command-modes follow-up (list mode))
(table-set! commands:command-modes abort (list mode))
(table-set! commands:command-modes take-queue (list mode))
(table-set! commands:command-modes previous-prompt (list mode))
(table-set! commands:command-modes next-prompt (list mode))
(table-set! commands:command-modes toggle-block (list mode))
(table-set! commands:command-modes toggle-all-blocks (list mode))
(table-set! commands:command-modes toggle-thinking (list mode))
(table-set! commands:command-modes visit (list mode))
(table-set! commands:command-modes next-message (list mode))
(table-set! commands:command-modes previous-message (list mode))
(table-set! commands:command-modes fork-here (list mode))
(table-set! commands:command-modes copy-message (list mode))
(table-set! commands:command-modes answer (list mode))
(table-set! commands:command-modes cancel-dialog (list mode))
(table-set! commands:command-modes new-session (list mode))
(table-set! commands:command-modes rename-session (list mode))
(table-set! commands:command-modes clone (list mode))
(table-set! commands:command-modes compact (list mode))
(table-set! commands:command-modes toggle-auto-compaction (list mode))
(table-set! commands:command-modes export-html (list mode))
(table-set! commands:command-modes copy-last-reply (list mode))
(table-set! commands:command-modes restart (list mode))
(table-set! commands:command-modes stop (list mode))

(table-set! views:position-describers %chat %describe-nothing)
(table-set! views:position-describers transcript describe-message)
(table-set! views:position-describers prompt views:describe-line)
(table-set! web:stylesheets 'pi-chat "pi-chat/pi-chat.css")

(add-hook! pi:chat-changed %chat-changed)
(add-hook! pi:editor-text-requested %editor-text)
(add-hook! buffers:after-edit %chat-edited)
(add-hook! buffers:killed %chat-buffer-killed)
(add-hook! files:directory-finders %chat-buffer-directory)
(add-hook! files:unsaved-kept %draft-kept?)
(add-hook! option-changed %option-changed)

(advice-add! batch-ended
  (lambda (ended)
    (guard (c [#t (report c)])
      (as-module (this-module) (%redraw-dirty!)))
    (ended)))

(for-each (lambda (chat) (%buffer-of chat) (%mark-dirty! chat)) (pi:chats))

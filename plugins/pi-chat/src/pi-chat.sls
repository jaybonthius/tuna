#!tuna
(import (pi) (chat) (processes) (ask) (buffers) (document) (views) (keys) (commands) (modes) (ui) (kill-ring) (files)
        (web) (haml) (hooks) (tables) (saved))

(define %self (current-owner))

(saved:define-saved prompt-history '() (lambda (v) (and (list? v) (for-all string? v))))

(saved:define-saved drafts '()
  (lambda (v) (and (list? v) (for-all (lambda (d) (and (pair? d) (string? (car d)) (string? (cdr d)))) v))))

(tables:define-table slash-commands
  "Pi's own terminal commands typed at the prompt's start: each name, such as \"/compact\", to a procedure of the chat and the text after the name.")

(tables:define-table keymap "Keys anywhere in a Pi chat.")

(hooks:define-hook %mode-hook)

(modes:define-major-mode mode (parent chat:mode) (lighter "Pi") (keymap keymap) (hook %mode-hook) (plugin-only #t))

(define (%refuse-edits node edit) #f)

(define (%attribute node name) (document:node-attribute node name #f))

(define (%draw-summary node view)
  (haml (:div.pi-chat-summary ([data-open (%attribute node 'open)]) (views:draw-children view node))))

(define (%draw-extension-message node view)
  (haml (:div.pi-chat-extension-message ([data-open (%attribute node 'open)]) (views:draw-children view node))))

(define (%draw-widget node view)
  (haml (:div.pi-chat-widget (views:draw-children view node))))

(buffers:define-kind summary (content nodes) (consent %refuse-edits) (draw %draw-summary))
(buffers:define-kind extension-message (content nodes) (consent %refuse-edits) (draw %draw-extension-message))
(buffers:define-kind widget (consent %refuse-edits) (draw %draw-widget))

(define (current-chat)
  (let ([c (chat:current)])
    (and (pi:chat? c) c)))

(define (%current-chat who)
  (or (current-chat) (error who "not in a Pi chat")))

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

(define (%join strings separator)
  (if (null? strings)
      '()
      (cons (car strings) (apply append (map (lambda (s) (list separator s)) (cdr strings))))))

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
    (chat:header '() (chat:name '() (pi:tool-call-name call)) " " (%first-line (%main-argument call))
                 (if (null? details) "" (chat:detail '() (apply string-append " · " (%join details " · "))))
                 "\n")))

(define (%edit-diff call)
  (let ([edits (let ([a (and (pair? (pi:tool-call-arguments call)) (assoc "edits" (pi:tool-call-arguments call)))])
                 (if (and a (vector? (cdr a))) (vector->list (cdr a)) '()))])
    (apply chat:diff '((key . diff))
      (apply append
        (map (lambda (e)
               (append (map (lambda (l) (chat:removed '() (%line l))) (%lines (or (%argument e "oldText") "")))
                       (map (lambda (l) (chat:added '() (%line l))) (%lines (or (%argument e "newText") "")))))
             edits)))))

(define (%lines s)
  (let loop ([i 0] [start 0] [acc '()])
    (cond
      [(fx= i (string-length s)) (reverse (if (fx< start i) (cons (substring s start i) acc) acc))]
      [(char=? (string-ref s i) #\newline) (loop (fx+ i 1) (fx+ i 1) (cons (substring s start i) acc))]
      [else (loop (fx+ i 1) start acc)])))

(define (%tool-datum j call open?)
  (let* ([unfolded? (open? j #f)] [output (pi:tool-call-output call)]
         [body (cond
                 [(and unfolded? (equal? (pi:tool-call-name call) "edit")) (list (%edit-diff call))]
                 [(and unfolded? (not (string=? output ""))) (list (chat:output '((key . output)) (%line output)))]
                 [(and (eq? (pi:tool-call-state call) (pi:tool-state running)) (not (string=? output "")))
                  (list (chat:output '((key . last)) (%line (%last-line output))))]
                 [else '()])])
    (apply chat:tool-call (list (cons 'key j) (cons 'state (pi:tool-call-state call)) (cons 'open unfolded?))
      (%tool-header call) body)))

(define (%text-state item)
  (if (pi:item-entry-id item) (chat:text-state history) (chat:text-state live)))

(define (%reply-datum item open?)
  (let* ([k (pi:item-key item)] [pending? (eq? (pi:reply-stop item) (pi:stop pending))] [parts (pi:reply-parts item)]
         [last-part (and (pair? parts) (car (last-pair parts)))]
         [state (if pending? (chat:text-state streaming) (%text-state item))])
    (apply chat:reply (list (cons 'key k) (cons 'stop (pi:reply-stop item)))
      (append
        (let loop ([parts parts] [j 0] [acc '()])
          (if (null? parts)
              (apply append (reverse acc))
              (let ([p (car parts)])
                (loop (cdr parts) (fx+ j 1)
                      (cons
                        (cond
                          [(pi:text? p) (chat:markdown-blocks (pi:text-string p) state j)]
                          [(pi:thinking? p)
                           (let* ([streaming? (and pending? (eq? p last-part))]
                                  [unfolded? (open? j (or streaming? (chat:thinking-shown?)))])
                             (list (apply chat:thinking (list (cons 'key j) (cons 'open unfolded?))
                                     (chat:header '() (if streaming? "Thinking…\n" "Thinking\n"))
                                     (if unfolded?
                                         (chat:markdown-blocks (pi:thinking-string p)
                                           (if streaming? (chat:text-state streaming) (%text-state item)) j)
                                         '()))))]
                          [else (list (%tool-datum j p open?))])
                        acc)))))
        (let ([stop (pi:reply-stop item)])
          (if (memq stop (list (pi:stop error) (pi:stop aborted)))
              (list (chat:notice '((key . stopped) (level . error))
                                 (string-append (if (eq? stop (pi:stop error)) "Failed" "Stopped")
                                                (let ([e (pi:reply-error item)]) (if e (string-append ": " e) "")) "\n")))
              '()))))))

;; Pi's exit is an item of its own so that its notice follows the chat's
;; own notices, as the conversation's last word.
(define %exited 'exited)

(define (%items chat)
  (let ([items (pi:chat-transcript chat)])
    (if (eq? (pi:chat-activity chat) (pi:activity exited))
        (append items (list %exited))
        items)))

(define (%item-key item)
  (if (eq? item %exited) %exited (pi:item-key item)))

(define (%item-datum chat item open?)
  (cond
    [(eq? item %exited)
     (chat:notice '((key . exited) (level . error)) (%restart-button '() "Restart Pi") "\n")]
    [(pi:user-message? item)
     (let ([k (pi:item-key item)] [images (pi:user-message-images item)])
       (apply chat:user-message (list (cons 'key k))
         (append (chat:markdown-blocks (pi:user-message-text item) (%text-state item) 0)
                 (if (fx> images 0)
                     (list (chat:notice '((key . images) (level . info))
                                        (string-append (number->string images) (if (fx= images 1) " image\n" " images\n"))))
                     '()))))]
    [(pi:reply? item) (%reply-datum item open?)]
    [(pi:shell-command? item)
     (let ([k (pi:item-key item)] [unfolded? (open? 0 #f)] [output (pi:shell-command-output item)])
       (apply chat:tool-call (list (cons 'key k) (cons 'state (pi:tool-state done)) (cons 'open unfolded?))
         (chat:header '() (chat:name '() "!") " " (%first-line (pi:shell-command-line item))
                      (let ([exit (pi:shell-command-exit item)])
                        (if (and (number? exit) (not (= exit 0)))
                            (chat:detail '() (string-append " · exit " (number->string exit)))
                            ""))
                      "\n")
         (if (and unfolded? (not (string=? output ""))) (list (chat:output '((key . output)) (%line output))) '())))]
    [(pi:summary? item)
     (let ([unfolded? (open? 0 #f)])
       (apply summary (list (cons 'key (pi:item-key item)) (cons 'open unfolded?))
         (chat:header '()
           (if (eq? (pi:summary-kind item) 'compaction) "Pi summarised the conversation" "Pi summarised a branch left behind")
           (let ([tokens (pi:summary-tokens-before item)])
             (if (number? tokens) (chat:detail '() (string-append " · " (number->string tokens) " tokens before")) ""))
           "\n")
         (if unfolded? (chat:markdown-blocks (pi:summary-text item) (%text-state item) 0) '())))]
    [(pi:extension-message? item)
     (let* ([text (pi:extension-message-text item)] [unfolded? (open? 0 (fx<= (%line-count text) 12))])
       (apply extension-message (list (cons 'key (pi:item-key item)) (cons 'open unfolded?))
         (chat:header '() (chat:name '() (pi:extension-message-type item)) "\n")
         (if unfolded? (chat:markdown-blocks text (%text-state item) 0) '())))]
    [(pi:notice? item)
     (chat:notice (list (cons 'key (pi:item-key item)) (cons 'level (pi:notice-level item))) (%line (pi:notice-text item)))]
    [else #f]))

(define (%dialog-datum chat d)
  (let ([method (pi:dialog-method d)] [title (pi:dialog-title d)])
    (apply chat:question (list (cons 'method method))
      (chat:header '() title
        (if (and (eq? method (pi:method input)) (pi:dialog-text d))
            (chat:detail '() (string-append " · " (pi:dialog-text d)))
            "")
        "\n")
      (append
        (if (pi:dialog-message d) (list (chat:message '() (%line (pi:dialog-message d)))) '())
        (cond
          [(eq? method (pi:method select))
           (list (chat:answers
                   (list (cons 'key 'answers)
                         (cons 'answers (map (lambda (option) (list (cons 'label option) (cons 'key #f) (cons 'value option)))
                                             (pi:dialog-options d))))))]
          [(eq? method (pi:method input)) (list (chat:field '((key . field)) "\n"))]
          [(eq? method (pi:method editor)) (list (chat:field '((key . field) (lines . #t)) (or (pi:dialog-text d) "") "\n"))]
          [else '()])
        (list
          (cond
            [(eq? method (pi:method confirm))
             (chat:actions '() (chat:answer-button '((value . #t)) "Yes") " " (chat:answer-button '((value . #f)) "No") "\n")]
            [(eq? method (pi:method select)) (chat:actions '() (chat:cancel-button '() "Cancel") "\n")]
            [else (chat:actions '() (chat:answer-button '((value . field)) "Answer") " " (chat:cancel-button '() "Cancel") "\n")]))))))

(define (%queue chat)
  (let-values ([(steering follow-ups) (pi:chat-queue chat)])
    (append (map (lambda (text) (cons (chat:delivery next-step) text)) steering)
            (map (lambda (text) (cons (chat:delivery turn-end) text)) follow-ups))))

(define (%widget-datums chat placement)
  (map (lambda (w)
         (widget (list (cons 'key (pi:widget-key w)))
                 (apply string-append (map %line (if (null? (pi:widget-lines w)) '("") (pi:widget-lines w))))))
       (filter (lambda (w) (eq? (pi:widget-placement w) placement)) (pi:chat-widgets chat))))

(define (%widgets-above chat) (%widget-datums chat 'above))

(define (%widgets-below chat) (%widget-datums chat 'below))

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
    [else #f]))

(define (%location chat item part-key)
  (and (pi:reply? item) (fixnum? part-key) (fx< part-key (length (pi:reply-parts item)))
       (let ([part (list-ref (pi:reply-parts item) part-key)])
         (and (pi:tool-call? part)
              (let* ([arguments (pi:tool-call-arguments part)] [path (%argument arguments "path")]
                     [offset (and (pair? arguments) (assoc "offset" arguments))])
                (and path (cons path (if (and offset (fixnum? (cdr offset))) (cdr offset) 1))))))))

(define (%activity-word chat) (symbol->string (pi:chat-activity chat)))

(define (%tool-calls chat)
  (apply append
    (map (lambda (item) (if (pi:reply? item) (filter pi:tool-call? (pi:reply-parts item)) '()))
         (pi:chat-transcript chat))))

(define (%activity-text chat)
  (let ([activity (pi:chat-activity chat)])
    (if (eq? activity (pi:activity running))
        (let ([running (filter (lambda (c) (eq? (pi:tool-call-state c) (pi:tool-state running))) (%tool-calls chat))])
          (if (null? running) "running" (string-append "running " (pi:tool-call-name (car (last-pair running))))))
        (symbol->string activity))))

(define (%percent share) (string-append (number->string (exact (round (* 100 share)))) "%"))

(define (%cost dollars)
  (let* ([cents (exact (round (* 100 dollars)))] [whole (quotient cents 100)] [rest (remainder cents 100)])
    (string-append "$" (number->string whole) "." (if (< rest 10) "0" "") (number->string rest))))

(define (%status chat)
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
          " · ")))))

(define (%commands chat)
  (let ([pi-commands (map (lambda (c) (cons (pi:slash-command-name c) (pi:slash-command-description c)))
                          (pi:chat-commands chat))])
    (append pi-commands
            (map (lambda (name) (cons (substring name 1 (string-length name)) #f))
                 (list-sort string<?
                   (remp (lambda (name) (assoc (substring name 1 (string-length name)) pi-commands))
                         (map car (tables:entries slash-commands))))))))

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

(define (%deliver chat text tell!)
  (let-values ([(name argument) (%slash-name text)])
    (cond
      [(and name (tables:ref slash-commands name #f)) => (lambda (run) (run chat argument))]
      [(and name (member name %terminal-commands)
            (not (exists (lambda (c) (string=? (string-append "/" (pi:slash-command-name c)) name))
                         (pi:chat-commands chat))))
       (chat:refuse (string-append name " is a command of Pi's terminal, which a chat cannot run"))]
      [else (tell! chat text)])))

(define (%send chat text) (%deliver chat text pi:send!))

(define (%follow-up chat text) (%deliver chat text pi:follow-up!))

(define (%ask-while-working chat question)
  (or (not (pi:chat-working? chat)) (ask:y-or-n? question)))

(define (%fork chat item)
  (unless (pi:item-entry-id item)
    (error 'chat:fork "Pi has not saved this message yet"))
  (when (%ask-while-working chat "Pi is working; stop it and fork? ")
    (chat:set-prompt! chat (pi:fork! chat (pi:item-entry-id item)))
    (views:set-point! (views:current) (chat:prompt-end chat))))

(define (%new-session chat)
  (when (%ask-while-working chat "Pi is working; stop it and start a new session? ")
    (pi:new-session! chat)))

(define (%clone chat)
  (when (%ask-while-working chat "Pi is working; stop it and clone the session? ")
    (pi:clone! chat)))

(chat:define-source source
  (conversation? pi:chat?)
  (conversations pi:chats)
  (title "Pi")
  (mode mode)
  (directory pi:chat-directory)
  (session pi:chat-session-id)
  (start pi:start)
  (items %items)
  (item-key %item-key)
  (draw-item %item-datum)
  (activity %activity-word)
  (working? pi:chat-working?)
  (history prompt-history)
  (drafts drafts)
  (send %send)
  (cancel pi:abort!)
  (item-text %item-markdown)
  (location %location)
  (questions pi:chat-dialogs)
  (question-id pi:dialog-id)
  (draw-question %dialog-datum)
  (answer pi:answer!)
  (cancel-question pi:cancel!)
  (queue %queue)
  (follow-up %follow-up)
  (take-queue pi:take-queue!)
  (refused? pi:refused?)
  (status %status)
  (commands %commands)
  (above %widgets-above)
  (below %widgets-below)
  (kill pi:stop!)
  (fork %fork)
  (last-reply pi:last-reply))

(commands:define-command (open [new? (and (commands:prefix-argument) #t)])
  "Shows the Pi chat used last in the current buffer's project, point in its prompt, starting one when there is none; with C-u, always a new one."
  (chat:open source new?))

(commands:define-command (new-session)
  "Goes on in a new session; asks first while Pi works."
  (%new-session (%current-chat 'pi-chat:new-session)))

(commands:define-command (rename-session [name (ask:line "Session name: ")])
  "Names the session."
  (pi:set-session-name! (%current-chat 'pi-chat:rename-session) name))

(commands:define-command (clone)
  "Goes on in a copy of the session; asks first while Pi works."
  (%clone (%current-chat 'pi-chat:clone)))

(commands:define-command (compact [instructions (ask:line "Compaction instructions (empty for none): ")])
  "Summarises the conversation, with INSTRUCTIONS for the summary."
  (pi:compact! (%current-chat 'pi-chat:compact) instructions))

(commands:define-command (toggle-auto-compaction)
  "Turns Pi's own compaction on or off."
  (let ([chat (%current-chat 'pi-chat:toggle-auto-compaction)])
    (pi:set-auto-compaction! chat (not (pi:chat-auto-compaction? chat)))
    (ask:message (if (pi:chat-auto-compaction? chat) "Pi compacts on its own" "Pi no longer compacts on its own"))))

(define (%export chat path)
  (ask:message (string-append "Exported the session to " (pi:export-html! chat path))))

(commands:define-command (export-html)
  "Writes the session as HTML and says where."
  (%export (%current-chat 'pi-chat:export-html) #f))

(commands:define-command (restart)
  "Restarts Pi on the chat's session; refused while Pi works."
  (pi:restart! (%current-chat 'pi-chat:restart)))

(commands:define-command (stop)
  "Ends Pi and kills the chat, asking first while Pi works."
  (let ([chat (%current-chat 'pi-chat:stop)])
    (when (%ask-while-working chat "Pi is working; stop it and end the chat? ")
      (pi:stop! chat))))

(ui:define-button %restart-button restart)

(define (%absolute dir path)
  (if (and (fx> (string-length path) 0) (char=? (string-ref path 0) #\/))
      path
      (string-append dir (if (and (fx> (string-length dir) 0) (char=? (string-ref dir (fx- (string-length dir) 1)) #\/)) "" "/")
                     path)))

(define %unfinished-tools (make-weak-eq-hashtable))

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
               (let ([path (%argument (pi:tool-call-arguments call) "path")])
                 (when (and path (eq? state (pi:tool-state done)))
                   (chat:files-edited! chat
                     (list (%absolute (files:expanded-path (pi:chat-directory chat)) path)))))]))))
      (%tool-calls chat))))

;; Each chat's buffer is its process's, so killing it ends Pi at once. A
;; restarted Pi is a new process, so the link is made again on each change.
(define (%link-process! chat)
  (let ([process (pi:chat-process chat)])
    (when process
      (let ([b (chat:buffer chat)])
        (unless (eq? (processes:buffer process) b)
          (processes:set-buffer! process b))))))

(define %edited-unchecked '())

;; Finding an edit rebuilds and walks the whole transcript, and Pi sends
;; an event for every piece of a reply, so chats are checked once per
;; batch.
(define (%chat-changed chat)
  (chat:changed! chat)
  (when (memq chat (pi:chats))
    (%link-process! chat)
    (unless (memq chat %edited-unchecked)
      (set! %edited-unchecked (cons chat %edited-unchecked)))))

(define (%revert-edits!)
  (let ([chats %edited-unchecked])
    (set! %edited-unchecked '())
    (for-each (lambda (chat) (when (memq chat (pi:chats)) (%revert-edited! chat))) chats)))

(define (%editor-text chat text)
  (chat:set-prompt! chat text)
  (chat:changed! chat))

(tables:set! slash-commands "/new" (lambda (chat argument) (%new-session chat)))
(tables:set! slash-commands "/name"
  (lambda (chat argument)
    (if (string=? argument "")
        (ask:message (or (pi:chat-session-name chat) "The session has no name"))
        (pi:set-session-name! chat argument))))
(tables:set! slash-commands "/compact" (lambda (chat argument) (pi:compact! chat argument)))
(tables:set! slash-commands "/clone" (lambda (chat argument) (%clone chat)))
(tables:set! slash-commands "/copy" (lambda (chat argument) (chat:copy-last-reply)))
(tables:set! slash-commands "/export"
  (lambda (chat argument) (%export chat (if (string=? argument "") #f argument))))

(keys:bind! keymap "C-c C-n" new-session)

(for-each (lambda (command) (tables:set! commands:command-modes command (list mode)))
  (list new-session rename-session clone compact toggle-auto-compaction export-html restart stop))

(tables:set! chat:block-kinds summary)
(tables:set! chat:block-kinds extension-message)
(tables:set! web:stylesheets 'pi-chat "pi-chat/pi-chat.css")

(for-each %link-process! (pi:chats))

(hooks:add! pi:chat-changed %chat-changed)
(hooks:add! pi:editor-text-requested %editor-text)

;; Added after chat's advice, so it wraps it: a notice of an edit is drawn
;; in the batch that found it.
(advice-add! batch-ended
  (lambda (ended)
    (guard (c [#t (report c)])
      (call-as-owner %self (lambda () (%revert-edits!))))
    (ended)))

#!tuna
(import (pi) (pi-chat) (projects) (completion) (minibuffer) (ask) (commands) (keys) (views) (buffers) (document)
        (faces) (files))

(completion:define-category chat-category "Live Pi chats, valued by the chat.")

(completion:define-category session-category "Pi's sessions of a folder, valued by the session.")

(completion:define-category model-category "Pi's models, valued by the model.")

(completion:define-category command-category
  "Pi's commands and the chat's own slash commands, valued by Pi's command or by the name.")

(define (%current-buffer)
  (let ([v (views:current)])
    (and v (views:buffer v))))

(define (%current-chat who)
  (or (pi-chat:current-chat) (error who "not in a Pi chat")))

(define (%ask-while-working chat question)
  (or (not (pi:chat-working? chat)) (ask:y-or-n? question)))

(define (%first-line s)
  (let loop ([i 0])
    (cond
      [(fx= i (string-length s)) s]
      [(char=? (string-ref s i) #\newline) (substring s 0 i)]
      [else (loop (fx+ i 1))])))

(define (%choose question choices choice-category preview default input)
  (cond
    [(and input (not (string=? input "")) (assoc input choices)) => cdr]
    [else
     (minibuffer:call-with-setup
       (lambda (p)
         (when (and input (not (string=? input "")))
           (minibuffer:set-input! p input)))
       (lambda ()
         (completion:read question
           (list (completion:source
                   (candidates (list->vector choices))
                   (in-order)
                   (category choice-category)
                   (preview preview)))
           #f
           default)))]))

(define (%check-choices who choices none)
  (when (null? choices)
    (error who none))
  choices)

(define (%chat-choices chats)
  (map (lambda (chat) (cons (buffers:name (pi-chat:buffer chat)) chat)) chats))

(define (%chat-preview view)
  (lambda (chat)
    (if chat (views:preview-buffer! view (pi-chat:buffer chat)) (views:end-preview! view))))

(define (%chats-for b)
  (if b (pi-chat:chats-for b) (reverse (pi:chats))))

(define (%read-switch)
  (let* ([b (%current-buffer)] [current (pi-chat:current-chat)] [chats (%chats-for b)]
         [ordered (if current (append (remq current chats) (list current)) chats)])
    (%choose "Switch to chat: "
      (%check-choices 'pi-picker:switch-to-chat (%chat-choices ordered) "no Pi chat is open")
      chat-category (%chat-preview (views:current)) #f #f)))

(commands:define-command (switch-to-chat [chat (%read-switch)])
  "Shows CHAT, read with a preview of each."
  (%check-chat 'pi-picker:switch-to-chat chat)
  (pi-chat:show! chat))

(define (%check-chat who v)
  (unless (pi:chat? v)
    (assertion-violation who "not a chat" v)))

(define (%region who)
  (let* ([v (views:current)] [mark (and v (views:mark v))])
    (unless mark
      (error who "the region is empty"))
    (values (views:buffer v) (fxmin mark (views:point v)) (fxmax mark (views:point v)))))

(define (%read-region-chat)
  (let-values ([(b start end) (%region 'pi-picker:add-region-to)])
    (%choose "Add the region to chat: "
      (%check-choices 'pi-picker:add-region-to (%chat-choices (%chats-for b)) "no Pi chat is open")
      chat-category #f #f #f)))

(commands:define-command (add-region-to [chat (%read-region-chat)])
  "Adds the region to the prompt of CHAT, as pi-chat:add-region does, and shows the chat."
  (%check-chat 'pi-picker:add-region-to chat)
  (let-values ([(b start end) (%region 'pi-picker:add-region-to)])
    (pi-chat:add-to-prompt! chat (pi-chat:region-text chat b start end))
    (pi-chat:show! chat)))

(define (%session-text s)
  (let ([name (pi:session-name s)] [message (pi:session-first-message s)])
    (cond
      [name name]
      [(string=? message "") (pi:session-id s)]
      [else message])))

(define (%folder who)
  (let ([b (%current-buffer)])
    (unless b (error who "no buffer is current"))
    (pi-chat:folder-for b)))

(define (%read-session folder input)
  (%choose "Resume session: "
    (%check-choices 'pi-picker:resume
      (map (lambda (s) (cons (%session-text s) s)) (pi:sessions folder))
      (string-append "no Pi session in " folder))
    session-category #f #f input))

;; Two Pis on one session would each write their own tree, so a session a
;; live chat is on shows that chat.
(define (%resume! chat folder session)
  (let ([live (find (lambda (c) (string=? (pi:chat-session-id c) (pi:session-id session))) (pi:chats))])
    (cond
      [live (pi-chat:show! live)]
      [(not chat) (pi-chat:show! (pi:start folder (pi:session-id session)))]
      [(%ask-while-working chat "Pi is working; stop it and resume another session? ")
       (pi:switch-session! chat (pi:session-file session))])))

(commands:define-command (resume [session (%read-session (%folder 'pi-picker:resume) #f)])
  "Goes on in SESSION, one of the chat folder's sessions, asking first while Pi works; outside a chat, starts a chat on it."
  (unless (pi:session? session)
    (assertion-violation 'pi-picker:resume "not a session" session))
  (%resume! (pi-chat:current-chat) (%folder 'pi-picker:resume) session))

(define (%read-fork-message chat input)
  (%choose "Fork from message: "
    (%check-choices 'pi-picker:fork
      (map (lambda (m) (cons (%first-line (cdr m)) (car m))) (reverse (pi:fork-messages chat)))
      "no message of yours to fork from")
    #f #f #f input))

(define (%fork! chat entry-id)
  (when (%ask-while-working chat "Pi is working; stop it and fork? ")
    (pi-chat:set-prompt! chat (pi:fork! chat entry-id))
    (pi-chat:show! chat)))

(commands:define-command (fork [entry-id (%read-fork-message (%current-chat 'pi-picker:fork) #f)])
  "Goes on in a new session holding what came before your message ENTRY-ID, that message in the prompt; asks first while Pi works."
  (unless (string? entry-id)
    (assertion-violation 'pi-picker:fork "not an entry id" entry-id))
  (%fork! (%current-chat 'pi-picker:fork) entry-id))

(define (%model-text m) (string-append (pi:model-provider m) "/" (pi:model-id m)))

(define (%read-model chat input)
  (let ([current (pi:chat-model chat)])
    (%choose "Model: "
      (%check-choices 'pi-picker:select-model
        (map (lambda (m) (cons (%model-text m) m)) (pi:models chat))
        "Pi offers no model")
      model-category #f (and current (%model-text current)) input)))

(commands:define-command (select-model [model (%read-model (%current-chat 'pi-picker:select-model) #f)])
  "Sets the model of this chat to MODEL."
  (unless (pi:model? model)
    (assertion-violation 'pi-picker:select-model "not a model" model))
  (pi:set-model! (%current-chat 'pi-picker:select-model) model))

(define (%read-thinking-level chat input)
  (%choose "Thinking level: "
    (%check-choices 'pi-picker:select-thinking-level
      (map (lambda (level) (cons level level)) (pi:thinking-levels chat))
      "the model offers no thinking level")
    #f #f (pi:chat-thinking-level chat) input))

(commands:define-command (select-thinking-level
                           [level (%read-thinking-level (%current-chat 'pi-picker:select-thinking-level) #f)])
  "Sets the thinking level of this chat to LEVEL."
  (unless (string? level)
    (assertion-violation 'pi-picker:select-thinking-level "not a string" level))
  (pi:set-thinking-level! (%current-chat 'pi-picker:select-thinking-level) level))

(define (%commands-of chat source)
  (map (lambda (c) (cons (pi:slash-command-name c) c))
       (filter (lambda (c) (eq? (pi:slash-command-source c) source)) (pi:chat-commands chat))))

(define (%read-pi-command chat)
  (when (null? (pi:chat-commands chat))
    (error 'pi-picker:run-command "Pi has no command"))
  (completion:read "Pi command: "
    (list (completion:source
            (candidates (list->vector (%commands-of chat 'skill)))
            (title "Skills")
            (category command-category))
          (completion:source
            (candidates (list->vector (%commands-of chat 'prompt)))
            (title "Prompt templates")
            (category command-category))
          (completion:source
            (candidates (list->vector (%commands-of chat 'extension)))
            (title "Extension commands")
            (category command-category)))
    #f))

(commands:define-command (run-command [command (%read-pi-command (%current-chat 'pi-picker:run-command))])
  "Reads the arguments of COMMAND, one of Pi's commands, and sends it to Pi."
  (unless (pi:slash-command? command)
    (assertion-violation 'pi-picker:run-command "not one of Pi's commands" command))
  (let* ([chat (%current-chat 'pi-picker:run-command)] [name (pi:slash-command-name command)]
         [arguments (ask:line (string-append "Arguments for /" name " (empty for none): "))])
    (pi:send! chat (if (string=? arguments "") (string-append "/" name) (string-append "/" name " " arguments)))))

(define (%word-start doc from point)
  (let loop ([i point])
    (if (and (fx> i from) (not (char-whitespace? (document:token doc (fx- i 1)))))
        (loop (fx- i 1))
        i)))

(define (%word-end doc point to)
  (let loop ([i point])
    (if (and (fx< i to) (not (char-whitespace? (document:token doc i))))
        (loop (fx+ i 1))
        i)))

(define (%with-slash dir)
  (if (and (fx> (string-length dir) 0) (char=? (string-ref dir (fx- (string-length dir) 1)) #\/))
      dir
      (string-append dir "/")))

(define (%starts-with? s part)
  (let ([n (string-length part)])
    (and (fx<= n (string-length s))
         (let loop ([i 0])
           (or (fx= i n) (and (char=? (string-ref s i) (string-ref part i)) (loop (fx+ i 1))))))))

(define (%last-slash text before)
  (let loop ([i (fx- before 1)])
    (cond
      [(fx< i 0) #f]
      [(char=? (string-ref text i) #\/) i]
      [else (loop (fx- i 1))])))

(define (%mention-receiver emit root folder)
  (let ([under (and (%starts-with? folder root) (substring folder (string-length root) (string-length folder)))]
        [seen (make-hashtable string-hash string=?)])
    ;; A folder is seen only with every folder above it, so the walk up
    ;; ends at the first one seen.
    (define (add-folders text slash found)
      (let ([shown (substring text 0 (fx+ slash 1))])
        (if (hashtable-contains? seen shown)
            found
            (let ([above (%last-slash text slash)])
              (hashtable-set! seen shown #t)
              (cons (cons shown (string-append folder shown))
                    (if above (add-folders text above found) found))))))
    (lambda (files)
      (cond
        [(eof-object? files) (emit 'done)]
        [under
         (let ([found '()])
           (vector-for-each
             (lambda (path)
               (when (%starts-with? path under)
                 (let* ([text (if (string=? under "") path (substring path (string-length under) (string-length path)))]
                        [slash (%last-slash text (string-length text))])
                   (set! found (cons (cons text (string-append root path))
                                     (if slash (add-folders text slash found) found))))))
             files)
           (unless (null? found) (emit (list->vector (reverse found)))))]))))

(define (%mention-stream folder)
  (lambda (emit)
    (let ([stop #f])
      (lambda (prefix)
        (cond
          [(eof-object? prefix) (when stop (stop))]
          [(projects:find folder)
           => (lambda (project)
                (set! stop
                  (as-module (this-module)
                    (projects:list-files project (%mention-receiver emit (projects:root project) folder)))))]
          [else (emit 'done)])))))

(define (%point-in-prompt chat)
  (let ([point (views:point (views:current))])
    (and (fx<= (pi-chat:prompt-start chat) point (pi-chat:prompt-end chat)) point)))

;; An @ inside a word, as in an address, starts no mention.
(define (complete-mention)
  (let* ([chat (pi-chat:current-chat)] [point (and chat (%point-in-prompt chat))])
    (and point
         (let* ([doc (buffers:document (pi-chat:buffer chat))]
                [start (%word-start doc (pi-chat:prompt-start chat) point)])
           (and (fx< start point)
                (eqv? (document:token doc start) #\@)
                (completion:region (fx+ start 1) (%word-end doc point (pi-chat:prompt-end chat))
                  (list (completion:source
                          (stream (%mention-stream (%with-slash (pi:chat-directory chat))))
                          (category completion:file-category)))))))))

(define (%command-choices chat)
  (let ([pi-commands (map (lambda (c) (cons (string-append "/" (pi:slash-command-name c)) c)) (pi:chat-commands chat))])
    (list->vector
      (append pi-commands
              (map (lambda (name) (cons name name))
                   (list-sort string<?
                     (remp (lambda (name) (assoc name pi-commands)) (map car (table-entries pi-chat:slash-commands)))))))))

(define (complete-command)
  (let* ([chat (pi-chat:current-chat)] [point (and chat (%point-in-prompt chat))])
    (and point
         (let ([doc (buffers:document (pi-chat:buffer chat))] [start (pi-chat:prompt-start chat)])
           (and (eqv? (document:token doc start) #\/)
                (fx= (%word-start doc start point) start)
                (completion:region start (%word-end doc point (pi-chat:prompt-end chat))
                  (list (completion:source
                          (candidates (lambda (prefix) (%command-choices chat)))
                          (category command-category)))))))))

(define (%age t)
  (let ([seconds (max 0 (time-second (time-difference (current-time 'time-utc) t)))])
    (cond
      [(< seconds 60) "just now"]
      [(< seconds 3600) (string-append (number->string (quotient seconds 60)) " min ago")]
      [(< seconds 86400) (string-append (number->string (quotient seconds 3600)) " h ago")]
      [else (string-append (number->string (quotient seconds 86400)) " d ago")])))

(define (%count n one many)
  (string-append (number->string n) " " (if (= n 1) one many)))

(define (%tokens n)
  (cond
    [(>= n 1000000) (string-append (number->string (quotient n 1000000)) "M tokens")]
    [(>= n 1000) (string-append (number->string (quotient n 1000)) "k tokens")]
    [else (string-append (number->string n) " tokens")]))

(define (annotate-chat session)
  (lambda (chat details)
    (list (cons faces:shadow (files:abbreviated-path (pi:chat-directory chat)))
          (cons faces:shadow (symbol->string (pi:chat-activity chat))))))

(define (annotate-session session)
  (lambda (s details)
    (list (cons faces:shadow (%age (pi:session-modified s)))
          (cons faces:shadow (%count (pi:session-message-count s) "message" "messages")))))

(define (annotate-model session)
  (lambda (m details)
    (list (cons faces:shadow (pi:model-name m))
          (cons faces:shadow (let ([w (pi:model-context-window m)]) (if w (%tokens w) ""))))))

(define (annotate-command session)
  (lambda (c details)
    (if (pi:slash-command? c)
        (list (cons faces:shadow (%first-line (pi:slash-command-description c))))
        '())))

(table-set! completion:annotators chat-category annotate-chat)
(table-set! completion:annotators session-category annotate-session)
(table-set! completion:annotators model-category annotate-model)
(table-set! completion:annotators command-category annotate-command)

(add-hook! completion:find-region complete-mention)
(add-hook! completion:find-region complete-command)

(table-set! pi-chat:slash-commands "/model"
  (lambda (chat argument) (pi:set-model! chat (%read-model chat argument))))
(table-set! pi-chat:slash-commands "/thinking"
  (lambda (chat argument) (pi:set-thinking-level! chat (%read-thinking-level chat argument))))
(table-set! pi-chat:slash-commands "/resume"
  (lambda (chat argument)
    (%resume! chat (pi:chat-directory chat) (%read-session (pi:chat-directory chat) argument))))
(table-set! pi-chat:slash-commands "/fork"
  (lambda (chat argument) (%fork! chat (%read-fork-message chat argument))))

(keys:bind! pi-chat:prompt-keymap "TAB" completion:complete-at-point)
(keys:bind! pi-chat:keymap "C-c C-r" resume)
(keys:bind! pi-chat:keymap "C-c C-m" select-model)

(table-set! commands:command-modes fork (list pi-chat:mode))
(table-set! commands:command-modes select-model (list pi-chat:mode))
(table-set! commands:command-modes select-thinking-level (list pi-chat:mode))
(table-set! commands:command-modes run-command (list pi-chat:mode))

#!tuna
(import (pi) (pi-chat) (chat) (completion) (minibuffer) (ask) (commands) (keys) (views) (faces) (tables))

(completion:define-category session-category "Pi's sessions of a folder, valued by the session.")

(completion:define-category model-category "Pi's models, valued by the model.")

(completion:define-category command-category "Pi's commands, valued by the command.")

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
                   (preview preview (and preview (lambda (chosen) (preview #f))))))
           #f
           default)))]))

(define (%check-choices who choices none)
  (when (null? choices)
    (error who none))
  choices)

(define (%session-text s)
  (let ([name (pi:session-name s)] [message (pi:session-first-message s)])
    (cond
      [name name]
      [(string=? message "") (pi:session-id s)]
      [else message])))

(define (%folder who)
  (let ([b (%current-buffer)])
    (unless b (error who "no buffer is current"))
    (chat:folder-for b)))

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
      [live (chat:show! live)]
      [(not chat) (chat:show! (pi:start folder (pi:session-id session)))]
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
    (chat:set-prompt! chat (pi:fork! chat entry-id))
    (chat:show! chat)))

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

(tables:set! completion:annotators session-category annotate-session)
(tables:set! completion:annotators model-category annotate-model)
(tables:set! completion:annotators command-category annotate-command)

(tables:set! pi-chat:slash-commands "/model"
  (lambda (chat argument) (pi:set-model! chat (%read-model chat argument))))
(tables:set! pi-chat:slash-commands "/thinking"
  (lambda (chat argument) (pi:set-thinking-level! chat (%read-thinking-level chat argument))))
(tables:set! pi-chat:slash-commands "/resume"
  (lambda (chat argument)
    (%resume! chat (pi:chat-directory chat) (%read-session (pi:chat-directory chat) argument))))
(tables:set! pi-chat:slash-commands "/fork"
  (lambda (chat argument) (%fork! chat (%read-fork-message chat argument))))

(keys:bind! pi-chat:keymap "C-c C-r" resume)
(keys:bind! pi-chat:keymap "C-c C-m" select-model)

(tables:set! commands:command-modes fork (list pi-chat:mode))
(tables:set! commands:command-modes select-model (list pi-chat:mode))
(tables:set! commands:command-modes select-thinking-level (list pi-chat:mode))
(tables:set! commands:command-modes run-command (list pi-chat:mode))

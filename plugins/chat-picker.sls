#!tuna
(import (chat) (projects) (completion) (commands) (keys) (views) (buffers) (document) (faces) (files))

(completion:define-category chat-category "Live chats, valued by the conversation.")

(completion:define-category command-category "An agent's commands, valued by the name and its description.")

(define (%current-buffer)
  (let ([v (views:current)])
    (and v (views:buffer v))))

(define (%first-line s)
  (let loop ([i 0])
    (cond
      [(fx= i (string-length s)) s]
      [(char=? (string-ref s i) #\newline) (substring s 0 i)]
      [else (loop (fx+ i 1))])))

(define (%choose question choices preview)
  (completion:read question
    (list (completion:source
            (candidates (list->vector choices))
            (in-order)
            (category chat-category)
            (preview preview (and preview (lambda (chosen) (preview #f))))))
    #f
    #f))

(define (%check-choices who choices)
  (when (null? choices)
    (error who "no chat is open"))
  choices)

(define (%chat-choices chats)
  (map (lambda (c) (cons (buffers:name (chat:buffer c)) c)) chats))

(define (%chat-preview view)
  (lambda (c)
    (if c (views:preview-buffer! view (chat:buffer c)) (views:end-preview! view))))

(define (%read-switch)
  (let* ([current (chat:current)] [chats (chat:chats-for (%current-buffer))]
         [ordered (if current (append (remq current chats) (list current)) chats)])
    (%choose "Switch to chat: "
      (%check-choices 'chat-picker:switch-to-chat (%chat-choices ordered))
      (%chat-preview (views:current)))))

(define (%check-chat who c)
  (unless (chat:conversation? c)
    (assertion-violation who "not a chat" c)))

(commands:define-command (switch-to-chat [c (%read-switch)])
  "Shows C, a live chat, read with a preview of each."
  (%check-chat 'chat-picker:switch-to-chat c)
  (chat:show! c))

(define (%region who)
  (let* ([v (views:current)] [mark (and v (views:mark v))])
    (unless mark
      (error who "the region is empty"))
    (values (views:buffer v) (fxmin mark (views:point v)) (fxmax mark (views:point v)))))

(define (%read-region-chat)
  (let-values ([(b start end) (%region 'chat-picker:add-region-to)])
    (%choose "Add the region to chat: "
      (%check-choices 'chat-picker:add-region-to (%chat-choices (chat:chats-for b)))
      #f)))

(commands:define-command (add-region-to [c (%read-region-chat)])
  "Adds the region to the prompt of C, as chat:add-region does, and shows the chat."
  (%check-chat 'chat-picker:add-region-to c)
  (let-values ([(b start end) (%region 'chat-picker:add-region-to)])
    (chat:add-to-prompt! c (chat:region-text c b start end))
    (chat:show! c)))

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

(define (%point-in-prompt c)
  (let ([point (views:point (views:current))])
    (and (fx<= (chat:prompt-start c) point (chat:prompt-end c)) point)))

;; An @ inside a word, as in an address, starts no mention.
(define (complete-mention)
  (let* ([c (chat:current)] [point (and c (%point-in-prompt c))])
    (and point
         (let* ([b (chat:buffer c)] [doc (buffers:document b)]
                [start (%word-start doc (chat:prompt-start c) point)])
           (and (fx< start point)
                (eqv? (document:token doc start) #\@)
                (completion:region (fx+ start 1) (%word-end doc point (chat:prompt-end c))
                  (list (completion:source
                          (stream (%mention-stream (%with-slash (chat:folder-for b))))
                          (category completion:file-category)))))))))

(define (%command-choices c)
  (list->vector (map (lambda (command) (cons (string-append "/" (car command)) command)) (chat:commands c))))

(define (complete-command)
  (let* ([c (chat:current)] [point (and c (%point-in-prompt c))])
    (and point
         (let ([doc (buffers:document (chat:buffer c))] [start (chat:prompt-start c)])
           (and (eqv? (document:token doc start) #\/)
                (fx= (%word-start doc start point) start)
                (completion:region start (%word-end doc point (chat:prompt-end c))
                  (list (completion:source
                          (candidates (lambda (prefix) (%command-choices c)))
                          (category command-category)))))))))

(define (annotate-chat session)
  (lambda (c details)
    (list (cons faces:shadow (files:abbreviated-path (chat:folder-for (chat:buffer c))))
          (cons faces:shadow (chat:activity c)))))

(define (annotate-command session)
  (lambda (command details)
    (if (string? (cdr command))
        (list (cons faces:shadow (%first-line (cdr command))))
        '())))

(table-set! completion:annotators chat-category annotate-chat)
(table-set! completion:annotators command-category annotate-command)

(add-hook! completion:find-region complete-mention)
(add-hook! completion:find-region complete-command)

(keys:bind! chat:prompt-keymap "TAB" completion:complete-at-point)

(table-set! commands:region-commands add-region-to #t)

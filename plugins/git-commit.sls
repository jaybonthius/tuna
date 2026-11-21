#!tuna
(import (git-mode) (git) (with-editor) (transient) (modes) (auto-mode) (keys) (commands) (buffers) (document) (views)
        (layout) (files) (faces) (ask) (web))

(define-enumeration committer-date (now keep) %committer-dates)

(define-enumeration staging (ask stage refuse) %stagings)

(define-enumeration style-check (non-empty-second-line overlong-summary-line) %style-checks)

(define (%one-of names) (lambda (v) (and (memq v (enum-set->list (enum-set-universe names))) #t)))

(define (%strings? v) (and (list? v) (for-all string? v)))

(define-option arguments '("--verbose") %strings? "The arguments the commit menu starts with.")

(define-option published-branches '("origin/master") %strings?
  "The branches whose commits are published; amending one of their commits asks first.")

(define-option ask-to-stage (staging ask) (%one-of (%stagings))
  "What git-commit:create does with nothing staged: ask asks, stage commits everything without asking, refuse raises Nothing staged.")

(define-option extend-override-date? #t boolean? "Whether extending sets the committer date to now; #f keeps HEAD's.")

(define-option reword-override-date? #t boolean? "Whether rewording sets the committer date to now; #f keeps HEAD's.")

(define-option major-mode modes:fundamental symbol? "The major mode of message buffers.")

(define-option style-checks (list (style-check non-empty-second-line))
  (lambda (v) (and (list? v) (for-all (%one-of (%style-checks)) v)))
  "The checks made on C-c C-c, values of git-commit:style-check.")

(define-option summary-max-length 68 (lambda (v) (and (fixnum? v) (fx> v 0)))
  "The summary length past which characters show in git-commit.overlong-summary.")

(define-saved messages '() %strings?)

(define %history-size 32)

(define-table keymap "Keys in a commit message buffer.")

(define-hook mode-hook "Called in each message buffer as git-commit:mode turns on.")

(modes:define-minor-mode mode
  "Whether the buffer holds a message git asked for: its history keys, trailers and faces."
  (keymap keymap))

(buffers:define-layer %faces)

(transient:define-menu menu "Making commits."
  (title "Commit")
  (arguments arguments))

(define (%author-reader question)
  (let* ([repository (git-mode:current-repository)]
         [authors (let loop ([lines (let ([out (utf8->string (git:query repository '("log" "--format=%aN <%aE>")))])
                                      (let split ([i 0] [start 0] [acc '()])
                                        (cond
                                          [(fx= i (string-length out)) (reverse acc)]
                                          [(char=? (string-ref out i) #\newline) (split (fx+ i 1) (fx+ i 1) (cons (substring out start i) acc))]
                                          [else (split (fx+ i 1) start acc)])))]
                             [acc '()])
                    (cond
                      [(null? lines) (reverse acc)]
                      [(member (car lines) acc) (loop (cdr lines) acc)]
                      [else (loop (cdr lines) (cons (car lines) acc))]))])
    (ask:line-with-candidates "Author: " authors)))

(define (date-for option)
  (unless (procedure? option)
    (assertion-violation 'git-commit:date-for "not an option" option))
  (if (eq? (and (option) #t) (not (commands:prefix-argument))) 'now 'keep))

(define (%staged? repository) (pair? (git:diff repository '("--cached"))))

(define (%unstaged? repository) (pair? (git:diff repository '())))

(define (%lines s)
  (let loop ([i 0] [start 0] [acc '()])
    (cond
      [(fx= i (string-length s)) (reverse (if (fx< start i) (cons (substring s start i) acc) acc))]
      [(char=? (string-ref s i) #\newline) (loop (fx+ i 1) (fx+ i 1) (cons (substring s start i) acc))]
      [else (loop (fx+ i 1) start acc)])))

(define (%head-committer-date repository)
  (let ([out (utf8->string (git:query repository '("log" "-1" "--format=%cD")))])
    (substring out 0 (fxmax 0 (fx- (string-length out) 1)))))

(define (%check-published! repository)
  (let* ([containing (guard (c [(git:failed-condition? c) '()])
                       (map (lambda (l) (let loop ([l l]) (if (and (fx> (string-length l) 0) (char=? (string-ref l 0) #\space)) (loop (substring l 1 (string-length l))) l)))
                            (%lines (utf8->string (git:query repository '("branch" "-r" "--contains" "HEAD"))))))]
         [published (filter (lambda (b) (member b containing)) (published-branches))])
    (unless (null? published)
      (unless (ask:y-or-n?
                (string-append
                  (if (= (length published) 1)
                      (string-append "This commit has already been published to " (car published) ".")
                      (format "This commit has already been published to ~a public branches." (length published)))
                  "\nDo you really want to modify it? "))
        (error 'git-commit "Abort")))))

(define (%commit! repository arguments environment)
  (let ([editing (with-editor:output-wrapper)])
    (git-mode:start repository (cons "commit" arguments)
      (lambda (command)
        (cond
          [(with-editor:canceled? editing) (git:set-command-canceled! command)]
          [(and (not (eqv? (git:command-exit command) 0))
                (let ([out (git:command-output command)])
                  (exists (lambda (l) (string=? l "Aborting commit due to empty commit message.")) (%lines out))))
           (git:set-command-canceled! command)
           (ask:message "Commit canceled")]))
      (append (with-editor:environment "GIT_EDITOR") environment)
      editing)
    (void)))

(define (%check-strings who arguments)
  (unless (%strings? arguments)
    (assertion-violation who "not a list of strings" arguments)))

(commands:define-command (create [arguments (transient:arguments menu)])
  "Runs git commit with ARGUMENTS, opening the message buffer; with nothing staged, offers to commit everything."
  (%check-strings 'git-commit:create arguments)
  (let ([repository (git-mode:current-repository)])
    (let ([arguments
           (if (or (member "--allow-empty" arguments) (member "--all" arguments) (%staged? repository))
               arguments
               (begin
                 (unless (%unstaged? repository)
                   (error 'git-commit:create "Nothing staged (or unstaged)"))
                 (case (ask-to-stage)
                   [(stage) (append arguments '("--all"))]
                   [(refuse) (error 'git-commit:create "Nothing staged")]
                   [else (and (ask:y-or-n? "Nothing staged.  Commit all uncommitted changes? ")
                              (append arguments '("--all")))])))])
      (when arguments
        (%commit! repository arguments '())))))

(commands:define-command (amend [arguments (transient:arguments menu)])
  "Runs git commit --amend; the message buffer opens with HEAD's message."
  (%check-strings 'git-commit:amend arguments)
  (let ([repository (git-mode:current-repository)])
    (%check-published! repository)
    (%commit! repository (cons "--amend" arguments) '())))

(define (%date-environment repository date)
  (unless (memq date '(now keep))
    (assertion-violation 'git-commit "not a git-commit:committer-date" date))
  (if (eq? date 'keep)
      (guard (c [(git:failed-condition? c) '()])
        (list (cons "GIT_COMMITTER_DATE" (%head-committer-date repository))))
      '()))

(commands:define-command (extend [arguments (transient:arguments menu)] [date (date-for extend-override-date?)])
  "Runs git commit --amend --no-edit, adding the staged changes to HEAD; with DATE keep, HEAD's committer date stays."
  (%check-strings 'git-commit:extend arguments)
  (let ([repository (git-mode:current-repository)])
    (%check-published! repository)
    (git-mode:start repository (append '("commit" "--amend" "--no-edit") arguments) (lambda (command) (void)) (%date-environment repository date))
    (void)))

(commands:define-command (reword [arguments (transient:arguments menu)] [date (date-for reword-override-date?)])
  "Runs git commit --amend --only --allow-empty, changing only HEAD's message, with the committer date DATE says."
  (%check-strings 'git-commit:reword arguments)
  (let ([repository (git-mode:current-repository)])
    (%check-published! repository)
    (%commit! repository (append '("--amend" "--only" "--allow-empty") arguments) (%date-environment repository date))))

(commands:define-command (show-menu)
  "Shows the commit menu."
  (git-mode:current-repository)
  (transient:show! menu))

(define %message-names '("COMMIT_EDITMSG" "MERGE_MSG" "TAG_EDITMSG" "SQUASH_MSG" "EDIT_DESCRIPTION"))

(define (%message-file? path)
  (and (string? path)
       (let* ([slash (let loop ([i (fx- (string-length path) 1)]) (cond [(fx< i 0) #f] [(char=? (string-ref path i) #\/) i] [else (loop (fx- i 1))]))]
              [name (if slash (substring path (fx+ slash 1) (string-length path)) path)]
              [folder (if slash (substring path 0 slash) "")])
         (and (member name %message-names)
              (let ([n (string-length folder)])
                (or (and (fx>= n 4) (string=? (substring folder (fx- n 4) n) ".git"))
                    (let loop ([i 0])
                      (and (fx<= (fx+ i 6) n)
                           (or (string=? (substring folder i (fx+ i 6)) "/.git/") (loop (fx+ i 1)))))))
              #t))))

(define (%choose-mode buffer name)
  (and (%message-file? (or (files:path buffer) name)) (major-mode)))

(define (%message-end doc)
  (let ([n (document:length doc)])
    (let loop ([p 0] [line-start? #t])
      (cond
        [(fx>= p n) n]
        [(and line-start? (eqv? (document:token doc p) #\#)) p]
        [else (let ([t (document:token doc p)]) (loop (fx+ p 1) (cond [(eqv? t #\newline) #t] [(char? t) #f] [else line-start?])))]))))

(define (%message-text b)
  (let* ([doc (buffers:document b)] [text (document:text doc 0 (%message-end doc))])
    (let trim ([s text])
      (cond
        [(and (fx> (string-length s) 0) (char-whitespace? (string-ref s (fx- (string-length s) 1))))
         (trim (substring s 0 (fx- (string-length s) 1)))]
        [else s]))))

(define (%save-message! b)
  (let ([text (%message-text b)])
    (unless (or (string=? text "") (and (pair? (messages)) (string=? (car (messages)) text)))
      (let ([all (cons text (messages))])
        (set-saved! messages (if (> (length all) %history-size) (list-head all %history-size) all))))))

(commands:define-command (save-message)
  "Puts the message on git-commit:messages unless it is empty or already the newest."
  (%save-message! (buffers:current)))

(define %history-index (make-weak-eq-hashtable))

(define (%replace-message! b text)
  (let ([end (%message-end (buffers:document b))])
    (buffers:replace! b 1 (fxmax 1 end) (string-append text "\n"))
    (views:set-point! (views:current) 1)))

(define (%step-history! who b n)
  (let* ([index (eq-hashtable-ref %history-index b -1)]
         [_ (when (fx= index -1) (%save-message! b))]
         [index (if (fx= index -1) (if (and (pair? (messages)) (string=? (car (messages)) (%message-text b))) 0 -1) index)]
         [target (+ index n)])
    (cond
      [(null? (messages)) (error who "No previous message")]
      [(>= target (length (messages))) (error who "No previous message")]
      [(< target 0) (error who "No next message")]
      [else
       (eq-hashtable-set! %history-index b target)
       (%replace-message! b (list-ref (messages) target))])))

(commands:define-command (previous-message [n (commands:prefix-number)])
  "Replaces the message with the Nth older one of git-commit:messages, after saving the one there."
  (%step-history! 'git-commit:previous-message (buffers:current) n))

(commands:define-command (next-message [n (commands:prefix-number)])
  "Replaces the message with the Nth newer one of git-commit:messages."
  (%step-history! 'git-commit:next-message (buffers:current) (- n)))

(define %trailer-keys
  '("Signed-off-by" "Acked-by" "Modified-by" "Cc" "Reported-by" "Reviewed-by" "Tested-by" "Suggested-by"))

(define (%user-identity)
  (let-values ([(name email) (git:user (git-mode:current-repository))])
    (string-append (or name "") " <" (or email "") ">")))

(define (%insert-trailer! b key value)
  (let* ([doc (buffers:document b)] [end (%message-end doc)] [text (document:text doc 0 end)]
         [lines (%lines text)]
         [content (let loop ([ls (reverse lines)]) (if (and (pair? ls) (string=? (car ls) "")) (loop (cdr ls)) (reverse ls)))]
         [trailers? (and (pair? content)
                         (let ([last (car (reverse content))])
                           (exists (lambda (k) (let ([p (string-append k ":")])
                                                 (and (fx>= (string-length last) (string-length p))
                                                      (string=? (substring last 0 (string-length p)) p))))
                                   (cons key %trailer-keys))))]
         [kept (apply string-append (map (lambda (l) (string-append l "\n")) content))])
    (buffers:replace! b 1 (fxmax 1 end)
      (string-append kept (if (or trailers? (null? content)) "" "\n") key ": " value "\n"))))

(commands:define-command (insert-trailer [key (ask:line-with-candidates "Trailer: " %trailer-keys)]
                                         [value (ask:line "Value: " (%user-identity))])
  "Inserts the trailer KEY: VALUE at the end of the message."
  (unless (and (string? key) (string? value))
    (assertion-violation 'git-commit:insert-trailer "not a string" (list key value)))
  (%insert-trailer! (buffers:current) key (if (string=? value "") (%user-identity) value)))

(define (%trailer-command key)
  (lambda ()
    (%insert-trailer! (buffers:current) key
      (if (commands:prefix-argument)
          (let* ([name (ask:line "Name: ")] [email (ask:line "Email: ")])
            (string-append name " <" email ">"))
          (%user-identity)))))

(commands:define-command (sign-off) "Inserts a Signed-off-by trailer with the user's name and email; with C-u, reads them." ((%trailer-command "Signed-off-by")))
(commands:define-command (ack) "Inserts an Acked-by trailer." ((%trailer-command "Acked-by")))
(commands:define-command (modified-by) "Inserts a Modified-by trailer." ((%trailer-command "Modified-by")))
(commands:define-command (cc) "Inserts a Cc trailer." ((%trailer-command "Cc")))
(commands:define-command (reported-by) "Inserts a Reported-by trailer." ((%trailer-command "Reported-by")))
(commands:define-command (reviewed-by) "Inserts a Reviewed-by trailer." ((%trailer-command "Reviewed-by")))
(commands:define-command (tested-by) "Inserts a Tested-by trailer." ((%trailer-command "Tested-by")))
(commands:define-command (suggested-by) "Inserts a Suggested-by trailer." ((%trailer-command "Suggested-by")))

(define (check-style b)
  (unless (buffers:buffer? b)
    (assertion-violation 'git-commit:check-style "not a buffer" b))
  (let ([lines (%lines (%message-text b))])
    (and (or (not (memq 'non-empty-second-line (style-checks)))
             (not (and (pair? lines) (pair? (cdr lines)) (not (string=? (cadr lines) ""))))
             (ask:y-or-n? "Second line is not empty.  Commit anyway? "))
         (or (not (memq 'overlong-summary-line (style-checks)))
             (not (and (pair? lines) (> (string-length (car lines)) (summary-max-length))))
             (ask:y-or-n? "Summary line is too long.  Commit anyway? ")))))

(define %scissors-line "# ------------------------ >8 ------------------------")

;; Faces are spans of the buffer's own layer, so they follow each edit,
;; and an edit above the scissors line repaints only the message: the
;; diff --verbose writes below it can be large.
(define (%paint! b to)
  (let* ([doc (buffers:document b)] [n (document:length doc)] [end (%message-end doc)] [spans '()])
    (define (span! a z face) (when (fx< a z) (set! spans (cons (list a z (list (cons 'face face))) spans))))
    (let loop ([p 0] [line 1] [scissors? #f])
      (when (fx< p to)
        (let* ([e (let find ([q p]) (if (or (fx>= q n) (eqv? (document:token doc q) #\newline)) q (find (fx+ q 1))))]
               [text (document:text doc p e)])
          (cond
            [(and (fx> (string-length text) 0) (char=? (string-ref text 0) #\#))
             (span! p e faces:comment)
             (loop (fx+ e 1) (fx+ line 1) (or scissors? (string=? text %scissors-line)))]
            [scissors?
             (cond
               [(and (fx> (string-length text) 0) (char=? (string-ref text 0) #\+)) (span! p e faces:diff.plus)]
               [(and (fx> (string-length text) 0) (char=? (string-ref text 0) #\-)) (span! p e faces:diff.minus)])
             (loop (fx+ e 1) (fx+ line 1) #t)]
            [(fx>= p end) (loop (fx+ e 1) (fx+ line 1) scissors?)]
            [(fx= line 1)
             (let ([cut (fxmin e (fx+ p (summary-max-length)))])
               (span! p cut "git-commit.summary")
               (span! cut e "git-commit.overlong-summary"))
             (loop (fx+ e 1) (fx+ line 1) scissors?)]
            [(and (fx= line 2) (fx> (string-length text) 0))
             (span! p e "git-commit.nonempty-second-line")
             (loop (fx+ e 1) (fx+ line 1) scissors?)]
            [else
             (let ([colon (let find ([i 0]) (cond [(fx= i (string-length text)) #f] [(char=? (string-ref text i) #\:) i] [else (find (fx+ i 1))]))])
               (when (and colon (member (substring text 0 colon) %trailer-keys))
                 (span! p (fx+ p colon 1) "git-commit.trailer-key")))
             (loop (fx+ e 1) (fx+ line 1) scissors?)]))))
    (buffers:set-spans! (buffers:layer b %faces) 0 to (reverse spans))))

(define (%mode-on? b) (and (buffers:live? b) (buffers:with-buffer b (mode))))

(define (%after-edit b edit)
  (when (%mode-on? b)
    (let* ([doc (buffers:document b)] [at (%scissors-start doc)]
           [diff (and at (fx- at (string-length %scissors-line)))]
           [edit-end (fx+ (buffers:edit-start edit) (buffers:piece-length (buffers:edit-inserted edit)))])
      (%paint! b (if (and diff (fx<= edit-end diff)) diff (document:length doc))))))

(define (%scissors-start doc)
  (let ([n (document:length doc)] [line %scissors-line])
    (let loop ([p 0])
      (cond
        [(fx> (fx+ p (string-length line)) n) #f]
        [(and (or (fx= p 0) (eqv? (document:token doc (fx- p 1)) #\newline))
              (string=? (document:text doc p (fx+ p (string-length line))) line))
         (fx+ p (string-length line))]
        [else (loop (fx+ p 1))]))))

;; As git-commit-collapse-diff, the diff --verbose writes below the
;; scissors line is folded in each view that shows the buffer.
(define (%fold-diff view)
  (let ([b (views:buffer view)])
    (when (and b (%mode-on? b))
      (let* ([doc (buffers:document b)] [at (%scissors-start doc)] [end (fx- (document:length doc) 1)])
        (when (and at (fx< at end) (null? (views:folds-at view at)))
          (views:fold! view at end))))))

(define (%after-switch view left point) (%fold-diff view))

(define %message-buffers (make-weak-eq-hashtable))

(define (%setup)
  (let ([b (buffers:current)])
    (eq-hashtable-set! %message-buffers b #t)
    (add-local-hook! with-editor:finish-checks check-style)
    (%paint! b (document:length (buffers:document b)))
    (for-each %fold-diff (views:showing b))
    (ask:message "Type C-c C-c to finish, C-c C-k to cancel, and M-p and M-n to recover older messages")))

(define (%after-visit b)
  (when (%message-file? (files:path b))
    (buffers:with-buffer b
      (set-option-local! mode #t)
      (mode-hook))))

(define (%killed b)
  (when (eq-hashtable-ref %message-buffers b #f)
    (eq-hashtable-delete! %message-buffers b)
    (%save-message! b)))

(define (%canceled path)
  (when (%message-file? path)
    (ask:message "Commit canceled. Message saved")))

(keys:bind! keymap "M-p" previous-message)
(keys:bind! keymap "M-n" next-message)
(keys:bind! keymap "C-c M-s" save-message)
(keys:bind! keymap "C-c C-i" insert-trailer)
(keys:bind! keymap "C-c C-s" sign-off)
(keys:bind! keymap "C-c C-a" ack)
(keys:bind! keymap "C-c C-m" modified-by)
(keys:bind! keymap "C-c C-o" cc)
(keys:bind! keymap "C-c C-p" reported-by)
(keys:bind! keymap "C-c C-r" reviewed-by)
(keys:bind! keymap "C-c C-t" tested-by)
(keys:bind! keymap "C-c M-i" suggested-by)
(keys:bind! keymap "C-c C-d" keys:undefined)
(keys:bind! keymap "C-c C-w" keys:undefined)
(transient:add! menu "Arguments"
  (transient:switch "- a" "Stage all modified and deleted files" "--all")
  (transient:switch "- e" "Allow empty commit" "--allow-empty")
  (transient:switch "- v" "Show diff of changes to be committed" "--verbose")
  (transient:switch "- n" "Disable hooks" "--no-verify")
  (transient:switch "- R" "Claim authorship and reset author date" "--reset-author")
  (transient:valued-switch "- A" "Override the author" "--author=" %author-reader))
(transient:add! menu "Create"
  (transient:command "c" "Commit" create))
(transient:add! menu "Edit HEAD"
  (transient:command "e" "Extend" extend)
  (transient:command "a" "Amend" amend)
  (transient:command "w" "Reword" reword))
(transient:add! git-mode:dispatch-menu #f
  (transient:command "c" "Commit" show-menu))
(keys:bind! git-mode:keymap "c" show-menu)
(add-hook! mode-hook %setup)
(add-hook! auto-mode:choosers %choose-mode -20)
(add-hook! files:after-visit %after-visit)
(add-hook! buffers:after-edit %after-edit)
(add-hook! buffers:killed %killed)
(add-hook! with-editor:canceled %canceled)
(add-hook! layout:after-switch-to-buffer %after-switch)
(table-set! web:stylesheets 'git-commit "git-commit/git-commit.css")

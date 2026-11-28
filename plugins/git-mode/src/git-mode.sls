#!tuna
(import (git) (diff) (diff-sections) (processes) (ui) (buffers) (document) (views) (layout) (modes) (keys) (commands)
        (transient) (files) (browse-url) (web) (ask) (status-line) (hooks) (options) (tables))

(define %self (current-owner))

(define-enumeration saving (ask save never) %savings)

(define-enumeration confirmation
  (discard trash delete resurrect rename reverse stage-all-changes unstage-all-changes kill-process set-and-push)
  %confirmations)

(define (%one-of names) (lambda (v) (and (memq v (enum-set->list (enum-set-universe names))) #t)))

(options:define-option repository #f (lambda (v) (or (not v) (git:repository? v)))
  "The buffer's repository, set locally in each Git buffer.")

(options:define-option save-repository-buffers (saving ask) (%one-of (%savings))
  "Before a refresh, whether to save modified buffers visiting files of the repository: ask asks for each, save saves without asking, never leaves them.")

(options:define-option revert-buffers? #t boolean?
  "Whether, after a command, unmodified buffers whose files changed on disk are reverted.")

(options:define-option no-confirm (list (confirmation set-and-push))
  (lambda (v) (and (list? v) (for-all (%one-of (%confirmations)) v)))
  "Actions done without asking, values of git-mode:confirmation.")

(options:define-option %refresher #f (lambda (v) (or (not v) (procedure? v)))
  "The procedure of a Git buffer that rebuilds it, set locally.")

(options:define-option side (lambda (section view) #f) procedure?
  "A procedure of a section and a view that returns what the section's changes are: unstaged, staged, untracked, committed or #f for a section that holds no change; each Git buffer sets it locally.")

(options:define-option %prefix "git" string? "The prefix of a Git buffer's name, set locally.")

(options:define-option locked? #f boolean?
  "Whether a Git buffer keeps what it shows, so a command that would show something else in a buffer of its mode makes another; set locally.")

(options:define-option files '() (lambda (v) (and (list? v) (for-all string? v)))
  "The files a Git buffer is limited to, '() for none; set locally.")

(hooks:define-hook repository-visitors
  "Called with a repository when git-mode:visit-file visits a row that is the root of another repository, such as a submodule's; the first entry, by depth, that returns a buffer has shown it. With none, the folder is visited as files:visit visits it.")

(hooks:define-hook before-refresh "Called with the repository before each refresh.")

(hooks:define-hook after-refresh "Called with the repository after each refresh.")

(tables:define-table keymap "Keys in every Git buffer.")

(tables:define-table status-modes
  "Modes, as keys, of a repository's status buffers, which git-mode:refresh refreshes beside the current Git buffer.")

(hooks:define-hook mode-hook "Called in each buffer that turns on git-mode:mode.")

(modes:define-major-mode mode
  (parent ui:section-mode)
  (lighter "Git")
  (keymap keymap)
  (hook mode-hook)
  (plugin-only #t))

(tables:define-table commands-keymap "Keys in the command log.")

(hooks:define-hook commands-mode-hook "Called in each command log as its mode is set.")

(modes:define-major-mode commands-mode
  (parent mode)
  (lighter "Git commands")
  (keymap commands-keymap)
  (hook commands-mode-hook)
  (plugin-only #t))

(buffers:define-layer %read-only (read-only) (sticky both))

(buffers:define-kind %contents (content nodes))

(define (%root repository) (git:repository-root repository))

(define (%repository-of b)
  (and (buffers:live? b) (buffers:with-buffer b (repository))))

(define (%git-buffer? b)
  (and (buffers:live? b) (modes:derived? (modes:major-mode b) mode) (%repository-of b) #t))

(define (%buffers-of repository)
  (filter (lambda (b) (and (%git-buffer? b) (string=? (%root (%repository-of b)) (%root repository))))
          (buffers:all)))

(define (repository-buffers repository)
  (unless (git:repository? repository)
    (assertion-violation 'git-mode:repository-buffers "not a repository" repository))
  (%buffers-of repository))

(define (%check-task who)
  (unless (current-task)
    (assertion-violation who "not in a task")))

;; A Git buffer's text is the repository's state, so only a refresh
;; writes it.
(define (protect! buffer)
  (unless (buffers:buffer? buffer)
    (assertion-violation 'git-mode:protect! "not a buffer" buffer))
  (let ([n (document:length (buffers:document buffer))])
    (buffers:set-spans! (buffers:layer buffer %read-only) 0 n (list (list 0 n '())))))

(define (buffer repo prefix major-mode rebuild)
  (unless (git:repository? repo)
    (assertion-violation 'git-mode:buffer "not a repository" repo))
  (unless (string? prefix)
    (assertion-violation 'git-mode:buffer "not a string" prefix))
  (unless (and (symbol? major-mode) (modes:derived? major-mode mode))
    (assertion-violation 'git-mode:buffer "not a mode derived from git-mode:mode" major-mode))
  (unless (procedure? rebuild)
    (assertion-violation 'git-mode:buffer "not a procedure" rebuild))
  (or (unlocked-buffer repo major-mode)
      (let* ([name (%name repo prefix #f #f)]
             [b (buffers:make name (%contents '()))])
        (buffers:set-silent! b #t)
        (modes:set-major-mode major-mode b)
        ;; As git-mode, so the buffer stays a Git buffer whichever plugin
        ;; asked for it unloads.
        (buffers:with-buffer b
          (call-as-owner %self
            (lambda ()
              (options:set-local! repository repo %refresher rebuild %prefix prefix buffers:revert-function refresh
                                 files:offer-save? #f))))
        b)))

(define (%name repository prefix value self)
  (let loop ([n 1])
    (let* ([name (string-append "*" prefix ": " (git:repository-name repository)
                                (if (= n 1) "" (string-append "<" (number->string n) ">")) "*"
                                (if value (string-append "<" value ">") ""))]
           [holder (buffers:find name)])
      (if (and holder (not (eq? holder self)))
          (loop (+ n 1))
          name))))

(define buffer-name
  (case-lambda
    [(buffer) (buffer-name buffer #f)]
    [(buffer value)
     (unless (%git-buffer? buffer)
       (assertion-violation 'git-mode:buffer-name "not a Git buffer" buffer))
     (unless (or (not value) (string? value))
       (assertion-violation 'git-mode:buffer-name "not a string or #f" value))
     (buffers:with-buffer buffer (%name (repository) (%prefix) value buffer))]))

(define (unlocked-buffer repository major-mode)
  (unless (git:repository? repository)
    (assertion-violation 'git-mode:unlocked-buffer "not a repository" repository))
  (find (lambda (b) (and (eq? (modes:major-mode b) major-mode) (not (buffers:with-buffer b (locked?))))) (%buffers-of repository)))

;; A file git asks to edit, such as COMMIT_EDITMSG, is in the git folder,
;; where git finds no work tree; its repository is the folder holding it.
(define (find-current-repository)
  (or (let ([b (buffers:current)]) (and b (%repository-of b)))
      (let ([folder (files:directory)])
        (and folder
             (or (git:find-repository folder)
                 (let ([at (%git-folder-at folder)])
                   (and at (git:find-repository (substring folder 0 at)))))))))

(define (current-repository)
  (or (find-current-repository)
      (error 'git-mode:current-repository "Not inside a Git repository")))

(define (%git-folder-at folder)
  (let loop ([i 0])
    (cond
      [(fx> (fx+ i 6) (string-length folder)) #f]
      [(string=? (substring folder i (fx+ i 6)) "/.git/") (fx+ i 1)]
      [else (loop (fx+ i 1))])))

;; Each repository's Git buffers are stale from the moment one of its
;; commands is queued until the refresh after the last queued one ends;
;; a stale repository holds the tasks waiting for it to be current.
(define %stale (make-hashtable string-hash string=?))

(define (%stale? repository) (hashtable-contains? %stale (%root repository)))

(define (%mark-stale! repository)
  (unless (%stale? repository)
    (hashtable-set! %stale (%root repository) '())))

(define (%mark-current! repository)
  (let ([waiters (hashtable-ref %stale (%root repository) '())])
    (hashtable-delete! %stale (%root repository))
    (for-each (lambda (w) ((cdr w) void)) (list-sort (lambda (a b) (< (car a) (car b))) waiters))))

;; A task waits in the order it first waited: a command that ran git and
;; waits again to put point back goes before a later key's command, which
;; must act on the buffer that command left.
(define %tickets (make-weak-eq-hashtable))

(define %last-ticket 0)

(define (%ticket task)
  (or (eq-hashtable-ref %tickets task #f)
      (begin
        (set! %last-ticket (+ %last-ticket 1))
        (eq-hashtable-set! %tickets task %last-ticket)
        %last-ticket)))

(define (wait-until-current b)
  (unless (buffers:buffer? b)
    (assertion-violation 'git-mode:wait-until-current "not a buffer" b))
  (let ([r (%repository-of b)] [ticket (and (current-task) (%ticket (current-task)))])
    ;; A task resumed before this one may have queued a command, so the
    ;; repository is checked again after each wait.
    (let loop ()
      (when (and r (%stale? r))
        (%check-task 'git-mode:wait-until-current)
        (suspend
          (lambda (resume)
            (hashtable-update! %stale (%root r) (lambda (ws) (cons (cons ticket resume) ws)) '())))
        (loop)))))

(define-record-type %refreshing
  (sealed #t)
  (fields (mutable again?) (mutable waiters)))

(define %refreshes (make-weak-eq-hashtable))

(define (%rebuild! b)
  (let ([refresh (buffers:with-buffer b (%refresher))])
    (when refresh
      (buffers:with-silent-edits b (refresh b))
      (protect! b))))

(define (%refresh-buffer! b)
  (let ([running (eq-hashtable-ref %refreshes b #f)])
    (if running
        (begin
          (%refreshing-again?-set! running #t)
          (suspend (lambda (resume) (%refreshing-waiters-set! running (cons resume (%refreshing-waiters running))))))
        (let ([state (make-%refreshing #f '())])
          (define (done! outcome)
            (eq-hashtable-delete! %refreshes b)
            (for-each (lambda (resume) (resume outcome)) (%refreshing-waiters state)))
          (eq-hashtable-set! %refreshes b state)
          (guard (c [#t (done! (lambda () (raise c))) (raise c)])
            (let loop ()
              (%refreshing-again?-set! state #f)
              (when (buffers:live? b) (%rebuild! b))
              (when (%refreshing-again? state) (loop))))
          (done! void)))))

;; A task's pause leaves its continuation, so dynamic-wind would run the
;; cleanup at every pause; this runs it once, when the body returns or
;; raises.
(define (%finally body cleanup)
  (guard (c [#t (cleanup) (raise c)])
    (call-with-values body
      (lambda results (cleanup) (apply values results)))))

(define (refresh-buffer buffer)
  (unless (%git-buffer? buffer)
    (assertion-violation 'git-mode:refresh-buffer "not a Git buffer" buffer))
  (%check-task 'git-mode:refresh-buffer)
  (%refresh-buffer! buffer))

(define (%in-repository? repository)
  (let ([root (%root repository)])
    (lambda (b)
      (let ([path (files:path b)])
        (and path (fx>= (string-length path) (string-length root))
             (string=? (substring path 0 (string-length root)) root))))))

(define (%save-repository-buffers! repository)
  (case (save-repository-buffers)
    [(ask) (files:save-some-buffers (%in-repository? repository))]
    [(save) (for-each (lambda (b) (when (and (buffers:modified? b) (files:path b)) (files:save-buffer b)))
                      (filter (%in-repository? repository) (files:buffers)))]
    [else (void)]))

(define (%refresh-buffers! repository buffers)
  (before-refresh repository)
  (%save-repository-buffers! repository)
  ;; A rebuild can fail for its own buffer alone, as a diff whose range
  ;; names a deleted branch does.
  (for-each (lambda (b) (guard (c [(not (cancelled? c)) (report c)]) (%refresh-buffer! b))) buffers)
  (after-refresh repository)
  (when (revert-buffers?)
    (files:revert-changed-buffers (%in-repository? repository)))
  (void))

(define (refresh-repository repository)
  (unless (git:repository? repository)
    (assertion-violation 'git-mode:refresh-repository "not a repository" repository))
  (%check-task 'git-mode:refresh-repository)
  (%refresh-buffers! repository (%buffers-of repository)))

(define (%status-buffers-of repository)
  (filter (lambda (b) (tables:ref status-modes (modes:major-mode b) #f)) (%buffers-of repository)))

(commands:define-command (refresh)
  "Refreshes the current Git buffer and its repository's status buffer."
  (let* ([b (buffers:current)] [r (and b (%repository-of b))])
    (unless r
      (error 'git-mode:refresh "Not a Git buffer"))
    (%refresh-buffers! r (cons b (remq b (%status-buffers-of r))))))

(commands:define-command (refresh-all)
  "Refreshes every Git buffer of the repository."
  (refresh-repository (current-repository)))

(define (confirm action question)
  (unless (memq action (enum-set->list (enum-set-universe (%confirmations))))
    (assertion-violation 'git-mode:confirm "not a git-mode:confirmation" action))
  (unless (string? question)
    (assertion-violation 'git-mode:confirm "not a string" question))
  (unless (or (memq action (no-confirm)) (ask:y-or-n? question))
    (error 'git-mode:confirm "Abort")))

;; A background command says when it ends, as Magit's asynchronous ones
;; do; a command a caller waits for tells the caller.
(define %background (make-weak-eq-hashtable))

(define start
  (case-lambda
    [(repository arguments on-end) (start repository arguments on-end '() #f)]
    [(repository arguments on-end environment) (start repository arguments on-end environment #f)]
    [(repository arguments on-end environment wrapper)
     (let ([command (git:start repository arguments on-end
                               (and (pair? environment) (processes:options [environment environment])) wrapper)])
       (eq-hashtable-set! %background command #t)
       command)]))

(define %last-errors (make-hashtable string-hash string=?))

(define (last-error repository)
  (unless (git:repository? repository)
    (assertion-violation 'git-mode:last-error "not a repository" repository))
  (hashtable-ref %last-errors (%root repository) #f))

(define (%summary command)
  (let ([lines (let loop ([s (git:command-output command)] [start 0] [i 0] [acc '()])
                 (cond
                   [(fx= i (string-length s)) (reverse (if (fx< start i) (cons (substring s start i) acc) acc))]
                   [(char=? (string-ref s i) #\newline) (loop s (fx+ i 1) (fx+ i 1) (cons (substring s start i) acc))]
                   [else (loop s start (fx+ i 1) acc)]))])
    (define (trimmed l)
      (let loop ([l l])
        (if (and (fx> (string-length l) 0) (char-whitespace? (string-ref l 0))) (loop (substring l 1 (string-length l))) l)))
    (define (starts? l p) (and (fx>= (string-length l) (string-length p)) (string=? (substring l 0 (string-length p)) p)))
    (let* ([ls (filter (lambda (l) (not (string=? (trimmed l) ""))) lines)]
           [marked (filter (lambda (l) (or (starts? l "fatal:") (starts? l "error:"))) ls)])
      (cond
        [(pair? marked) (trimmed (let ([l (car (reverse marked))]) (substring l 6 (string-length l))))]
        [(pair? ls) (trimmed (car (reverse ls)))]
        [else "git failed"]))))

(define (%command-ended repository command)
  (let ([exit (git:command-exit command)])
    (cond
      [(git:command-canceled? command) (void)]
      [(eqv? exit 0)
       (hashtable-delete! %last-errors (%root repository))
       (when (eq-hashtable-ref %background command #f)
         (ask:message "Git finished"))]
      [else
       (let ([summary (%summary command)])
         (hashtable-set! %last-errors (%root repository) summary)
         (ask:message (string-append "Git error: " summary " [Type $ for details]")))])
    (eq-hashtable-delete! %background command)
    (unless (git:queued? repository)
      (call-as-owner %self
        (lambda ()
          (spawn-task
            (lambda (restore)
              (%finally
                (lambda () (refresh-repository repository))
                (lambda () (unless (git:queued? repository) (%mark-current! repository)))))))))))

;; A failed command a caller waited for has said Git error already, so
;; the caller stops without raising it again, as Magit's synchronous
;; calls return.
(define (call-with-failures-reported repository thunk)
  (unless (git:repository? repository)
    (assertion-violation 'git-mode:call-with-failures-reported "not a repository" repository))
  (unless (procedure? thunk)
    (assertion-violation 'git-mode:call-with-failures-reported "not a procedure" thunk))
  (guard (c [(and (git:failed-condition? c) (memq (git:failure-command c) (git:commands repository))) (void)])
    (thunk)))

(define %command-ids (make-weak-eq-hashtable))

(define %next-command-id 0)

(define (%command-id command)
  (or (eq-hashtable-ref %command-ids command #f)
      (begin
        (set! %next-command-id (+ %next-command-id 1))
        (eq-hashtable-set! %command-ids command %next-command-id)
        %next-command-id)))

(define (%heading command)
  (let ([exit (git:command-exit command)])
    (string-append
      (let ([s (if exit (number->string exit) "")])
        (string-append (make-string (fxmax 0 (fx- 3 (string-length s))) #\space) s))
      " git … "
      (let loop ([args (git:command-arguments command)] [acc ""])
        (if (null? args) acc (loop (cdr args) (string-append acc (if (string=? acc "") "" " ") (car args))))))))

(define (%log-sections repository)
         (map (lambda (command)
                (let* ([output (git:command-output command)] [exit (git:command-exit command)])
                  (apply ui:section `((type . command) (value . ,(%command-id command))
                                      (hidden . ,(and exit (eqv? exit 0))))
                         (%heading command)
                         (if (string=? output "") '() (list output)))))
              (git:commands repository)))

(define (%refresh-log! b)
  (buffers:reconcile! b (document:token (buffers:document b) 0) (%log-sections (%repository-of b))))

(define (%make-log! repository)
  (let ([b (buffer repository "git-commands" commands-mode %refresh-log!)])
    (buffers:with-silent-edits b (%refresh-log! b))
    (protect! b)
    b))

(define (%log-buffer repository)
  (find (lambda (b) (modes:derived? (modes:major-mode b) commands-mode)) (%buffers-of repository)))

(define (%command-updated repository command)
  (unless (git:command-exit command)
    (%mark-stale! repository))
  (let ([b (%log-buffer repository)])
    (when b
      (buffers:with-silent-edits b (%refresh-log! b))
      (protect! b))))

;; The log is shown from another view, which q goes back to, as
;; magit-mode-quit-window selects the window the log was shown from.
(define %shown-from (make-weak-eq-hashtable))

(commands:define-command (show-commands)
  "Shows the log of the repository's commands in another view and selects it."
  (let ([b (%make-log! (current-repository))] [from (layout:selected-view)])
    (layout:select! (layout:display-buffer b))
    (eq-hashtable-set! %shown-from b from)
    (let ([v (layout:selected-view)] [last (%last-section b)])
      (when (and last (eq? (views:buffer v) b))
        (views:set-point! v (ui:section-heading-start last))))))

(define (%last-section b)
  (let ([doc (buffers:document b)] [last #f])
    (unless (fx= (document:length doc) 0)
      (let ([root (document:token doc 0)])
        (document:for-each-child root (fx+ (document:node-start root) 1) (fx- (document:node-end root) 1)
          (lambda (child at) (when (and (document:node? child) (not (document:atom? child))) (set! last child))))))
    last))

(define (%command-at view)
  (let* ([b (views:buffer view)] [s (ui:section-at view)]
         [s (let up ([s s]) (and s (if (eq? (ui:section-type s) 'command) s (up (ui:section-parent s b)))))]
         [r (%repository-of b)])
    (and s r (find (lambda (c) (eqv? (eq-hashtable-ref %command-ids c #f) (ui:section-value s))) (git:commands r)))))

(commands:define-command (stop-command)
  "Asks to kill the process of the command at point, and stops it."
  (let ([command (%command-at (views:current))])
    (unless command
      (error 'git-mode:stop-command "No command at point"))
    (when (git:command-exit command)
      (error 'git-mode:stop-command "Process isn't running"))
    (confirm (confirmation kill-process) "Kill process?")
    (unless (git:command-exit command)
      (git:stop! command))))

(commands:define-command (quit [kill (commands:prefix-argument)])
  "Quits the view; with C-u also kills the buffer, with C-u C-u every Git buffer of the repository."
  (let* ([b (buffers:current)] [r (and b (%repository-of b))])
    (cond
      [(and (pair? kill) (>= (car kill) 16) r)
       (for-each buffers:kill! (%buffers-of r))]
      [kill (%quit-view! b) (when (buffers:live? b) (buffers:kill! b))]
      [else (%quit-view! b)])))

(define (%quit-view! b)
  (let ([from (eq-hashtable-ref %shown-from b #f)])
    (layout:quit-view)
    (when (and from (memq from (layout:views)))
      (eq-hashtable-delete! %shown-from b)
      (layout:select! from))))

(define (section-side section view)
  (unless (views:view? view)
    (assertion-violation 'git-mode:section-side "not a view" view))
  (buffers:with-buffer (views:buffer view) ((side) section view)))

(ui:define-section-kind file-section)

(ui:define-section-kind change-list-section)

(ui:define-section-kind commit-section)

(ui:define-section-kind range-list-section)

(commands:define-command (visit-thing)
  "RET where no section's keymap gives it a meaning: opens the URL at point, else says There is no thing at point that could be visited."
  (let* ([v (views:current)] [b (and v (views:buffer v))])
    (let-values ([(start end) (if b (browse-url:url-at b (views:point v)) (values #f #f))])
      (unless start
        (error 'git-mode:visit-thing "There is no thing at point that could be visited"))
      (browse-url:open (document:text (buffers:document b) start end) (web:current-client)))))

(commands:define-command (delete-thing)
  "k where no section's keymap gives it a meaning: says There is no thing at point that could be deleted."
  (error 'git-mode:delete-thing "There is no thing at point that could be deleted"))

(define (%git-view who)
  (let ([v (views:current)])
    (unless (and v (%git-buffer? (views:buffer v)))
      (error who "Not in a Git buffer"))
    v))

(define (%worktree-line repository from file line)
  (let ([later (find (lambda (f) (equal? (diff:file-path-bytes f) (diff:file-path-bytes file))) (git:diff repository from))])
    (if later
        (let loop ([hunks (diff:file-hunks later)] [shift 0])
          (cond
            [(null? hunks) (+ line shift)]
            [(< line (diff:hunk-old-start (car hunks))) (+ line shift)]
            [(< line (+ (diff:hunk-old-start (car hunks)) (diff:hunk-old-count (car hunks))))
             (%new-line (car hunks) line)]
            [else (loop (cdr hunks) (+ shift (- (diff:hunk-new-count (car hunks)) (diff:hunk-old-count (car hunks)))))]))
        line)))

;; A removed line's new line is the one that follows it.
(define (%new-line hunk line)
  (let ([lines (diff:hunk-lines hunk)])
    (let loop ([i 0] [next (diff:hunk-new-start hunk)])
      (if (fx= i (vector-length lines))
          next
          (let-values ([(old new) (diff:line-numbers hunk i)])
            (if (and old (= old line))
                (or new next)
                (loop (fx+ i 1) (if new (+ new 1) next))))))))

(define (%line-of hunk index)
  (let ([lines (diff:hunk-lines hunk)])
    (let loop ([i index])
      (if (fx>= i (vector-length lines))
          (let-values ([(old new) (diff:line-numbers hunk (fx- (vector-length lines) 1))])
            (if new (+ new 1) (diff:hunk-new-start hunk)))
          (let-values ([(old new) (diff:line-numbers hunk i)])
            (or new (loop (fx+ i 1))))))))

(define (%first-changed-line file)
  (let ([hunks (diff:file-hunks file)])
    (if (null? hunks)
        1
        (let* ([hunk (car hunks)] [lines (diff:hunk-lines hunk)])
          (let loop ([i 0])
            (cond
              [(fx= i (vector-length lines)) (diff:hunk-new-start hunk)]
              [(eq? (diff:line-kind (vector-ref lines i)) 'context) (loop (fx+ i 1))]
              [else (%line-of hunk i)]))))))

(define (%later-diff side file-section)
  (case side
    [(staged) '()]
    [(committed) (let ([revision (document:node-attribute file-section 'revision #f)]) (and revision (list revision)))]
    [else #f]))

(define (%visit-target view)
  (let* ([b (views:buffer view)] [repository (%repository-of b)] [root (git:repository-root repository)]
         [section (ui:section-at view)] [file-section (and section (diff-sections:file-section-of section b))]
         [side (and file-section (section-side file-section view))])
    (unless (and file-section side)
      (error 'git-mode:visit-file "There is no thing at point that could be visited"))
    (let ([path (string-append root (ui:section-value file-section))])
      (if (eq? side 'untracked)
          (values path 1 0)
          (let ([file (diff-sections:file file-section b)] [later (%later-diff side file-section)])
            (let-values ([(hunk-section index) (diff-sections:line-at view)])
              (let* ([line (if hunk-section
                               (%line-of (diff-sections:hunk hunk-section) index)
                               (%first-changed-line file))]
                     [line (if later (%worktree-line repository later file line) line)]
                     [column (if hunk-section
                                 (let* ([doc (buffers:document b)] [p (views:point view)]
                                        [width (bytevector-length (diff:line-prefix (vector-ref (diff:hunk-lines (diff-sections:hunk hunk-section)) index)))])
                                   (fxmax 0 (fx- (document:column doc p (buffers:with-buffer b (views:tab-width))) width)))
                                 0)])
                (values path line column))))))))

(define (%with-slash path)
  (if (and (fx> (string-length path) 0) (char=? (string-ref path (fx- (string-length path) 1)) #\/)) path (string-append path "/")))

(define (%visit! view other-view?)
  (let-values ([(path line column) (%visit-target view)])
    (let ([repository (and (file-directory? path) (git:find-repository path))])
      (unless (and repository (string=? (git:repository-root repository) (%with-slash path))
                   (exists (lambda (entry) (entry repository)) (hooks:entries repository-visitors)))
        (let ([b (files:visit path)])
          (if other-view?
              (layout:select! (layout:display-buffer b layout:display-in-other-view))
              (layout:switch-to-buffer b))
          (let* ([v (layout:selected-view)] [doc (buffers:document b)])
            (when (eq? (views:buffer v) b)
              (let ([last (document:line doc (document:length doc))])
                (views:set-point! v (document:column-position doc (fxmax 1 (fxmin line last)) column
                                      (buffers:with-buffer b (views:tab-width))))))))))))

(commands:define-command (visit-file [other-view (commands:prefix-argument)])
  "Visits the working tree's file of the section at point, at the line of point's diff line; with C-u, in another view."
  (%visit! (%git-view 'git-mode:visit-file) (and other-view #t)))

(commands:define-command (visit-worktree-file [other-view (commands:prefix-argument)])
  "Visits the working tree's file of the section at point, at the line of point's diff line, from a staged or committed diff too."
  (%visit! (%git-view 'git-mode:visit-worktree-file) (and other-view #t)))

(transient:define-menu dispatch-menu "Every Git menu and the commands that act on changes."
  (title "Transient and dwim commands"))

(commands:define-command (dispatch)
  "Shows the menu of every Git menu and the commands that act on changes."
  (current-repository)
  (transient:show! dispatch-menu))

(define (show-running view)
  (let* ([b (views:buffer view)] [r (and b (%git-buffer? b) (%repository-of b))] [c (and r (git:running r))])
    (and c
         (let loop ([args (git:command-arguments c)] [acc "git"])
           (if (null? args) (string-append acc "…") (loop (cdr args) (string-append acc " " (car args))))))))

(status-line:define-segment running (show show-running))

(keys:bind! keymap "G" refresh-all)
(keys:bind! keymap "q" quit)
(keys:bind! keymap "$" show-commands)
(keys:bind! keymap "?" dispatch)
(keys:bind! keymap "h" dispatch)
(keys:bind! keymap "C-c C-c" dispatch)
(keys:bind! keymap "RET" visit-thing)
(keys:bind! keymap "k" delete-thing)
(keys:remap! file-section-keys visit-thing visit-file)
(keys:bind! file-section-keys "C-j" visit-worktree-file)
(keys:bind! file-section-keys "C-RET" visit-worktree-file)
(for-each (lambda (key) (keys:bind! keymap key keys:undefined))
          '("b" "d" "D" "l" "L" "m" "M" "r" "t" "v" "V" "x" "X" "y" "z" "A" "a" "i" "K" "R" "w" "W" "Z" "!" "+"
            "C-w" "M-w" "j" "J"))
(keys:bind! commands-keymap "k" stop-command)
(keys:bind! commands-keymap "g" keys:undefined)
(keys:bind! keys:global "C-x M-g" dispatch)
(transient:add! dispatch-menu "Essential commands"
  (transient:command "g" "Refresh current buffer" refresh)
  (transient:command "q" "Bury current buffer" quit)
  (transient:command "TAB" "Toggle section at point" ui:section-toggle)
  (transient:command "RET" "Visit thing at point" visit-thing))
(transient:set-group-depth! dispatch-menu "Essential commands" 100)
(tables:set! status-line:segments running (status-line:left 60))
(hooks:add! git:command-updated %command-updated)
(hooks:add! git:command-ended %command-ended)

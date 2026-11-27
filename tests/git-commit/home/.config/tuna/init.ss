(import (hooks) (options) (tables) (timers) (saved))
(import (tuna) (testing) (web) (keys) (commands) (document) (buffers) (views))
;; ask's readers are the tests': each question is kept, and answered
;; from a queue the transcript fills.
(define said '())
(define asked '())
(define answers '())
(define (answer! . xs) (set! answers (append answers xs)))
(define (next-answer question)
  (set! asked (cons question asked))
  (if (null? answers)
      (error 'ask "no answer" question)
      (let ([a (car answers)]) (set! answers (cdr answers)) a)))
(use-plugin ask
  (config
    (options:set! ask:message-writer (lambda (text) (set! said (cons text said)))
                 ask:y-or-n-reader (lambda (q) (next-answer q))
                 ask:line-reader (case-lambda [(q) (next-answer q)] [(q d) (next-answer q)])
                 ask:line-with-candidates-reader (lambda (q candidates default) (next-answer q))
                 ask:file-name-reader (case-lambda [(q) (next-answer q)] [(q f) (next-answer q)]))))
(define (take-said!) (let ([s (reverse said)]) (set! said '()) s))
(define (take-asked!) (let ([s (reverse asked)]) (set! asked '()) s))
(use-plugin layout)
(use-plugin layout-split)
(use-plugin files)
(use-plugin editing)
(use-plugin undo)
(use-plugin isearch)
(use-plugin git-status)
(use-plugin git-commit)
(use-plugin git-remotes)
(import (git) (git-mode) (git-commit) (git-remotes) (with-editor) (transient) (ui) (diff) (diff-sections) (layout) (files) (processes)
        (haml))

(define (html v) (html->string (views:draw v client)))

(define (contains? s part)
  (let loop ([i 0])
    (and (<= (+ i (string-length part)) (string-length s))
         (or (string=? (substring s i (+ i (string-length part))) part) (loop (+ i 1))))))

(define client (web:add-client! 1))

(define (press! . keys)
  (for-each
    (lambda (key)
      (parameterize ([web:current-client client])
        (views:call-with-view (layout:selected-view) (lambda () (keys:press! client key)))))
    keys))

(define (view) (layout:selected-view))


(define home (getenv "HOME"))

(define (at path) (string-append home "/" path))

(putenv "GIT_AUTHOR_NAME" "Tuna")
(putenv "GIT_AUTHOR_EMAIL" "tuna@example.org")
(putenv "GIT_AUTHOR_DATE" "1767225600 +0000")
(putenv "GIT_COMMITTER_NAME" "Tuna")
(putenv "GIT_COMMITTER_EMAIL" "tuna@example.org")
(putenv "GIT_COMMITTER_DATE" "1767225600 +0000")

(define (sh command)
  (unless (zero? (system (string-append "{ set -e; cd \"$HOME\"; " command "; } < /dev/null > /dev/null 2>&1")))
    (error 'sh "failed" command)))

(define (write-file! path text)
  (sh (string-append "mkdir -p \"$(dirname '" path "')\""))
  (call-with-output-file (string-append home "/" path) (lambda (p) (display text p)) '(replace)))

(define (read-file path)
  (call-with-input-file (string-append home "/" path) get-string-all))

(define (git-out repo-name . args)
  (let-values ([(s o e) (processes:run "git" args #f (processes:options [directory (at repo-name)] [separate-stderr #t]))])
    (utf8->string o)))

;; A sample repository: one pushed commit and one not,
;; a.py with two unstaged hunks, b.txt staged then changed again,
;; gone.txt deleted and new.txt untracked.
(define (sample-repository! name)
  (sh (string-append "rm -rf " name " origin-" name ".git && git init -q --bare -b main origin-" name ".git"
                     " && git init -q -b main " name))
  (write-file! (string-append name "/a.py") "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n")
  (write-file! (string-append name "/b.txt") "alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\neta\ntheta\n")
  (write-file! (string-append name "/gone.txt") "bye\n")
  (sh (string-append "cd " name " && git add -A && git commit -qm 'First commit'"
                     " && git remote add origin ../origin-" name ".git && git push -q -u origin main"))
  (write-file! (string-append name "/a.py") "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\n")
  (sh (string-append "cd " name " && git commit -qam 'Second commit'"))
  (write-file! (string-append name "/a.py") "one\nTWO\nthree\nfour\nfive\nsix\nseven\neight\nNINE\nten\neleven\n")
  (write-file! (string-append name "/b.txt") "alpha\nBETA\ngamma\ndelta\nepsilon\nzeta\neta\ntheta\n")
  (sh (string-append "cd " name " && git add b.txt"))
  (write-file! (string-append name "/b.txt") "alpha\nBETA\ngamma\ndelta\nepsilon\nzeta\nETA\ntheta\n")
  (sh (string-append "cd " name " && rm gone.txt"))
  (write-file! (string-append name "/new.txt") "fresh\n"))

(define (status-buffer) (find git-status:buffer? (buffers:all)))

(define (numbers from to)
  (let loop ([i to] [acc ""]) (if (< i from) acc (loop (- i 1) (string-append (number->string i) "\n" acc)))))

;; The sample repository with long.txt changed in two hunks, its status
;; shown alone.
(define (fresh! name)
  (for-each buffers:kill! (filter git-status:buffer? (buffers:all)))
  (sample-repository! name)
  (write-file! (string-append name "/long.txt") (numbers 1 20))
  (sh (string-append "cd " name " && git add long.txt && git commit -qm long -- long.txt"))
  (write-file! (string-append name "/long.txt") (string-append "1\nTWO\n" (numbers 3 17) "EIGHTEEN\n19\n20\n"))
  (let ([r (git:find-repository (at name))])
    (git-status:show r)
    r))

;; The lines a view shows, a hidden section's heading ending in an
;; ellipsis.
(define (shown v)
  (let* ([b (views:buffer v)] [doc (buffers:document b)] [n (document:length doc)])
    (define (hidden? p) (and (views:folded? v p) (exists (lambda (f) (< (car f) p)) (views:folds-at v p))))
    (define (folded-here? p) (exists (lambda (f) (= (car f) p)) (views:folds-at v p)))
    (let loop ([p 0] [line '()] [start #f] [acc '()])
      (cond
        [(= p n) (reverse acc)]
        [(char? (document:token doc p))
         (let ([c (document:token doc p)])
           (if (char=? c #\newline)
               (loop (+ p 1) '() #f
                     (if (and start (not (hidden? start)))
                         (cons (string-append (list->string (reverse line)) (if (folded-here? p) "…" "")) acc)
                         acc))
               (loop (+ p 1) (cons c line) (or start p) acc)))]
        [else (loop (+ p 1) line start acc)]))))

(define (status) (shown (view)))

(define (point-line)
  (let* ([v (view)] [doc (buffers:document (views:buffer v))] [p (views:point v)]
         [line (document:line doc p)] [s (document:line-start doc line)])
    (let loop ([q s] [acc '()])
      (let ([t (and (< q (document:length doc)) (document:token doc q))])
        (cond
          [(or (not t) (eqv? t #\newline)) (list->string (reverse acc))]
          [(char? t) (loop (+ q 1) (cons t acc))]
          [else (loop (+ q 1) acc)])))))

(define started 0)
(define ended 0)
(hooks:add! commands:before-command (lambda (command) (set! started (+ started 1))))
(hooks:add! commands:after-command (lambda (command) (set! ended (+ ended 1))))

;; A key's command runs in a task of its own, and git's in processes,
;; so a test waits until every command has ended and the repository's
;; Git buffers are current.
(define (settle!)
  (let loop ([n 0])
    (timers:sleep 0.05)
    (testing:wait-until (lambda () (= started ended)))
    (let ([b (status-buffer)])
      (when b (git-mode:wait-until-current b)))
    (unless (or (= n 3) (and (= started ended) (not (exists (lambda (r) (git:queued? r)) (repositories)))))
      (loop (+ n 1)))))

(define (repositories)
  (let ([b (status-buffer)]) (if b (list (buffers:with-buffer b (git-mode:repository))) '())))

(define (shown-buffer) (let ([b (views:buffer (view))]) (and b (buffers:name b))))

(define (section . identity) (ui:find-section (status-buffer) identity))

(define (go-to-section! . identity)
  (views:set-point! (view) (ui:section-heading-start (apply section identity))))

(define (go-to-in! text . identity)
  (let* ([s (apply section identity)] [doc (buffers:document (status-buffer))])
    (go-to-between! text (document:node-start s) (document:node-end s))))

(define (go-to! text) (go-to-between! text 0 (document:length (buffers:document (views:buffer (view))))))

(define (go-to-between! text from to)
  (let* ([v (view)] [doc (buffers:document (views:buffer v))] [n to]
         [chars (let loop ([p from] [acc '()])
                  (cond
                    [(= p n) (reverse acc)]
                    [(char? (document:token doc p)) (loop (+ p 1) (cons (cons p (document:token doc p)) acc))]
                    [else (loop (+ p 1) acc)]))]
         [k (string-length text)])
    (let loop ([cs chars])
      (cond
        [(< (length cs) k) (error 'go-to! "not found" text)]
        [(string=? (list->string (map cdr (list-head cs k))) text) (views:set-point! v (caar cs))]
        [else (loop (cdr cs))]))))

(define (mouse-in! v action place . fields)
  (parameterize ([web:current-client client])
    ((tables:ref web:input-handlers "mouse") client
     (append fields
             `(("type" . "mouse") ("action" . ,action) ("button" . 1) ("clicks" . 1) ("modifiers" . #())
               ("view" . ,(views:id v)) ("version" . ,(buffers:version (views:buffer v)))
               ("showing" . ,(views:shown-count v)) ("report" . 1)
               ,@place)))))

(define (click-at! v at) (mouse-in! v "down" `(("at" . ,at) ("count" . 0))) (mouse-in! v "click" `(("at" . ,at) ("count" . 0))))

;; A click on an element a keymap marks, as the page sends one.
(define (click-marked! v at keymap)
  (let ([marks (vector (read (open-input-string (views:keymap-mark keymap))))])
    (mouse-in! v "down" `(("token" . ,at)) (cons "keymaps" marks))
    (mouse-in! v "click" `(("token" . ,at)) (cons "keymaps" marks))))

(define (menu-buffer) (buffers:find " *transient*"))

(define (menu-open?) (let ([b (menu-buffer)]) (and b (pair? (views:showing b)))))

;; The open menu as its title, then each group's heading and its entries'
;; keys, descriptions and arguments, an argument that is in starred.
(define (menu)
  (define (attribute d key) (let ([p (assq key (vector-ref d 1))]) (and p (cdr p))))
  (define (entry d)
    (let ([argument (attribute d 'argument)])
      (append (list (attribute d 'key) (attribute d 'description))
              (if argument (list (if (eq? (attribute d 'in) #t) (string-append "*" argument) argument)) '()))))
  (map (lambda (part)
         (if (vector? part)
             (attribute part 'text)
             (map (lambda (d) (if (eq? (vector-ref d 0) 'transient:%heading) (attribute d 'text) (entry d)))
                  (cddr part))))
       (cddr (car (document:datums (buffers:document (menu-buffer)))))))

(define (raised thunk)
  (guard (c [#t (if (message-condition? c) (condition-message c) c)])
    (thunk)
    'no-error))
(import (console))

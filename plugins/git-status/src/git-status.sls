#!tuna
(import (git-mode) (git) (diff) (diff-sections) (ui) (buffers) (document) (views) (layout) (keys) (commands) (files)
        (ask) (modes) (transient) (faces) (web) (haml) (hooks) (options) (tables))

(define %self (current-owner))

(options:define-option initial-section 1
  (lambda (v) (or (not v) (and (fixnum? v) (fx> v 0)) (and (list? v) (for-all list? v))))
  "Where point starts in a new status buffer: the Nth section after the headers, the first section whose identity is in a list of identities, or the first line with #f.")

(options:define-option untracked-files #f (lambda (v) (or (not v) (memq v '(normal all no))))
  "How untracked files are listed, a value of git:untracked-listing; #f follows git's status.showUntrackedFiles.")

(options:define-option file-list-limit 100 (lambda (v) (and (fixnum? v) (fx> v 0)))
  "How many untracked files the list shows.")

(options:define-option commit-count 10 (lambda (v) (and (fixnum? v) (fx> v 0)))
  "How many commits Recent commits shows.")

(hooks:define-hook headers
  "Procedures of the repository and its status, each returning a list of header lines, each a list of inline content.")

(hooks:define-hook sections
  "Procedures of the repository and its status, each returning a list of section datums.")

(tables:define-table keymap "Keys in the status buffer.")

(hooks:define-hook mode-hook "Called in each status buffer as its mode is set.")

(modes:define-major-mode mode
  (parent git-mode:mode)
  (lighter "Git")
  (keymap keymap)
  (hook mode-hook)
  (plugin-only #t))

(define (%face face . content) (apply %styled `((face . ,(if (symbol? face) (symbol->string face) face))) content))

(define (%draw-styled node view)
  (haml (:span ([data-face (document:node-attribute node 'face)]) (views:draw-children view node))))

(buffers:define-kind %styled (inline) (draw %draw-styled))

(buffers:define-kind %header)

;; The counts are drawn, not text, as VS Code's sync counts are, so a
;; copied header holds none.
(define (%draw-counts node view)
  (let* ([ahead (document:node-attribute node 'ahead)] [behind (document:node-attribute node 'behind)]
         [up (if (eqv? ahead 0) '() (haml (:span ([data-face "git-status.ahead"]) "↑" ahead)))]
         [down (if (eqv? behind 0) '() (haml (:span ([data-face "git-status.behind"]) "↓" behind)))])
    (haml (:span.git-status-counts ([aria-hidden "true"]) up down))))

(buffers:define-kind %counts (inline) (draw %draw-counts))

(buffers:define-kind %gap)

(define (%path-content bytes) (document:datums (document:from-utf8 bytes)))

(define (%padded word) (string-append word (make-string (fxmax 1 (fx- 10 (string-length word))) #\space)))

(define (%label name face) (%face face name))

(define (%summary-of repository rev)
  (guard (c [(git:failed-condition? c) #f])
    (let ([cs (git:commits repository rev 1)])
      (and (pair? cs) (git:commit-subject (car cs))))))

(define (last-error-header repository status)
  (let ([e (git-mode:last-error repository)])
    (if e
        (list (list (%face "git-status.header" (%padded "GitError!")) (%face faces:error e) "  [Type $ for details]"))
        '())))

(define (%head-header repository status)
  (let ([branch (git:status-branch status)] [head (git:status-head status)])
    (list
      (cond
        [(not head) (list (%padded "Head:") (%label (or branch "HEAD") "git-status.branch-local") " In the beginning there was darkness")]
        [branch (list (%padded "Head:") (%label branch "git-status.branch-local") " " (or (%summary-of repository "HEAD") ""))]
        [else (list (%padded "Head:") (%face "git-status.hash" (substring head 0 (fxmin 7 (string-length head)))) " "
                    (or (%summary-of repository "HEAD") ""))]))))

(define (%merge-header repository status)
  (let ([upstream (git:status-upstream status)])
    (if (and upstream (git:status-head status))
        (list (append (list (%padded "Merge:") (%label upstream "git-status.branch-remote") " " (or (%summary-of repository upstream) ""))
                      (if (and (eqv? (git:status-ahead status) 0) (eqv? (git:status-behind status) 0))
                          '()
                          (list (%counts `((ahead . ,(git:status-ahead status)) (behind . ,(git:status-behind status))))))))
        '())))

(define (%push-branch repository status)
  (let* ([branch (git:status-branch status)] [remote (and branch (git:push-remote repository branch))])
    (and remote (string-append remote "/" branch))))

(define (%push-header repository status)
  (let ([push (%push-branch repository status)])
    (if (and push (not (equal? push (git:status-upstream status))) (git:status-head status))
        (list (list (%padded "Push:") (%label push "git-status.branch-remote") " " (or (%summary-of repository push) "")))
        '())))

(define (%tag-header repository status)
  (let ([described (and (git:status-head status)
                        (guard (c [(git:failed-condition? c) #f])
                          (let ([out (utf8->string (git:query repository '("describe" "--tags" "--long" "HEAD")))])
                            (substring out 0 (fxmax 0 (fx- (string-length out) 1))))))])
    (if described
        (let* ([dash2 (let loop ([i (fx- (string-length described) 1)] [n 0])
                        (cond [(fx< i 0) #f] [(char=? (string-ref described i) #\-) (if (fx= n 1) i (loop (fx- i 1) (fx+ n 1)))] [else (loop (fx- i 1) n)]))]
               [tag (and dash2 (substring described 0 dash2))]
               [count (and dash2 (let ([rest (substring described (fx+ dash2 1) (string-length described))])
                                   (string->number (let loop ([i 0]) (if (char=? (string-ref rest i) #\-) (substring rest 0 i) (loop (fx+ i 1)))))))])
          (if tag
              (list (append (list (%padded "Tag:") (%label tag "git-status.tag"))
                            (if (and count (> count 0)) (list (format " (~a)" count)) '())))
              '()))
        '())))

(define (%list-section type value title items hidden?)
  (if (null? items)
      '()
      (list (apply ui:section `((type . ,type) (value . ,value) ,@(if hidden? '((hidden . #t)) '()))
                   (format "~a (~a)" title (length items))
                   (append items '(""))))))

(define (untracked-section repository status)
  (let* ([paths (git:untracked repository (untracked-files))] [limit (file-list-limit)]
         [shown (if (> (length paths) limit) (list-head paths limit) paths)]
         [files (map (lambda (p) (ui:section `((type . file) (value . ,(utf8->string p)) (path . ,p)) (%path-content p)))
                     shown)])
    (if (null? paths)
        '()
        (list (apply ui:section '((type . untracked) (value . #f) (hidden . #t))
                     (format "Untracked files (~a)" (length paths))
                     (append files
                             (if (> (length paths) limit)
                                 (list (%section-line (%face faces:warning (format "~a files not listed" (- (length paths) limit)))))
                                 '())
                             '("")))))))

(buffers:define-kind %line)

(define (%section-line . content) (apply %line '() (append content '("\n"))))

(define (%diff-files repository arguments)
  (map (lambda (f) (diff-sections:file-section f '((hidden . #t)))) (git:diff repository arguments)))

(define (unstaged-section repository status)
  (%list-section 'unstaged #f "Unstaged changes" (%diff-files repository '()) #f))

(define (staged-section repository status)
  (%list-section 'staged #f "Staged changes" (%diff-files repository '("--cached")) #f))

(define (stashes-section repository status)
  (%list-section 'stashes #f "Stashes"
    (map (lambda (s) (ui:section `((type . stash) (value . ,(car s))) (list (%face "git-status.stash" (car s)) " " (cdr s))))
         (git:stashes repository))
    #f))

(define (%commit-section commit)
  (ui:section `((type . commit) (value . ,(git:commit-name commit)))
              (append (list (%face "git-status.hash" (git:commit-short-name commit)) " ")
                      (apply append (map (lambda (r) (list (%label r (if (%remote-ref? r) "git-status.branch-remote" "git-status.branch-local")) " "))
                                         (git:commit-refs commit)))
                      (list (git:commit-subject commit)))))

(define (%remote-ref? r)
  (let loop ([i 0]) (and (fx< i (string-length r)) (or (char=? (string-ref r i) #\/) (loop (fx+ i 1))))))

(define (%commits repository range count)
  (guard (c [(git:failed-condition? c) '()])
    (git:commits repository range count)))

(define (%push-differs? repository status)
  (let ([push (%push-branch repository status)])
    (and push (not (equal? push (git:status-upstream status))) (git:status-head status)
         (pair? (guard (c [(git:failed-condition? c) '()]) (git:remote-branches repository)))
         (member push (git:remote-branches repository))
         push)))

(define (unpushed-section repository status)
  (let ([push (%push-differs? repository status)])
    (if push
        (%list-section 'unpushed "@{push}" (string-append "Unpushed to " push)
          (map %commit-section (%commits repository (string-append push "..HEAD") #f)) #t)
        '())))

(define (unmerged-section repository status)
  (let* ([upstream (and (git:status-head status) (git:status-upstream status))]
         [unmerged (if upstream (%commits repository (string-append upstream "..HEAD") #f) '())])
    (cond
      [(pair? unmerged)
       (%list-section 'unpushed "@{upstream}" (string-append "Unmerged into " upstream) (map %commit-section unmerged) #f)]
      [(git:status-head status)
       (list (apply ui:section '((type . recent) (value . #f) (hidden . #t)) "Recent commits"
                    (append (map %commit-section (%commits repository "HEAD" (commit-count))) '(""))))]
      [else '()])))

(define (unpulled-from-push-section repository status)
  (let ([push (%push-differs? repository status)])
    (if push
        (%list-section 'unpulled "@{push}" (string-append "Unpulled from " push)
          (map %commit-section (%commits repository (string-append "HEAD.." push) #f)) #t)
        '())))

(define (unpulled-section repository status)
  (let ([upstream (and (git:status-head status) (git:status-upstream status))])
    (if upstream
        (%list-section 'unpulled "@{upstream}" (string-append "Unpulled from " upstream)
          (map %commit-section (%commits repository (string-append "HEAD.." upstream) #f)) #t)
        '())))

(define (%header-datum line) (apply %header '() (append line '("\n"))))

(define (%in-tasks repository status entries)
  (let ([tasks (map (lambda (entry) (call-as-owner %self (lambda () (spawn-task (lambda (restore) (entry repository status)))))) entries)])
    (apply append
      (map (lambda (t)
             (let-values ([(how detail) (join-task t)])
               (case how
                 [(returned) (car detail)]
                 [(raised) (raise detail)]
                 [else '()])))
           tasks))))

(define (%contents repository)
  (let* ([status (git:status repository)]
         [header-lines (%in-tasks repository status (hooks:entries headers))]
         [lists (%in-tasks repository status (hooks:entries sections))])
    (append
      (if (null? header-lines)
          '()
          (list (apply ui:section '((type . headers) (value . #f)) (car header-lines)
                       (map %header-datum (cdr header-lines)))
                (%gap '() "\n")))
      lists)))

(define (%refresh! b)
  (let ([r (buffers:with-buffer b (git-mode:repository))])
    (buffers:reconcile! b (document:token (buffers:document b) 0) (%contents r))))

(define (buffer? b)
  (and (buffers:buffer? b) (buffers:live? b) (eq? (modes:major-mode b) mode)))

(define (%status-buffer repository) (git-mode:buffer repository "git" mode %refresh!))

(define %gap-kind (buffers:kind-name (buffers:constructor-kind %gap)))

(define (%top-sections b)
  (let ([doc (buffers:document b)] [acc '()])
    (when (fx> (document:length doc) 0)
      (let ([root (document:token doc 0)])
        (document:for-each-child root (fx+ (document:node-start root) 1) (fx- (document:node-end root) 1)
          (lambda (child at)
            (when (and (document:node? child) (not (document:atom? child)) (not (eq? (document:node-kind child) %gap-kind)))
              (set! acc (cons child acc)))))))
    (reverse acc)))

(define (%place-initial! view b)
  (let* ([tops (filter (lambda (s) (not (eq? (ui:section-type s) 'headers))) (%top-sections b))]
         [choice (initial-section)]
         [target (cond
                   [(not choice) #f]
                   [(fixnum? choice) (and (>= (length tops) choice) (list-ref tops (- choice 1)))]
                   [else (or (exists (lambda (identity) (ui:find-section b identity)) choice) (and (pair? tops) (car tops)))])])
    (if target
        (views:set-point! view (ui:section-heading-start target))
        (views:set-point! view (or (views:next-stop view 0) 0)))))

(define (%existing-status-buffer repository)
  (find (lambda (b) (and (buffer? b)
                         (string=? (git:repository-root (buffers:with-buffer b (git-mode:repository))) (git:repository-root repository))))
        (buffers:all)))

;; A status buffer already made shows at once and is refreshed in place,
;; its keys working meanwhile; a new one is filled before it shows.
(define (%show! repository)
  (let* ([existing (%existing-status-buffer repository)] [b (%status-buffer repository)])
    (if existing
        (begin
          (layout:select! (or (layout:reuse-view b) (layout:display-buffer b)))
          (git-mode:refresh-repository repository))
        (begin
          (git-mode:refresh-repository repository)
          (let ([v (or (layout:reuse-view b) (layout:display-buffer b))])
            (layout:select! v)
            (%place-initial! v b))))))

(define (%read-repository)
  (let ([prefix (commands:prefix-argument)])
    (or (and (not prefix) (git-mode:find-current-repository))
        (let ([folder (files:expanded-path (ask:file-name "Git repository: "))])
          (or (git:find-repository folder)
              (and (ask:y-or-n? (string-append "Create repository in " (%with-slash folder) "? "))
                   (git:init folder)))))))

(define (%with-slash path)
  (if (and (fx> (string-length path) 0) (char=? (string-ref path (fx- (string-length path) 1)) #\/)) path (string-append path "/")))

(commands:define-command (show [repository (%read-repository)])
  "Shows the status buffer of REPOSITORY and selects its view; outside a repository, or with C-u, reads one, offering to create it."
  (unless (or (not repository) (git:repository? repository))
    (assertion-violation 'git-status:show "not a repository or #f" repository))
  (when repository
    (%show! repository)))

(define (%existing-ancestor folder)
  (let loop ([f (substring folder 0 (fx- (string-length folder) 1))])
    (cond
      [(file-directory? f) f]
      [else
       (let ([slash (let find ([i (fx- (string-length f) 1)]) (cond [(fx<= i 0) #f] [(char=? (string-ref f i) #\/) i] [else (find (fx- i 1))]))])
         (and slash (loop (substring f 0 slash))))])))

(define (%read-init-folder)
  (let* ([folder (%with-slash (files:expanded-path (ask:file-name "Create repository in: ")))]
         [ancestor (%existing-ancestor folder)]
         [existing (and ancestor (git:find-repository ancestor))])
    (when existing
      (unless (ask:y-or-n?
                (if (string=? (git:repository-root existing) folder)
                    (string-append "Reinitialize existing repository " folder "? ")
                    (string-append (git:repository-root existing) " is a repository.  Create another in " folder "? ")))
        (error 'git-status:init "Abort")))
    folder))

(commands:define-command (init [folder (%read-init-folder)])
  "Runs git init in FOLDER and shows its status."
  (unless (string? folder)
    (assertion-violation 'git-status:init "not a string" folder))
  (%show! (git:init folder)))

(define (refresh-after-save buffer)
  (let ([path (files:path buffer)])
    (when path
      (let ([b (find (lambda (b) (let ([root (git:repository-root (buffers:with-buffer b (git-mode:repository)))])
                                   (and (fx>= (string-length path) (string-length root))
                                        (string=? (substring path 0 (string-length root)) root))))
                     (filter buffer? (buffers:all)))])
        (when b
          (call-as-owner %self
            (lambda ()
              (spawn-task
                (lambda (restore)
                  (git-mode:refresh-repository (buffers:with-buffer b (git-mode:repository))))))))))))

(define (%list-of b section)
  (let up ([s section])
    (and s (if (memq (ui:section-type s) '(untracked unstaged staged unpushed unpulled recent stashes headers)) s
               (up (ui:section-parent s b))))))

(define (%side b section)
  (let ([l (%list-of b section)]) (and l (ui:section-type l))))

(define (%file-of b section)
  (case (ui:section-type section)
    [(file) section]
    [(hunk) (ui:section-parent section b)]
    [else #f]))

(define (%path-bytes b file-section)
  (let ([path (document:node-attribute file-section 'path #f)])
    (or path (diff:file-path-bytes (diff-sections:file file-section b)))))

(define-record-type %selection
  (sealed #t)
  (fields side kind sections hunk first last))

(define (%selection-of view section)
  (let ([b (views:buffer view)])
    (cond
      [section (%of-section b section)]
      [(ui:section-selection view)
       => (lambda (ss) (make-%selection (%side b (car ss)) (if (eq? (ui:section-type (car ss)) 'hunk) 'hunks 'files) ss #f #f #f))]
      [else
       (let-values ([(hunk first last) (diff-sections:selected-lines view)])
         (if hunk
             (make-%selection (%side b hunk) 'lines (list hunk) hunk first last)
             (%of-section b (ui:section-at view))))])))

(define (%of-section b section)
  (cond
    [(not section) (make-%selection #f 'none '() #f #f #f)]
    [else
     (case (ui:section-type section)
       [(untracked unstaged staged)
        (make-%selection (ui:section-type section) 'list
                         (filter (lambda (s) (eq? (ui:section-type s) 'file)) (ui:section-children section)) #f #f #f)]
       [(file) (make-%selection (%side b section) 'files (list section) #f #f #f)]
       [(hunk) (make-%selection (%side b section) 'hunks (list section) #f #f #f)]
       [(commit) (make-%selection 'commit 'none '() #f #f #f)]
       [else (make-%selection (%side b section) 'none '() #f #f #f)])]))

(define (%status-view who)
  (let ([v (views:current)])
    (unless (and v (buffer? (views:buffer v)))
      (error who "Not in a status buffer"))
    v))

(define (%repository-of view) (buffers:with-buffer (views:buffer view) (git-mode:repository)))

(define (%context-zero? repository)
  (or (member "-U0" (git:diff-arguments)) (equal? (git:config repository "diff.context") "0")))

(define (%ignoring-whitespace?)
  (exists (lambda (a) (member a '("-w" "-b" "--ignore-space-at-eol" "--ignore-blank-lines" "--ignore-all-space" "--ignore-space-change")))
          (git:diff-arguments)))

(define (%check-context repository who)
  (when (%context-zero? repository)
    (error who "Not enough context to apply patch.  Increase the context")))

(define (%hunks-of b sections) (map diff-sections:hunk sections))

(define-record-type %place
  (sealed #t)
  (fields side path file-index hunk-index))

(define (%index-of x xs)
  (let loop ([xs xs] [i 0])
    (cond [(null? xs) #f] [(fx= (document:node-start (car xs)) (document:node-start x)) i] [else (loop (cdr xs) (fx+ i 1))])))

(define (%place-of b selection)
  (let* ([first (and (pair? (%selection-sections selection)) (car (%selection-sections selection)))]
         [file (and first (%file-of b first))]
         [l (and file (%list-of b file))])
    (and l (memq (%selection-kind selection) '(files hunks lines))
         (make-%place (ui:section-type l) (ui:section-value file)
                      (%index-of file (ui:section-children l))
                      (and (memq (ui:section-type first) '(hunk)) (%index-of first (ui:section-children file)))))))

(define (%go-to-place! view place)
  (let* ([b (views:buffer view)]
         [l (find (lambda (s) (eq? (ui:section-type s) (%place-side place))) (%top-sections b))])
    (when l
      (let* ([files (filter (lambda (s) (eq? (ui:section-type s) 'file)) (ui:section-children l))]
             [same (find (lambda (f) (equal? (ui:section-value f) (%place-path place))) files)]
             [target
              (or (and (%place-hunk-index place) same
                       (let ([hunks (ui:section-children same)])
                         (and (> (length hunks) (%place-hunk-index place)) (list-ref hunks (%place-hunk-index place)))))
                  (let ([i (if (and same (%place-hunk-index place)) (+ (%index-of same files) 1) (%place-file-index place))])
                    (and i (> (length files) i) (list-ref files i)))
                  l)])
        (views:set-point! view (ui:section-heading-start target))))))

(define (%changed! view place)
  (when place (views:set-mark! view #f))
  (git-mode:wait-until-current (views:buffer view))
  (when (and place (buffers:live? (views:buffer view)))
    (%go-to-place! view place)))

(define (%lines-patch-file b selection)
  (diff-sections:file (%selection-hunk selection) b))

(define (%stage-files! repository b sections)
  (let-values ([(patched added)
                (partition (lambda (s)
                             (and (%ignoring-whitespace?) (not (document:node-attribute s 'path #f))
                                  (let ([f (diff-sections:file s b)])
                                    (not (or (diff:file-binary? f) (eq? (diff:file-status f) 'unmerged))))))
                           sections)])
    (for-each (lambda (s) (git:apply repository (diff:file-patch (diff-sections:file s b)) '("--cached" "--ignore-space-change")))
              patched)
    (unless (null? added)
      (git:stage repository (map (lambda (s) (%path-bytes b s)) added)))))

(define (%stage-all! repository all?)
  (let ([staged? (pair? (git:diff repository '("--cached")))])
    (when staged?
      (git-mode:confirm (git-mode:confirmation stage-all-changes) "Stage all changes? "))
    (if all? (git:stage-all repository) (git:stage-tracked repository))))

(define (%read-files-to-stage view repository)
  (let* ([b (views:buffer view)]
         [candidates (append (map diff:file-path (git:diff repository '()))
                             (map utf8->string (git:untracked repository (untracked-files))))]
         [at (let ([s (ui:section-at view)]) (and s (%file-of b s) (ui:section-value (%file-of b s))))]
         [answer (ask:line-with-candidates "Stage file,s: " candidates at)])
    (let loop ([i 0] [start 0] [acc '()])
      (cond
        [(fx= i (string-length answer))
         (reverse (if (fx< start i) (cons (substring answer start i) acc) acc))]
        [(char=? (string-ref answer i) #\,) (loop (fx+ i 1) (fx+ i 1) (if (fx< start i) (cons (substring answer start i) acc) acc))]
        [else (loop (fx+ i 1) start acc)]))))

(define (%stage! view section intent?)
  (let* ([b (views:buffer view)] [repository (%repository-of view)])
    (git-mode:wait-until-current b)
    (let* ([selection (%selection-of view section)] [side (%selection-side selection)] [kind (%selection-kind selection)]
           [place (and (not section) (%place-of b selection))])
      (git-mode:call-with-failures-reported repository
        (lambda ()
          (cond
            [(eq? kind 'none)
             (if (memq side '(headers commit #f recent unpushed unpulled stashes))
                 (let ([files (%read-files-to-stage view repository)])
                   (unless (null? files) (git:stage repository files)))
                 (error 'git-status:stage "Cannot apply this, it's not a change"))]
            [(eq? side 'staged) (error 'git-status:stage "Already staged")]
            [(eq? side 'untracked)
             (let ([paths (map (lambda (s) (%path-bytes b s)) (%selection-sections selection))])
               (unless (null? paths)
                 (if intent? (git:stage-intent-to-add repository paths) (git:stage repository paths))))]
            [(not (eq? side 'unstaged)) (error 'git-status:stage "Cannot apply this, it's not a change")]
            [(eq? kind 'list) (%stage-all! repository #f)]
            [(eq? kind 'files) (%stage-files! repository b (%selection-sections selection))]
            [(eq? kind 'hunks)
             (%check-context repository 'git-status:stage)
             (let ([file (diff-sections:file (car (%selection-sections selection)) b)])
               (git:apply repository (diff:hunks-patch file (%hunks-of b (%selection-sections selection))) '("--cached")))]
            [(eq? kind 'lines)
             (%check-context repository 'git-status:stage)
             (git:apply repository (diff:lines-patch (%lines-patch-file b selection) (diff-sections:hunk (%selection-hunk selection))
                                                     (%selection-first selection) (%selection-last selection))
                        '("--cached"))])
          (%changed! view place))))))

(commands:define-command (stage [intent (commands:prefix-argument)])
  "Stages the files, hunks or lines selected; with C-u, stages untracked files with --intent-to-add."
  (%stage! (%status-view 'git-status:stage) #f (and intent #t)))

(define (%unstage! view section)
  (let* ([b (views:buffer view)] [repository (%repository-of view)])
    (git-mode:wait-until-current b)
    (let* ([selection (%selection-of view section)] [side (%selection-side selection)] [kind (%selection-kind selection)]
           [place (and (not section) (%place-of b selection))])
      (git-mode:call-with-failures-reported repository
        (lambda ()
          (cond
            [(eq? side 'untracked) (error 'git-status:unstage "Cannot unstage untracked changes")]
            [(and (eq? side 'unstaged) (eq? kind 'files)
                  (for-all (lambda (s) (let ([f (diff-sections:file s b)]) (and f (%intent-to-add? repository f))))
                           (%selection-sections selection)))
             (git:unstage repository (map (lambda (s) (%path-bytes b s)) (%selection-sections selection)))]
            [(eq? side 'unstaged) (error 'git-status:unstage "Already unstaged")]
            [(not (eq? side 'staged)) (error 'git-status:unstage "Cannot apply this, it's not a change")]
            [(eq? kind 'list) (%unstage-all! repository)]
            [(eq? kind 'files)
             (when (exists (lambda (s) (eq? (diff:file-status (diff-sections:file s b)) 'unmerged)) (%selection-sections selection))
               (error 'git-status:unstage "Unstaging a conflict waits for conflict resolution"))
             (git:unstage repository (map (lambda (s) (%path-bytes b s)) (%selection-sections selection)))]
            [(eq? kind 'hunks)
             (%check-context repository 'git-status:unstage)
             (let ([file (diff-sections:file (car (%selection-sections selection)) b)])
               (git:apply repository (diff:reverse-hunks-patch file (%hunks-of b (%selection-sections selection))) '("--reverse" "--cached")))]
            [(eq? kind 'lines)
             (%check-context repository 'git-status:unstage)
             (git:apply repository (diff:reverse-lines-patch (%lines-patch-file b selection) (diff-sections:hunk (%selection-hunk selection))
                                                             (%selection-first selection) (%selection-last selection))
                        '("--reverse" "--cached"))]
            [else (error 'git-status:unstage "Cannot apply this, it's not a change")])
          (%changed! view place))))))

(define (%intent-to-add? repository file)
  (and (eq? (diff:file-status file) 'added)
       (exists (lambda (e) (and (equal? (git:entry-path-bytes e) (diff:file-path-bytes file)) (eq? (git:entry-worktree e) 'added)))
               (git:status-entries (git:status repository)))))

(commands:define-command (unstage)
  "Unstages the files, hunks or lines selected."
  (%unstage! (%status-view 'git-status:unstage) #f))

(define (%unstage-all! repository)
  (let ([staged (git:diff repository '("--cached"))])
    (when (null? staged)
      (error 'git-status:unstage-all "Nothing to unstage"))
    (when (or (pair? (git:diff repository '())) (pair? (git:untracked repository (untracked-files))))
      (git-mode:confirm (git-mode:confirmation unstage-all-changes) "Unstage all changes? "))
    (git:unstage repository #f)))

(commands:define-command (stage-all [all (commands:prefix-argument)])
  "Stages every change to tracked files, and with C-u untracked files too, asking first when something is staged."
  (let* ([v (%status-view 'git-status:stage-all)] [repository (%repository-of v)])
    (git-mode:wait-until-current (views:buffer v))
    (git-mode:call-with-failures-reported repository
      (lambda () (%stage-all! repository (and all #t)) (%changed! v #f)))))

(commands:define-command (unstage-all)
  "Unstages everything, asking first when there are also unstaged or untracked changes."
  (let* ([v (%status-view 'git-status:unstage-all)] [repository (%repository-of v)])
    (git-mode:wait-until-current (views:buffer v))
    (git-mode:call-with-failures-reported repository
      (lambda () (%unstage-all! repository) (%changed! v #f)))))

(define (%quoted path) (string-append "\"" path "\""))

(define (%refuse-tilde! path)
  (when (and (fx> (string-length path) 0) (char=? (string-ref path 0) #\~))
    (error 'git-status:discard (string-append "Refusing to delete " (%quoted path) ", too dangerous"))))

;; Both of git status's columns decide, as in Magit's table: a staged
;; change judged by the diff alone would be restored from HEAD, losing
;; the file's unstaged changes. A row the table does not name is left
;; alone, as Magit leaves it.
(define (%kind-of-file side entry)
  (cond
    [(eq? side 'untracked) 'delete]
    [(not entry) #f]
    [else
     (let ([x (git:entry-index entry)] [y (git:entry-worktree entry)])
       (cond
         [(or (eq? x 'unmerged) (eq? y 'unmerged) (and (eq? x y) (memq x '(added deleted)))) 'resolve]
         [(eq? side 'unstaged) (case y [(modified) 'discard] [(deleted) 'resurrect] [else #f])]
         [else
          (case x
            [(modified) (and (memq y '(unmodified modified deleted)) 'discard)]
            [(added copied) (case y [(modified) 'discard-new] [(unmodified deleted) 'delete] [else #f])]
            [(deleted) (and (memq y '(unmodified modified)) 'resurrect)]
            [(renamed) (and (memq y '(unmodified modified deleted)) 'rename)]
            [else #f])]))]))

(define (%delete-question n first)
  (let ([verb (if (files:delete-by-moving-to-trash?) "Trash" "Delete")])
    (if (= n 1)
        (string-append verb " " (%quoted first) "? ")
        (string-append verb " " (number->string n) " files? "))))

(define (%discard-files! repository b side sections)
  (let* ([entries (if (eq? side 'untracked) '() (git:status-entries (git:status repository)))]
         [kind-of (lambda (s)
                    (%kind-of-file side (let ([path (%path-bytes b s)])
                                          (find (lambda (e) (equal? (git:entry-path-bytes e) path)) entries))))]
         [kinds (map (lambda (s) (cons s (kind-of s))) sections)]
         [by-kind (lambda (kind) (map car (filter (lambda (k) (eq? (cdr k) kind)) kinds)))]
         [root (git:repository-root repository)]
         [paths (lambda (ss) (map (lambda (s) (%path-bytes b s)) ss))])
    (let ([resolve (by-kind 'resolve)] [resurrect (by-kind 'resurrect)] [delete (by-kind 'delete)]
          [rename (by-kind 'rename)] [discard (by-kind 'discard)] [discard-new (by-kind 'discard-new)])
      (unless (null? resolve)
        (error 'git-status:discard "Discarding a conflict waits for conflict resolution"))
      (unless (null? resurrect)
        (git-mode:confirm (git-mode:confirmation resurrect)
          (if (= (length resurrect) 1)
              (string-append "Resurrect " (%quoted (ui:section-value (car resurrect))) "? ")
              (format "Resurrect ~a files? " (length resurrect))))
        (if (eq? side 'staged)
            (git:unstage repository (paths resurrect))
            (git:restore-from-index repository (paths resurrect))))
      (unless (null? delete)
        (for-each (lambda (s) (%refuse-tilde! (ui:section-value s))) delete)
        (git-mode:confirm (if (files:delete-by-moving-to-trash?) (git-mode:confirmation trash) (git-mode:confirmation delete))
          (string-append
            (if (> (length delete) 1)
                (apply string-append (map (lambda (s) (string-append (ui:section-value s) "\n")) delete))
                "")
            (%delete-question (length delete) (ui:section-value (car delete)))))
        (when (eq? side 'staged)
          (git:run repository (append '("rm" "--cached" "--force" "-q" "--") (map (lambda (s) (ui:section-value s)) delete))))
        (for-each (lambda (s)
                    (let ([path (string-append root (ui:section-value s))])
                      (when (or (file-exists? path #f) (file-directory? path))
                        (if (files:delete-by-moving-to-trash?) (files:move-to-trash path) (files:delete-file path)))))
                  delete))
      (for-each
        (lambda (s)
          (let* ([f (diff-sections:file s b)] [old (diff:file-old-path f)] [new (diff:file-new-path f)])
            (git-mode:confirm (git-mode:confirmation rename)
              (string-append "Undo rename " old " -> " new "? "))
            (if (file-exists? (string-append root new) #f)
                (let ([folder (path-parent (string-append root old))])
                  (unless (file-directory? folder) (files:make-folder folder))
                  (git:run repository (list "mv" "--" new old)))
                (git:unstage repository (list (%path-bytes b s) (diff:file-old-path-bytes f))))))
        rename)
      (let ([all (append discard discard-new)])
        (unless (null? all)
          (git-mode:confirm (git-mode:confirmation discard)
            (if (= (length all) 1)
                (string-append "Discard " (if (eq? side 'staged) "staged" "unstaged") " changes in " (%quoted (ui:section-value (car all))) "? ")
                (format "Discard ~a changes in ~a files? " (if (eq? side 'staged) "staged" "unstaged") (length all))))
          (if (eq? side 'unstaged)
              (git:restore-from-index repository (paths discard))
              (%discard-staged-files! repository b discard (paths discard-new))))))))

;; As magit-discard-files--discard: a new file changed since it was
;; staged leaves the index and keeps its content; a binary file has no
;; patch to reverse, so it is unstaged, and refused when it also has
;; unstaged changes, which unstaging would mix with the staged one.
;; Files with unstaged changes need their own patch, since --index
;; refuses a file whose worktree differs from its index; Magit checks
;; only the first file, so its one patch fails when a later one has some.
(define (%discard-staged-files! repository b discard new-paths)
  (unless (null? new-paths)
    (git:stage repository new-paths)
    (git:unstage repository new-paths))
  (unless (null? discard)
    (let* ([unstaged (%unstaged-paths repository)]
           [unstaged? (lambda (f) (hashtable-contains? unstaged (diff:file-path-bytes f)))])
      (let*-values ([(binaries patched) (partition diff:file-binary? (map (lambda (s) (diff-sections:file s b)) discard))]
                    [(mixed clean) (partition unstaged? patched)])
        (unless (null? clean)
          (git:apply repository (%joined-patch clean) '("--reverse" "--index")))
        (unless (null? mixed)
          (let ([patch (%joined-patch mixed)])
            (git:apply repository patch '("--reverse" "--cached"))
            (git:apply repository patch '("--reverse" "--reject"))))
        (let-values ([(kept unstage) (partition unstaged? binaries)])
          (unless (null? unstage)
            (git:unstage repository (map diff:file-path-bytes unstage)))
          (unless (null? kept)
            (error 'git-status:discard
                   "Cannot discard staged changes to binary files, which also have unstaged changes.  Unstage instead")))))))

(define (%joined-patch files)
  (call-with-bytevector-output-port
    (lambda (p) (for-each (lambda (f) (put-bytevector p (diff:file-patch f))) files))))

(define (%unstaged-paths repository)
  (let ([paths (make-hashtable equal-hash equal?)])
    (for-each (lambda (f) (hashtable-set! paths (diff:file-path-bytes f) #t)) (git:diff repository '()))
    paths))

(define (%has-unstaged? repository file)
  (hashtable-contains? (%unstaged-paths repository) (diff:file-path-bytes file)))

(define (%discard! view section)
  (let* ([b (views:buffer view)] [repository (%repository-of view)])
    (git-mode:wait-until-current b)
    (let* ([selection (%selection-of view section)] [side (%selection-side selection)] [kind (%selection-kind selection)]
           [place (and (not section) (%place-of b selection))])
      (git-mode:call-with-failures-reported repository
        (lambda ()
          (cond
            [(memq side '(unpushed unpulled recent commit)) (error 'git-status:discard "Cannot discard committed changes")]
            [(or (eq? kind 'none) (not (memq side '(untracked unstaged staged))))
             (error 'git-status:discard "Cannot apply this, it's not a change")]
            [(memq kind '(list files)) (%discard-files! repository b side (%selection-sections selection))]
            [(eq? kind 'hunks)
             (%check-context repository 'git-status:discard)
             (let* ([sections (%selection-sections selection)] [file (diff-sections:file (car sections) b)]
                    [patch (diff:reverse-hunks-patch file (%hunks-of b sections))])
               (git-mode:confirm (git-mode:confirmation discard)
                 (if (= (length sections) 1) "Discard hunk? " (format "Discard ~a hunks from ~a? " (length sections) (diff:file-path file))))
               (%apply-discard! repository side file patch))]
            [(eq? kind 'lines)
             (%check-context repository 'git-status:discard)
             (let* ([file (%lines-patch-file b selection)]
                    [patch (diff:reverse-lines-patch file (diff-sections:hunk (%selection-hunk selection))
                                                     (%selection-first selection) (%selection-last selection))])
               (git-mode:confirm (git-mode:confirmation discard) "Discard region? ")
               (%apply-discard! repository side file patch))])
          (%changed! view place))))))

(define (%apply-discard! repository side file patch)
  (cond
    [(eq? side 'unstaged) (git:apply repository patch '("--reverse"))]
    [(%has-unstaged? repository file)
     (git:apply repository patch '("--reverse" "--cached"))
     (git:apply repository patch '("--reverse" "--reject"))]
    [else (git:apply repository patch '("--reverse" "--index"))]))

(commands:define-command (discard)
  "Discards the files, hunks or lines selected, asking first."
  (%discard! (%status-view 'git-status:discard) #f))

(define (%worktree-line repository file line)
  (let ([unstaged (find (lambda (f) (equal? (diff:file-path-bytes f) (diff:file-path-bytes file))) (git:diff repository '()))])
    (if unstaged
        (let loop ([hunks (diff:file-hunks unstaged)] [shift 0])
          (cond
            [(null? hunks) (+ line shift)]
            [(< line (diff:hunk-old-start (car hunks))) (+ line shift)]
            [(< line (+ (diff:hunk-old-start (car hunks)) (diff:hunk-old-count (car hunks))))
             (diff:hunk-new-start (car hunks))]
            [else (loop (cdr hunks) (+ shift (- (diff:hunk-new-count (car hunks)) (diff:hunk-old-count (car hunks)))))]))
        line)))

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

(define (%visit-target view)
  (let* ([b (views:buffer view)] [repository (%repository-of view)] [root (git:repository-root repository)]
         [section (ui:section-at view)] [file-section (and section (%file-of b section))]
         [side (and section (%side b section))])
    (unless (and file-section (memq side '(untracked unstaged staged)))
      (error 'git-status:visit "Cannot determine file to visit"))
    (let ([path (string-append root (ui:section-value file-section))])
      (if (eq? side 'untracked)
          (values path 1 0)
          (let ([file (diff-sections:file file-section b)])
            (let-values ([(hunk-section index) (diff-sections:line-at view)])
              (let* ([line (if hunk-section
                               (%line-of (diff-sections:hunk hunk-section) index)
                               (%first-changed-line file))]
                     [line (if (eq? side 'staged) (%worktree-line repository file line) line)]
                     [column (if hunk-section
                                 (let* ([doc (buffers:document b)] [p (views:point view)]
                                        [width (bytevector-length (diff:line-prefix (vector-ref (diff:hunk-lines (diff-sections:hunk hunk-section)) index)))])
                                   (fxmax 0 (fx- (document:column doc p) width)))
                                 0)])
                (values path line column))))))))

(define (%visit! view other-view?)
  (let-values ([(path line column) (%visit-target view)])
    (let ([repository (and (file-directory? path) (git:find-repository path))])
      (if (and repository (string=? (git:repository-root repository) (%with-slash path)))
          (let ([b (%status-buffer repository)])
            (git-mode:refresh-repository repository)
            (layout:switch-to-buffer b)
            (%place-initial! (layout:selected-view) b))
          (let ([b (files:visit path)])
            (if other-view?
                (layout:select! (layout:display-buffer b layout:display-in-other-view))
                (layout:switch-to-buffer b))
            (let* ([v (layout:selected-view)] [doc (buffers:document b)])
              (when (eq? (views:buffer v) b)
                (let ([last (document:line doc (document:length doc))])
                  (views:set-point! v (document:column-position doc (fxmax 1 (fxmin line last)) column))))))))))

(commands:define-command (visit [other-view (commands:prefix-argument)])
  "Visits the file of the section at point, at the line of point's diff line; with C-u, in another view."
  (%visit! (%status-view 'git-status:visit) (and other-view #t)))

(commands:define-command (visit-worktree-file [other-view (commands:prefix-argument)])
  "Visits the working tree's file of the section at point, at the line of point's diff line, from a staged diff too."
  (%visit! (%status-view 'git-status:visit-worktree-file) (and other-view #t)))

(define (%clicked-section who)
  (let* ([event (keys:command-event)] [posn (and (keys:event? event) (keys:event-start event))]
         [v (and posn (views:posn-view posn))] [p (and posn (views:posn-point posn))])
    (unless (and v p (buffer? (views:buffer v)))
      (error who "no row at the click"))
    (values v (ui:section-at v p))))

(define (%run-on-click! who action)
  (let-values ([(v s) (%clicked-section who)])
    (views:call-with-view v (lambda () (action v s)))))

(commands:define-command (stage-button)
  "Stages the row whose button was clicked."
  (%run-on-click! 'git-status:stage-button (lambda (v s) (%stage! v s #f))))

(commands:define-command (unstage-button)
  "Unstages the row whose button was clicked."
  (%run-on-click! 'git-status:unstage-button (lambda (v s) (%unstage! v s))))

(commands:define-command (discard-button)
  "Discards the row whose button was clicked, asking first."
  (%run-on-click! 'git-status:discard-button (lambda (v s) (%discard! v s))))

(tables:define-table stage-button-keys "Clicks on a row's stage button.")
(tables:define-table unstage-button-keys "Clicks on a row's unstage button.")
(tables:define-table discard-button-keys "Clicks on a row's discard button.")

(define (%button keymap label title)
  (haml (:button.ui-button.git-status-button ([type "button"] [tabindex "-1"] [title title]
                                              [data-keymap (views:keymap-mark keymap)])
          label)))

(define (%row-buttons view section)
  (let ([b (views:buffer view)])
    (and (buffer? b)
         (memq (ui:section-type section) '(file hunk untracked unstaged staged))
         (let ([side (%side b section)])
           (and (memq side '(untracked unstaged staged))
                (let ([first (if (eq? side 'staged)
                                 (%button unstage-button-keys "−" "Unstage")
                                 (%button stage-button-keys "+" "Stage"))])
                  (haml (:span.git-status-buttons first (%button discard-button-keys "⟲" "Discard")))))))))

(for-each
  (lambda (keymap command)
    (keys:bind! keymap "<mouse-1>" command)
    (keys:bind! keymap "<mouse-2>" command)
    (keys:bind! keymap "<down-mouse-1>" keys:ignore)
    (keys:bind! keymap "<drag-mouse-1>" keys:ignore)
    (keys:bind! keymap "<drag-mouse-2>" keys:ignore))
  (list stage-button-keys unstage-button-keys discard-button-keys)
  (list stage-button unstage-button discard-button))

(hooks:add! headers last-error-header -10)
(hooks:add! headers %head-header 0)
(hooks:add! headers %merge-header 10)
(hooks:add! headers %push-header 20)
(hooks:add! headers %tag-header 30)
(hooks:add! sections untracked-section 0)
(hooks:add! sections unstaged-section 10)
(hooks:add! sections staged-section 20)
(hooks:add! sections stashes-section 30)
(hooks:add! sections unpushed-section 40)
(hooks:add! sections unmerged-section 50)
(hooks:add! sections unpulled-from-push-section 60)
(hooks:add! sections unpulled-section 70)
(hooks:add! ui:section-heading-adornments %row-buttons)
(keys:bind! keymap "s" stage)
(keys:bind! keymap "u" unstage)
(keys:bind! keymap "k" discard)
(keys:bind! keymap "S" stage-all)
(keys:bind! keymap "U" unstage-all)
(keys:bind! keymap "RET" visit)
(keys:bind! keymap "C-j" visit-worktree-file)
(keys:bind! keymap "C-RET" visit-worktree-file)
(keys:bind! keys:global "C-x g" show)
(transient:add! git-mode:dispatch-menu #f
  (transient:command "I" "Init" init))
(transient:add! git-mode:dispatch-menu "Applying changes"
  (transient:command "s" "Stage" stage)
  (transient:command "u" "Unstage" unstage)
  (transient:command "k" "Discard" discard)
  (transient:command "S" "Stage all" stage-all)
  (transient:command "U" "Unstage all" unstage-all))
(transient:add! git-mode:dispatch-menu "Essential commands"
  (transient:command "RET" "Visit thing at point" visit))
(tables:set! web:stylesheets 'git-status "git-status/git-status.css")

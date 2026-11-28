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

(define (%list-section make type value title items hidden?)
  (if (null? items)
      '()
      (list (apply make `((type . ,type) (value . ,value) ,@(if hidden? '((hidden . #t)) '()))
                   (format "~a (~a)" title (length items))
                   (append items '(""))))))

(define (untracked-section repository status)
  (let* ([paths (git:untracked repository (untracked-files))] [limit (file-list-limit)]
         [shown (if (> (length paths) limit) (list-head paths limit) paths)]
         [files (map (lambda (p) (git-mode:file-section `((type . file) (value . ,(utf8->string p)) (path . ,p)) (%path-content p)))
                     shown)])
    (if (null? paths)
        '()
        (list (apply git-mode:change-list-section '((type . untracked) (value . #f) (hidden . #t))
                     (format "Untracked files (~a)" (length paths))
                     (append files
                             (if (> (length paths) limit)
                                 (list (%section-line (%face faces:warning (format "~a files not listed" (- (length paths) limit)))))
                                 '())
                             '("")))))))

(buffers:define-kind %line)

(define (%section-line . content) (apply %line '() (append content '("\n"))))

(define (%diff-files repository arguments)
  (map (lambda (f) (diff-sections:file-section f '((hidden . #t)) git-mode:file-section))
       (git:diff repository (append (git:diff-arguments) arguments))))

(define (unstaged-section repository status)
  (%list-section git-mode:change-list-section 'unstaged #f "Unstaged changes" (%diff-files repository '()) #f))

(define (staged-section repository status)
  (%list-section git-mode:change-list-section 'staged #f "Staged changes" (%diff-files repository '("--cached")) #f))

(define (stashes-section repository status)
  (%list-section ui:section 'stashes #f "Stashes"
    (map (lambda (s) (ui:section `((type . stash) (value . ,(car s))) (list (%face "git-status.stash" (car s)) " " (cdr s))))
         (git:stashes repository))
    #f))

(define (%commit-section commit)
  (git-mode:commit-section `((type . commit) (value . ,(git:commit-name commit)))
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
        (%list-section git-mode:range-list-section 'unpushed "@{push}" (string-append "Unpushed to " push)
          (map %commit-section (%commits repository (string-append push "..HEAD") #f)) #t)
        '())))

(define (unmerged-section repository status)
  (let* ([upstream (and (git:status-head status) (git:status-upstream status))]
         [unmerged (if upstream (%commits repository (string-append upstream "..HEAD") #f) '())])
    (cond
      [(pair? unmerged)
       (%list-section git-mode:range-list-section 'unpushed "@{upstream}" (string-append "Unmerged into " upstream) (map %commit-section unmerged) #f)]
      [(git:status-head status)
       (list (apply ui:section '((type . recent) (value . #f) (hidden . #t)) "Recent commits"
                    (append (map %commit-section (%commits repository "HEAD" (commit-count))) '(""))))]
      [else '()])))

(define (unpulled-from-push-section repository status)
  (let ([push (%push-differs? repository status)])
    (if push
        (%list-section git-mode:range-list-section 'unpulled "@{push}" (string-append "Unpulled from " push)
          (map %commit-section (%commits repository (string-append "HEAD.." push) #f)) #t)
        '())))

(define (unpulled-section repository status)
  (let ([upstream (and (git:status-head status) (git:status-upstream status))])
    (if upstream
        (%list-section git-mode:range-list-section 'unpulled "@{upstream}" (string-append "Unpulled from " upstream)
          (map %commit-section (%commits repository (string-append "HEAD.." upstream) #f)) #t)
        '())))

(define (%header-datum line) (apply %header '() (append line '("\n"))))

;; The entries run in the buffer, so its own values of options such as
;; git:diff-arguments apply.
(define (%in-tasks b repository status entries)
  (let ([tasks (map (lambda (entry)
                      (call-as-owner %self (lambda () (spawn-task (lambda (restore) (buffers:with-buffer b (entry repository status)))))))
                    entries)])
    (apply append
      (map (lambda (t)
             (let-values ([(how detail) (join-task t)])
               (case how
                 [(returned) (car detail)]
                 [(raised) (raise detail)]
                 [else '()])))
           tasks))))

(define (%contents b repository)
  (let* ([status (git:status repository)]
         [header-lines (%in-tasks b repository status (hooks:entries headers))]
         [lists (%in-tasks b repository status (hooks:entries sections))])
    (append
      (if (null? header-lines)
          '()
          (list (apply ui:section '((type . headers) (value . #f)) (car header-lines)
                       (map %header-datum (cdr header-lines)))
                (%gap '() "\n")))
      lists)))

(define (%refresh! b)
  (let ([r (buffers:with-buffer b (git-mode:repository))])
    (buffers:reconcile! b (document:token (buffers:document b) 0) (%contents b r))
    (diff-sections:refine! b)))

(define (%source-of b repository)
  (lambda (container external files)
    (git:diff-with repository
                   (append (buffers:with-buffer b (git:diff-arguments)) (if (eq? (ui:section-type container) 'staged) '("--cached") '()))
                   external files)))

(define (buffer? b)
  (and (buffers:buffer? b) (buffers:live? b) (eq? (modes:major-mode b) mode)))

(define (%status-buffer repository)
  (let ([b (git-mode:buffer repository "git" mode %refresh!)])
    (buffers:with-buffer b
      (call-as-owner %self (lambda () (options:set-local! git-mode:side %side-in-status diff-sections:source (%source-of b repository)))))
    b))

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

(define (show-in-selected-view repository)
  (let ([b (%status-buffer repository)])
    (git-mode:refresh-repository repository)
    (layout:switch-to-buffer b)
    (%place-initial! (layout:selected-view) b)
    b))

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

(define (%side-in-status section view)
  (let ([side (%side (views:buffer view) section)])
    (and (memq side '(untracked unstaged staged)) side)))

(hooks:add! git-mode:repository-visitors show-in-selected-view)
(tables:set! git-mode:status-modes mode)
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
(keys:bind! keys:global "C-x g" show)
(transient:add! git-mode:dispatch-menu #f
  (transient:command "I" "Init" init))
(tables:set! web:stylesheets 'git-status "git-status/git-status.css")

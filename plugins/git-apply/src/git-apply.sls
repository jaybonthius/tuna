#!tuna
(import (git-mode) (git) (diff) (diff-sections) (ui) (buffers) (document) (views) (modes) (keys) (commands) (files)
        (ask) (transient) (web) (haml) (options) (tables) (hooks))

(options:define-option unstage-committed? #t boolean?
  "Whether u on a committed change reverses it in the index and leaves the working tree; #f raises Cannot unstage committed changes.")

(options:define-option reverse-atomically? #f boolean?
  "Whether v reverses nothing when part of the selection cannot be reversed; #f reverses what it can and leaves .rej files for the rest.")

(define (%git-view who)
  (let ([v (views:current)])
    (unless (and v (views:buffer v) (modes:derived? (modes:major-mode (views:buffer v)) git-mode:mode))
      (error who "Not in a Git buffer"))
    v))

(define (%repository-of view) (buffers:with-buffer (views:buffer view) (git-mode:repository)))

(define (%side view section) (and section (git-mode:section-side section view)))

(define (%path-bytes b file-section)
  (let ([path (document:node-attribute file-section 'path #f)])
    (or path (diff:file-path-bytes (diff-sections:file file-section b)))))

(define (%change-list? section) (memq (ui:section-type section) '(untracked unstaged staged)))

(define-record-type %selection
  (sealed #t)
  (fields side kind sections hunk first last))

(define (%of-section view section)
  (cond
    [(not section) (make-%selection #f 'none '() #f #f #f)]
    [(%change-list? section)
     (make-%selection (%side view section) 'list
                      (filter (lambda (s) (eq? (ui:section-type s) 'file)) (ui:section-children section)) #f #f #f)]
    [else
     (case (ui:section-type section)
       [(file) (make-%selection (%side view section) 'files (list section) #f #f #f)]
       [(hunk) (make-%selection (%side view section) 'hunks (list section) #f #f #f)]
       [else (make-%selection (%side view section) 'none '() #f #f #f)])]))

(define (%selection-of view section)
  (cond
    [section (%of-section view section)]
    [(ui:section-selection view)
     => (lambda (ss)
          (make-%selection (%side view (car ss)) (if (eq? (ui:section-type (car ss)) 'hunk) 'hunks 'files) ss #f #f #f))]
    [else
     (let-values ([(hunk first last) (diff-sections:selected-lines view)])
       (if hunk
           (make-%selection (%side view hunk) 'lines (list hunk) hunk first last)
           (%of-section view (ui:section-at view))))]))

(define (%buffer-arguments b) (buffers:with-buffer b (git:diff-arguments)))

(define (%context-zero? repository b)
  (or (member "-U0" (%buffer-arguments b)) (equal? (git:config repository "diff.context") "0")))

(define (%ignoring-whitespace? b)
  (exists (lambda (a) (member a '("-w" "-b" "--ignore-space-at-eol" "--ignore-blank-lines" "--ignore-all-space" "--ignore-space-change")))
          (%buffer-arguments b)))

(define (%check-context repository b who)
  (when (%context-zero? repository b)
    (error who "Not enough context to apply patch.  Increase the context")))

;; A textconv'd diff holds the filter's text, not the file's, so a patch
;; of it would not apply.
(define (%check-patchable b who)
  (when (exists (lambda (a) (member a '("--textconv" "-T"))) (%buffer-arguments b))
    (error who "This diff was made with textconv and cannot be applied")))

(define (%hunks-of sections) (map diff-sections:hunk sections))

(define (%lines-patch-file b selection)
  (diff-sections:file (%selection-hunk selection) b))

(define-record-type %place
  (sealed #t)
  (fields container path file-index hunk-index))

(define (%index-of x xs)
  (let loop ([xs xs] [i 0])
    (cond [(null? xs) #f] [(fx= (document:node-start (car xs)) (document:node-start x)) i] [else (loop (cdr xs) (fx+ i 1))])))

(define (%files-in b container)
  (filter (lambda (s) (eq? (ui:section-type s) 'file))
          (if container (ui:section-children container) (ui:top-sections b))))

(define (%place-of b selection)
  (let* ([first (and (pair? (%selection-sections selection)) (car (%selection-sections selection)))]
         [file (and first (diff-sections:file-section-of first b))]
         [container (and file (ui:section-parent file b))])
    (and file (memq (%selection-kind selection) '(files hunks lines))
         (make-%place (and container (ui:section-identity container b)) (ui:section-value file)
                      (%index-of file (%files-in b container))
                      (and (eq? (ui:section-type first) 'hunk) (%index-of first (ui:section-children file)))))))

(define (%go-to-place! view place)
  (let* ([b (views:buffer view)] [identity (%place-container place)]
         [container (and identity (ui:find-section b identity))])
    (unless (and identity (not container))
      (let* ([files (%files-in b container)]
             [same (find (lambda (f) (equal? (ui:section-value f) (%place-path place))) files)]
             [target
              (or (and (%place-hunk-index place) same
                       (let ([hunks (ui:section-children same)])
                         (and (> (length hunks) (%place-hunk-index place)) (list-ref hunks (%place-hunk-index place)))))
                  (let ([i (if (and same (%place-hunk-index place)) (+ (%index-of same files) 1) (%place-file-index place))])
                    (and i (> (length files) i) (list-ref files i)))
                  container)])
        (if target
            (views:set-point! view (ui:section-heading-start target))
            (views:set-point! view 0))))))

(define (%changed! view place)
  (when place (views:set-mark! view #f))
  (git-mode:wait-until-current (views:buffer view))
  (when (and place (buffers:live? (views:buffer view)))
    (%go-to-place! view place)))

(define (%stage-files! repository b sections)
  (let-values ([(patched added)
                (partition (lambda (s)
                             (and (%ignoring-whitespace? b) (not (document:node-attribute s 'path #f))
                                  (let ([f (diff-sections:file s b)])
                                    (not (or (diff:file-binary? f) (eq? (diff:file-status f) 'unmerged))))))
                           sections)])
    (for-each (lambda (s) (git:apply repository (diff:file-patch (diff-sections:file s b)) '("--cached" "--ignore-space-change")))
              patched)
    (unless (null? added)
      (git:stage repository (map (lambda (s) (%path-bytes b s)) added)))))

;; A commit takes everything staged, so the question is asked whatever
;; files the buffer is limited to.
(define (%stage-all! repository files all?)
  (when (pair? (git:diff repository '("--cached")))
    (git-mode:confirm (git-mode:confirmation stage-all-changes) "Stage all changes? "))
  (let ([paths (and (pair? files) files)])
    (if all? (git:stage-all repository paths) (git:stage-tracked repository paths))))

(define (%split-names answer)
  (let loop ([start 0] [i 0])
    (cond
      [(fx= i (string-length answer)) (if (fx< start i) (list (substring answer start i)) '())]
      [(char=? (string-ref answer i) #\,)
       (if (fx< start i) (cons (substring answer start i) (loop (fx+ i 1) (fx+ i 1))) (loop (fx+ i 1) (fx+ i 1)))]
      [else (loop start (fx+ i 1))])))

(define (%file-at view)
  (let* ([s (ui:section-at view)] [f (and s (diff-sections:file-section-of s (views:buffer view)))])
    (and f (ui:section-value f))))

(define (%apply-to-index! repository b selection reverse?)
  (let ([arguments (if reverse? '("--reverse" "--cached") '("--cached"))])
    (case (%selection-kind selection)
      [(hunks)
       (%check-context repository b 'git-apply:stage)
       (let ([file (diff-sections:file (car (%selection-sections selection)) b)] [hunks (%hunks-of (%selection-sections selection))])
         (git:apply repository (if reverse? (diff:reverse-hunks-patch file hunks) (diff:hunks-patch file hunks)) arguments))]
      [(lines)
       (%check-context repository b 'git-apply:stage)
       (let ([file (%lines-patch-file b selection)] [hunk (diff-sections:hunk (%selection-hunk selection))])
         (git:apply repository
                    (if reverse?
                        (diff:reverse-lines-patch file hunk (%selection-first selection) (%selection-last selection))
                        (diff:lines-patch file hunk (%selection-first selection) (%selection-last selection)))
                    arguments))])))

(define (%stage! view section intent?)
  (let* ([b (views:buffer view)] [repository (%repository-of view)])
    (git-mode:wait-until-current b)
    (let* ([selection (%selection-of view section)] [side (%selection-side selection)] [kind (%selection-kind selection)]
           [place (and (not section) (%place-of b selection))])
      (git-mode:call-with-failures-reported repository
        (lambda ()
          (cond
            [(or (eq? kind 'none) (not side)) (error 'git-apply:stage "Cannot apply this, it's not a change")]
            [(eq? side 'staged) (error 'git-apply:stage "Already staged")]
            [(eq? side 'committed) (error 'git-apply:stage "Cannot stage committed changes")]
            [(eq? side 'untracked)
             (let ([paths (map (lambda (s) (%path-bytes b s)) (%selection-sections selection))])
               (unless (null? paths)
                 (if intent? (git:stage-intent-to-add repository paths) (git:stage repository paths))))]
            [else
             (%check-patchable b 'git-apply:stage)
             (case kind
               [(list) (%stage-all! repository (%files-of view) #f)]
               [(files) (%stage-files! repository b (%selection-sections selection))]
               [else (%apply-to-index! repository b selection #f)])])
          (%changed! view place))))))

(commands:define-command (stage [intent (commands:prefix-argument)])
  "Stages the files, hunks or lines selected; with C-u, stages untracked files with --intent-to-add."
  (%stage! (%git-view 'git-apply:stage) #f (and intent #t)))

(commands:define-command (stage-files [names (%split-names (ask:line-with-candidates "Stage file,s: " (%stage-candidates) (%file-at (views:current))))])
  "Reads files, Stage file,s:, and stages them: s where no change is at point."
  (unless (and (list? names) (for-all string? names))
    (assertion-violation 'git-apply:stage-files "not a list of strings" names))
  (let ([repository (git-mode:current-repository)])
    (git-mode:call-with-failures-reported repository
      (lambda () (unless (null? names) (git:stage repository names))))))

(define (%stage-candidates)
  (let ([repository (git-mode:current-repository)])
    (append (map diff:file-path (git:diff repository '()))
            (map utf8->string (git:untracked repository #f)))))

(define (%unstage-candidates)
  (map diff:file-path (git:diff (git-mode:current-repository) '("--cached"))))

(commands:define-command (unstage-files [names (%split-names (ask:line-with-candidates "Unstage file,s: " (%unstage-candidates) (%file-at (views:current))))])
  "Reads staged files, Unstage file,s:, and unstages them: u where no change is at point."
  (unless (and (list? names) (for-all string? names))
    (assertion-violation 'git-apply:unstage-files "not a list of strings" names))
  (let ([repository (git-mode:current-repository)])
    (git-mode:call-with-failures-reported repository
      (lambda () (unless (null? names) (git:unstage repository names))))))

(define (%intent-to-add? repository file)
  (and (eq? (diff:file-status file) 'added)
       (exists (lambda (e) (and (equal? (git:entry-path-bytes e) (diff:file-path-bytes file)) (eq? (git:entry-worktree e) 'added)))
               (git:status-entries (git:status repository)))))

(define (%unstage-all! repository files)
  (when (null? (git:diff repository (if (pair? files) (append '("--cached" "--") files) '("--cached"))))
    (error 'git-apply:unstage-all "Nothing to unstage"))
  (when (or (pair? (git:diff repository '())) (pair? (git:untracked repository #f)))
    (git-mode:confirm (git-mode:confirmation unstage-all-changes) "Unstage all changes? "))
  (git:unstage repository (and (pair? files) files)))

(define (%files-of view) (buffers:with-buffer (views:buffer view) (git-mode:files)))

(define (%unstage! view section)
  (let* ([b (views:buffer view)] [repository (%repository-of view)])
    (git-mode:wait-until-current b)
    (let* ([selection (%selection-of view section)] [side (%selection-side selection)] [kind (%selection-kind selection)]
           [place (and (not section) (%place-of b selection))])
      (git-mode:call-with-failures-reported repository
        (lambda ()
          (cond
            [(or (eq? kind 'none) (not side)) (error 'git-apply:unstage "Cannot apply this, it's not a change")]
            [(eq? side 'untracked) (error 'git-apply:unstage "Cannot unstage untracked changes")]
            [(and (eq? side 'unstaged) (eq? kind 'files)
                  (for-all (lambda (s) (let ([f (diff-sections:file s b)]) (and f (%intent-to-add? repository f))))
                           (%selection-sections selection)))
             (git:unstage repository (map (lambda (s) (%path-bytes b s)) (%selection-sections selection)))]
            [(eq? side 'unstaged) (error 'git-apply:unstage "Already unstaged")]
            [(eq? side 'committed)
             (unless (unstage-committed?)
               (error 'git-apply:unstage "Cannot unstage committed changes"))
             (%check-patchable b 'git-apply:unstage)
             (if (memq kind '(list files))
                 (git:apply repository (%joined-patch (map (lambda (s) (diff-sections:file s b)) (%selection-sections selection)))
                            '("--reverse" "--cached"))
                 (%apply-to-index! repository b selection #t))]
            [else
             (%check-patchable b 'git-apply:unstage)
             (case kind
               [(list) (%unstage-all! repository (%files-of view))]
               [(files)
                (when (exists (lambda (s) (eq? (diff:file-status (diff-sections:file s b)) 'unmerged)) (%selection-sections selection))
                  (error 'git-apply:unstage "Unstaging a conflict waits for conflict resolution"))
                (git:unstage repository (map (lambda (s) (%path-bytes b s)) (%selection-sections selection)))]
               [else (%apply-to-index! repository b selection #t)])])
          (%changed! view place))))))

(commands:define-command (unstage)
  "Unstages the files, hunks or lines selected; on a committed change, reverses it in the index."
  (%unstage! (%git-view 'git-apply:unstage) #f))

(commands:define-command (stage-all [all (commands:prefix-argument)])
  "Stages every change to tracked files, and with C-u untracked files too, asking first when something is staged."
  (let* ([v (%git-view 'git-apply:stage-all)] [repository (%repository-of v)])
    (git-mode:wait-until-current (views:buffer v))
    (git-mode:call-with-failures-reported repository
      (lambda () (%stage-all! repository (%files-of v) (and all #t)) (%changed! v #f)))))

(commands:define-command (unstage-all)
  "Unstages everything, asking first when there are also unstaged or untracked changes."
  (let* ([v (%git-view 'git-apply:unstage-all)] [repository (%repository-of v)])
    (git-mode:wait-until-current (views:buffer v))
    (git-mode:call-with-failures-reported repository
      (lambda () (%unstage-all! repository (%files-of v)) (%changed! v #f)))))

(define (%quoted path) (string-append "\"" path "\""))

(define (%refuse-tilde! path)
  (when (and (fx> (string-length path) 0) (char=? (string-ref path 0) #\~))
    (error 'git-apply:discard (string-append "Refusing to delete " (%quoted path) ", too dangerous"))))

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

(define (%undo-renames! repository b renames)
  (let ([root (git:repository-root repository)])
    (git-mode:confirm (git-mode:confirmation rename)
      (if (= (length renames) 1)
          (let ([f (diff-sections:file (car renames) b)])
            (string-append "Undo rename " (diff:file-old-path f) " -> " (diff:file-new-path f) "? "))
          (format "Undo ~a renames? " (length renames))))
    (for-each
      (lambda (s)
        (let* ([f (diff-sections:file s b)] [old (diff:file-old-path f)] [new (diff:file-new-path f)])
          (if (file-exists? (string-append root new) #f)
              (let ([folder (path-parent (string-append root old))])
                (unless (file-directory? folder) (files:make-folder folder))
                (git:run repository (list "mv" "--" new old)))
              (git:unstage repository (list (%path-bytes b s) (diff:file-old-path-bytes f))))))
      renames)))

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
        (error 'git-apply:discard "Discarding a conflict waits for conflict resolution"))
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
                (fold-right (lambda (s listed) (string-append (ui:section-value s) "\n" listed)) "" delete)
                "")
            (%delete-question (length delete) (ui:section-value (car delete)))))
        (when (eq? side 'staged)
          (git:run repository (append '("rm" "--cached" "--force" "-q" "--") (map (lambda (s) (ui:section-value s)) delete))))
        (for-each (lambda (s)
                    (let ([path (string-append root (ui:section-value s))])
                      (when (or (file-exists? path #f) (file-directory? path))
                        (if (files:delete-by-moving-to-trash?) (files:move-to-trash path) (files:delete-file path)))))
                  delete)
        ;; Deleting an untracked file runs no git command, so nothing
        ;; else refreshes the repository's buffers.
        (unless (eq? side 'staged)
          (git-mode:refresh-repository repository)))
      (unless (null? rename)
        (%undo-renames! repository b rename))
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
            (error 'git-apply:discard
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

(define (%apply-discard! repository side file patch)
  (cond
    [(eq? side 'unstaged) (git:apply repository patch '("--reverse"))]
    [(%has-unstaged? repository file)
     (git:apply repository patch '("--reverse" "--cached"))
     (git:apply repository patch '("--reverse" "--reject"))]
    [else (git:apply repository patch '("--reverse" "--index"))]))

(define (%discard! view section)
  (let* ([b (views:buffer view)] [repository (%repository-of view)])
    (git-mode:wait-until-current b)
    (let* ([selection (%selection-of view section)] [side (%selection-side selection)] [kind (%selection-kind selection)]
           [place (and (not section) (%place-of b selection))])
      (git-mode:call-with-failures-reported repository
        (lambda ()
          (cond
            [(eq? side 'committed) (error 'git-apply:discard "Cannot discard committed changes")]
            [(or (eq? kind 'none) (not side)) (error 'git-apply:discard "Cannot apply this, it's not a change")]
            [(memq kind '(list files)) (%discard-files! repository b side (%selection-sections selection))]
            [(eq? kind 'hunks)
             (%check-patchable b 'git-apply:discard)
             (%check-context repository b 'git-apply:discard)
             (let* ([sections (%selection-sections selection)] [file (diff-sections:file (car sections) b)]
                    [patch (diff:reverse-hunks-patch file (%hunks-of sections))])
               (git-mode:confirm (git-mode:confirmation discard)
                 (if (= (length sections) 1) "Discard hunk? " (format "Discard ~a hunks from ~a? " (length sections) (diff:file-path file))))
               (%apply-discard! repository side file patch))]
            [(eq? kind 'lines)
             (%check-patchable b 'git-apply:discard)
             (%check-context repository b 'git-apply:discard)
             (let* ([file (%lines-patch-file b selection)]
                    [patch (diff:reverse-lines-patch file (diff-sections:hunk (%selection-hunk selection))
                                                     (%selection-first selection) (%selection-last selection))])
               (git-mode:confirm (git-mode:confirmation discard) "Discard region? ")
               (%apply-discard! repository side file patch))])
          (%changed! view place))))))

(commands:define-command (discard)
  "Discards the files, hunks or lines selected, asking first."
  (%discard! (%git-view 'git-apply:discard) #f))

(define (%selection-patch b selection reverse?)
  (let ([sections (%selection-sections selection)])
    (case (%selection-kind selection)
      [(lines)
       (let ([file (%lines-patch-file b selection)] [hunk (diff-sections:hunk (%selection-hunk selection))])
         ((if reverse? diff:reverse-lines-patch diff:lines-patch) file hunk (%selection-first selection) (%selection-last selection)))]
      [(hunks)
       (let ([file (diff-sections:file (car sections) b)])
         ((if reverse? diff:reverse-hunks-patch diff:hunks-patch) file (%hunks-of sections)))]
      [else (%joined-patch (map (lambda (s) (diff-sections:file s b)) sections))])))

(define (%apply! view section three-way?)
  (let* ([b (views:buffer view)] [repository (%repository-of view)])
    (git-mode:wait-until-current b)
    (let* ([selection (%selection-of view section)] [side (%selection-side selection)] [kind (%selection-kind selection)])
      (git-mode:call-with-failures-reported repository
        (lambda ()
          (cond
            [(or (eq? kind 'none) (not side)) (error 'git-apply:apply "Cannot apply this, it's not a change")]
            [(memq side '(unstaged staged untracked)) (error 'git-apply:apply "Change is already in the working tree")]
            [else
             (%check-patchable b 'git-apply:apply)
             (unless (memq kind '(list files))
               (%check-context repository b 'git-apply:apply))
             (git:apply repository (%selection-patch b selection #f) (if three-way? '("--3way") '()))])
          (%changed! view #f))))))

(commands:define-command (apply [three-way (commands:prefix-argument)])
  "Applies the selected change of a committed diff to the working tree; with C-u, with --3way, which stages the result too."
  (%apply! (%git-view 'git-apply:apply) #f (and three-way #t)))

(define (%reverse-question b selection)
  (let ([sections (%selection-sections selection)])
    (case (%selection-kind selection)
      [(lines) "Reverse region? "]
      [(hunks)
       (if (= (length sections) 1)
           "Reverse hunk? "
           (format "Reverse ~a hunks from ~a? " (length sections) (ui:section-value (ui:section-parent (car sections) b))))]
      [else
       (if (= (length sections) 1)
           (string-append "Reverse " (%quoted (ui:section-value (car sections))) "? ")
           (format "Reverse ~a files? " (length sections)))])))

(define (%reverse! view section three-way?)
  (let* ([b (views:buffer view)] [repository (%repository-of view)])
    (git-mode:wait-until-current b)
    (let* ([selection (%selection-of view section)] [side (%selection-side selection)] [kind (%selection-kind selection)])
      (git-mode:call-with-failures-reported repository
        (lambda ()
          (cond
            [(or (eq? kind 'none) (not side)) (error 'git-apply:reverse "Cannot apply this, it's not a change")]
            [(eq? side 'untracked) (error 'git-apply:reverse "Cannot reverse untracked changes")]
            [(eq? side 'unstaged) (error 'git-apply:reverse "Cannot reverse unstaged changes")]
            [else
             (%check-patchable b 'git-apply:reverse)
             (let-values ([(binaries selection)
                           (if (memq kind '(list files))
                               (let-values ([(binaries rest) (partition (lambda (s) (diff:file-binary? (diff-sections:file s b)))
                                                                        (%selection-sections selection))])
                                 (values binaries (make-%selection side 'files rest #f #f #f)))
                               (values '() selection))])
               (unless (null? (%selection-sections selection))
                 (unless (memq kind '(list files))
                   (%check-context repository b 'git-apply:reverse))
                 (git-mode:confirm (git-mode:confirmation reverse) (%reverse-question b selection))
                 (git:apply repository (%selection-patch b selection #t)
                            (append '("--reverse")
                                    (if three-way? '("--3way") '())
                                    (if (or three-way? (reverse-atomically?)) '() '("--reject")))))
               (unless (null? binaries)
                 (error 'git-apply:reverse "Cannot reverse binary files")))])
          (%changed! view #f))))))

(commands:define-command (reverse [three-way (commands:prefix-argument)])
  "Reverses the selected change of a staged or committed diff in the working tree, asking first; with C-u, with --3way."
  (%reverse! (%git-view 'git-apply:reverse) #f (and three-way #t)))

(define (%clicked-section who)
  (let* ([event (keys:command-event)] [posn (and (keys:event? event) (keys:event-start event))]
         [v (and posn (views:posn-view posn))] [p (and posn (views:posn-point posn))])
    (unless (and v p (views:buffer v) (modes:derived? (modes:major-mode (views:buffer v)) git-mode:mode))
      (error who "no row at the click"))
    (values v (ui:section-at v p))))

(define (%run-on-click! who action)
  (let-values ([(v s) (%clicked-section who)])
    (views:call-with-view v (lambda () (action v s)))))

(commands:define-command (stage-button)
  "Stages the row whose button was clicked."
  (%run-on-click! 'git-apply:stage-button (lambda (v s) (%stage! v s #f))))

(commands:define-command (unstage-button)
  "Unstages the row whose button was clicked."
  (%run-on-click! 'git-apply:unstage-button (lambda (v s) (%unstage! v s))))

(commands:define-command (discard-button)
  "Discards the row whose button was clicked, asking first."
  (%run-on-click! 'git-apply:discard-button (lambda (v s) (%discard! v s))))

(tables:define-table stage-button-keys "Clicks on a row's stage button.")
(tables:define-table unstage-button-keys "Clicks on a row's unstage button.")
(tables:define-table discard-button-keys "Clicks on a row's discard button.")

(define (%button keymap label title)
  (haml (:button.ui-button.git-apply-button ([type "button"] [tabindex "-1"] [title title]
                                             [data-keymap (views:keymap-mark keymap)])
          label)))

(define (%row-buttons view section)
  (let ([b (views:buffer view)])
    (and b (modes:derived? (modes:major-mode b) git-mode:mode)
         (memq (ui:section-type section) '(file hunk untracked unstaged staged))
         (let ([side (%side view section)])
           (and (memq side '(untracked unstaged staged))
                (let ([first (if (eq? side 'staged)
                                 (%button unstage-button-keys "−" "Unstage")
                                 (%button stage-button-keys "+" "Stage"))])
                  (haml (:span.git-apply-buttons first (%button discard-button-keys "⟲" "Discard")))))))))

(for-each
  (lambda (keymap command)
    (keys:bind! keymap "<mouse-1>" command)
    (keys:bind! keymap "<mouse-2>" command)
    (keys:bind! keymap "<down-mouse-1>" keys:ignore)
    (keys:bind! keymap "<drag-mouse-1>" keys:ignore)
    (keys:bind! keymap "<drag-mouse-2>" keys:ignore))
  (list stage-button-keys unstage-button-keys discard-button-keys)
  (list stage-button unstage-button discard-button))

(hooks:add! ui:section-heading-adornments %row-buttons)
(keys:bind! git-mode:keymap "s" stage-files)
(keys:bind! git-mode:keymap "u" unstage-files)
(keys:bind! git-mode:keymap "S" stage-all)
(keys:bind! git-mode:keymap "U" unstage-all)
(for-each
  (lambda (keymap)
    (keys:remap! keymap stage-files stage)
    (keys:remap! keymap unstage-files unstage)
    (keys:remap! keymap git-mode:delete-thing discard)
    (keys:bind! keymap "a" apply)
    (keys:bind! keymap "v" reverse))
  (list git-mode:file-section-keys git-mode:change-list-section-keys))
(transient:add! git-mode:dispatch-menu "Applying changes"
  (transient:command "s" "Stage" stage)
  (transient:command "u" "Unstage" unstage)
  (transient:command "k" "Discard" discard)
  (transient:command "S" "Stage all" stage-all)
  (transient:command "U" "Unstage all" unstage-all))
(transient:set-group-depth! git-mode:dispatch-menu "Applying changes" 50)
(tables:set! web:stylesheets 'git-apply "git-apply/git-apply.css")

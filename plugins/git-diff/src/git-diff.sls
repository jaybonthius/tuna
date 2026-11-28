#!tuna
(import (git-mode) (git) (diff) (diff-sections) (ui) (buffers) (document) (views) (layout) (modes) (keys)
        (commands) (transient) (status-line) (ask) (faces) (web) (haml) (hooks) (options) (tables))

(define %self (current-owner))

(define-record-type (%spec %make-spec spec?)
  (sealed #t)
  (fields kind range files))

(define (unstaged-spec) (%make-spec 'unstaged #f '()))

(define staged-spec
  (case-lambda
    [() (staged-spec #f)]
    [(revision)
     (unless (or (not revision) (string? revision))
       (assertion-violation 'git-diff:staged-spec "not a string or #f" revision))
     (%make-spec 'staged revision '())]))

(define range-spec
  (case-lambda
    [(range) (range-spec range '())]
    [(range files)
     (unless (string? range)
       (assertion-violation 'git-diff:range-spec "not a string" range))
     (unless (and (list? files) (for-all string? files))
       (assertion-violation 'git-diff:range-spec "not a list of strings" files))
     (%make-spec 'committed range files)]))

(define (%commit-spec name files) (%make-spec 'commit name files))

(define (spec=? a b)
  (unless (and (spec? a) (spec? b))
    (assertion-violation 'git-diff:spec=? "not a spec" a b))
  (and (eq? (%spec-kind a) (%spec-kind b)) (equal? (%spec-range a) (%spec-range b)) (equal? (%spec-files a) (%spec-files b))))

(define-enumeration header (author author-date commit commit-date) %headers)

(define-enumeration related-ref (parents merged contained follows precedes) %related-refs)

(define (%list-of names) (lambda (v) (and (list? v) (for-all (lambda (x) (memq x (enum-set->list (enum-set-universe names)))) v))))

(options:define-option diffstat? #t boolean? "Whether a diff or commit buffer shows the diffstat; a buffer may set it locally.")

(options:define-option revision-headers (list (header author) (header author-date) (header commit) (header commit-date))
  (%list-of (%headers)) "The header lines a commit buffer shows, values of git-diff:header.")

(options:define-option related-refs
  (list (related-ref parents) (related-ref merged) (related-ref contained) (related-ref follows) (related-ref precedes))
  (%list-of (%related-refs)) "The related-ref rows a commit buffer shows, values of git-diff:related-ref; each is a git run in a task.")

(options:define-option related-branches (git:branch-scope local)
  (lambda (v) (and (memq v '(local all mixed)) #t))
  "Which branches the merged and contained rows list, a value of git:branch-scope.")

(options:define-option %spec-of #f (lambda (v) (or (not v) (spec? v))) "A diff or commit buffer's spec, set locally.")

(options:define-option %back '() list? "The specs a buffer showed before its own, newest first, set locally.")

(options:define-option %forward '() list? "The specs a buffer showed after its own, nearest first, set locally.")

(hooks:define-hook sections "Called with a diff buffer's spec; each entry returns a list of section datums shown after the diffstat.")

(hooks:define-hook revision-sections "Called with a commit buffer's revision; each entry returns a list of section datums.")

(tables:define-table dwim-targets
  "Section types, as keys, of procedures of a section and a view that show its diff and return true, or return #f.")

(tables:define-table keymap "Keys in diff buffers.")

(hooks:define-hook mode-hook "Called in each diff buffer as its mode is set.")

(modes:define-major-mode mode
  (parent git-mode:mode)
  (lighter "Git Diff")
  (keymap keymap)
  (hook mode-hook)
  (plugin-only #t))

(tables:define-table revision-keymap "Keys in commit buffers.")

(hooks:define-hook revision-mode-hook "Called in each commit buffer as its mode is set.")

(modes:define-major-mode revision-mode
  (parent mode)
  (lighter "Git Rev")
  (keymap revision-keymap)
  (hook revision-mode-hook)
  (plugin-only #t))

(buffers:define-kind %line)

;; A buffer's own values belong to this plugin whoever asks for the diff,
;; so they outlive the module that asked.
(define (%set-local! . arguments)
  (call-as-owner %self (lambda () (apply options:set-local! arguments))))

(define (%new-side range)
  (let ([dots (%dots range)])
    (and dots
         (let ([after (substring range (fx+ (car dots) (cdr dots)) (string-length range))])
           (if (string=? after "") "HEAD" after)))))

(define (%dots range)
  (let loop ([i 0])
    (cond
      [(fx> (fx+ i 2) (string-length range)) #f]
      [(string=? (substring range i (fx+ i 2)) "..")
       (cons i (if (and (fx< (fx+ i 2) (string-length range)) (char=? (string-ref range (fx+ i 2)) #\.)) 3 2))]
      [else (loop (fx+ i 1))])))

(define (%spec-revisions spec)
  (case (%spec-kind spec)
    [(unstaged) '()]
    [(staged) (cons "--cached" (if (%spec-range spec) (list (%spec-range spec)) '()))]
    [else (list (%spec-range spec))]))

(define (%spec-arguments spec)
  (append (%spec-revisions spec) (if (null? (%spec-files spec)) '() (cons "--" (%spec-files spec)))))

(define (buffer-spec b)
  (unless (buffers:buffer? b)
    (assertion-violation 'git-diff:buffer-spec "not a buffer" b))
  (let ([spec (buffers:with-buffer b (%spec-of))])
    (and spec (not (eq? (%spec-kind spec) 'commit)) spec)))

(define (description spec)
  (unless (spec? spec)
    (assertion-violation 'git-diff:description "not a spec" spec))
  (string-append
    (case (%spec-kind spec)
      [(unstaged) "Unstaged changes"]
      [(staged) (if (%spec-range spec) (string-append "Changes from " (%spec-range spec) " to index") "Staged changes")]
      [else (if (%dots (%spec-range spec))
                (string-append "Changes in " (%spec-range spec))
                (string-append "Changes from " (%spec-range spec) " to working tree"))])
    (let ([files (%spec-files spec)])
      (cond
        [(null? files) ""]
        [(null? (cdr files)) (string-append " in file " (car files))]
        [else (string-append " in files " (fold-right (lambda (f rest) (if (string=? rest "") f (string-append f ", " rest))) "" files))]))))

(define (%revision-attributes revision) (if revision `((revision . ,revision)) '()))

(define (%file-sections files revision)
  (map (lambda (f) (diff-sections:file-section f (%revision-attributes revision) git-mode:file-section)) files))

(define (%diffstat files revision)
  (if (and (diffstat?) (pair? files))
      (list (diff-sections:diffstat-section files (%revision-attributes revision) git-mode:file-section))
      '()))

(define (%diff-contents repository spec arguments)
  (let ([files (git:diff repository (append arguments (%spec-arguments spec)))]
        [revision (and (eq? (%spec-kind spec) 'committed) (%new-side (%spec-range spec)))])
    (append
      (%diffstat files revision)
      (if (null? files) (list (%line '() "No changes\n")) '())
      (%file-sections files revision)
      (apply append (map (lambda (entry) (entry spec)) (hooks:entries sections))))))

(define (%refresh-diff! b)
  (buffers:with-buffer b
    (let ([contents (%diff-contents (git-mode:repository) (%spec-of) (git:diff-arguments))])
      (%set-local! git-mode:files (%spec-files (%spec-of)))
      (buffers:reconcile! b (document:token (buffers:document b) 0) (append contents (%history-buttons b)))))
  (diff-sections:refine! b))

(define (%side-in-diff section view)
  (let ([spec (buffers:with-buffer (views:buffer view) (%spec-of))])
    (and spec (memq (ui:section-type section) '(file hunk)) (%spec-kind spec))))

(define (%diff-source b)
  (lambda (container external files)
    (let-values ([(repository spec arguments) (buffers:with-buffer b (values (git-mode:repository) (%spec-of) (git:diff-arguments)))])
      (git:diff-with repository (append arguments (%spec-revisions spec)) external files))))

(define (%diff-buffer repository)
  (let ([b (git-mode:buffer repository "git-diff" mode %refresh-diff!)])
    (buffers:with-buffer b
      (%set-local! git-mode:side %side-in-diff diff-sections:source (%diff-source b)))
    b))

(define (%put-on-history! b now)
  (buffers:with-buffer b
    (let ([was (%spec-of)])
      (when (and was (not (spec=? was now)))
        (%set-local! %back (cons was (%back)) %forward '())))))

;; A diff git refuses leaves the buffer as it was, and a buffer made for
;; it goes, so a later refresh does not run the refused diff again.
(define (%change! b made? change!)
  (let ([was (buffers:with-buffer b (list (%spec-of) (git:diff-arguments) (%back) (%forward)))])
    (buffers:with-buffer b (change!))
    (guard (c [#t (if made?
                      (buffers:kill! b)
                      (buffers:with-buffer b
                        (apply (lambda (spec arguments back forward)
                                 (%set-local! %spec-of spec git:diff-arguments arguments %back back %forward forward))
                               was)))
                  (raise c)])
      (git-mode:refresh-buffer b))))

(define (show repository spec arguments)
  (unless (git:repository? repository)
    (assertion-violation 'git-diff:show "not a repository" repository))
  (unless (spec? spec)
    (assertion-violation 'git-diff:show "not a spec" spec))
  (unless (and (list? arguments) (for-all string? arguments))
    (assertion-violation 'git-diff:show "not a list of strings" arguments))
  (let* ([made? (not (git-mode:unlocked-buffer repository mode))]
         [b (%diff-buffer repository)])
    (%change! b made?
      (lambda ()
        (%put-on-history! b spec)
        (%set-local! %spec-of spec git:diff-arguments arguments)))
    (for-each (lambda (v) (views:set-point! v 0)) (views:showing b))
    (when (memq (%spec-kind spec) '(unstaged staged))
      (when (null? (filter (lambda (s) (eq? (ui:section-type s) 'file)) (ui:top-sections b)))
        (ask:message "No changes")))
    b))

(define (%show-selected! repository spec arguments)
  (let ([b (show repository spec arguments)])
    (layout:select! (or (layout:reuse-view b) (layout:display-buffer b)))))

(define (%files-of arguments)
  (let ([files (find (lambda (a) (and (fx>= (string-length a) 3) (string=? (substring a 0 3) "-- "))) arguments)])
    (values (if files
                (fold-right (lambda (name rest) (if (string=? name "") rest (cons name rest))) '()
                            (%split (substring files 3 (string-length files)) #\,))
                '())
            (remp (lambda (a) (eq? a files)) arguments))))

(define (%split s c)
  (let loop ([start 0] [i 0])
    (cond
      [(fx= i (string-length s)) (list (substring s start i))]
      [(char=? (string-ref s i) c) (cons (substring s start i) (loop (fx+ i 1) (fx+ i 1)))]
      [else (loop start (fx+ i 1))])))

(define (%with-files spec files) (%make-spec (%spec-kind spec) (%spec-range spec) files))

(define (%show-from-menu! spec arguments)
  (let-values ([(files arguments) (%files-of arguments)])
    (%show-selected! (git-mode:current-repository) (%with-files spec files) arguments)))

(define (%check-arguments who arguments)
  (unless (and (list? arguments) (for-all string? arguments))
    (assertion-violation who "not a list of strings" arguments)))

(define (%read-revision question)
  (ask:line-with-candidates question (git:refs (git-mode:current-repository)) #f))

(commands:define-command (unstaged [arguments (transient:arguments menu)])
  "Shows the changes in the working tree that are not staged."
  (%check-arguments 'git-diff:unstaged arguments)
  (%show-from-menu! (unstaged-spec) arguments))

(commands:define-command (staged [choose (commands:prefix-argument)] [arguments (transient:arguments menu)])
  "Shows the staged changes against HEAD; with C-u, reads a revision to show the index against."
  (%check-arguments 'git-diff:staged arguments)
  (%show-from-menu! (staged-spec (and choose (%read-revision "Diff index and commit: "))) arguments))

(commands:define-command (worktree [choose (commands:prefix-argument)] [arguments (transient:arguments menu)])
  "Shows HEAD against the working tree; with C-u, reads the revision."
  (%check-arguments 'git-diff:worktree arguments)
  (%show-from-menu! (range-spec (if choose (%read-revision "Diff working tree and commit: ") "HEAD")) arguments))

(define (%range-default view)
  (let ([s (and view (views:buffer view) (ui:section-at view))])
    (or (and s (memq (ui:section-type s) '(commit)) (ui:section-value s))
        (let ([status (git:status (git-mode:current-repository))]) (git:status-branch status)))))

(commands:define-command (range [range (ask:line-with-candidates "Diff for range: " (git:refs (git-mode:current-repository))
                                                                 (%range-default (views:current)))]
                                [arguments (transient:arguments menu)])
  "Shows the diff of RANGE, A..B or A...B as git reads them, or of a revision against the working tree."
  (unless (string? range)
    (assertion-violation 'git-diff:range "not a string" range))
  (%check-arguments 'git-diff:range arguments)
  (%show-from-menu! (range-spec range) arguments))

(define (%revision-at view)
  (let ([b (and view (views:buffer view))])
    (and b
         (let up ([s (ui:section-at view)])
           (and s (if (memq (ui:section-type s) '(commit branch tag)) (ui:section-value s) (up (ui:section-parent s b))))))))

(define (%commit-name repository revision)
  (guard (c [(git:failed-condition? c) (error 'git-diff:show-commit (string-append revision " cannot be dereferenced as a commit"))])
    (let ([out (utf8->string (git:query repository (list "rev-parse" "--verify" "-q" (string-append revision "^{commit}"))))])
      (substring out 0 (fxmax 0 (fx- (string-length out) 1))))))

(define (%commit-buffer repository)
  (let ([b (git-mode:buffer repository "git-revision" revision-mode %refresh-revision!)])
    (buffers:with-buffer b
      (%set-local! git-mode:side %side-in-revision diff-sections:source (%revision-source b)))
    b))

(define (%side-in-revision section view)
  (and (memq (ui:section-type section) '(file hunk)) 'committed))

(define (%revision-source b)
  (lambda (container external files)
    (let-values ([(repository commit arguments) (buffers:with-buffer b (values (git-mode:repository) (%spec-of) (git:diff-arguments)))])
      (git:show-with repository (%spec-range commit) arguments external files))))

(define show-revision
  (case-lambda
    [(repository revision arguments) (show-revision repository revision arguments '())]
    [(repository revision arguments files)
     (unless (git:repository? repository)
       (assertion-violation 'git-diff:show-revision "not a repository" repository))
     (unless (string? revision)
       (assertion-violation 'git-diff:show-revision "not a string" revision))
     (%check-arguments 'git-diff:show-revision arguments)
     (%check-arguments 'git-diff:show-revision files)
     (let* ([commit (%commit-spec (%commit-name repository revision) files)]
            [made? (not (git-mode:unlocked-buffer repository revision-mode))]
            [b (%commit-buffer repository)])
       (%change! b made?
         (lambda ()
           (%put-on-history! b commit)
           (%set-local! %spec-of commit git:diff-arguments arguments)))
       (for-each (lambda (v) (views:set-point! v 0)) (views:showing b))
       b)]))

(commands:define-command (show-commit [revision (or (and (not (commands:prefix-argument)) (%revision-at (views:current)))
                                                    (%read-revision "Show commit: "))]
                                      [arguments (transient:arguments menu)])
  "Shows the commit buffer of REVISION, by default the commit at point, in another view, and selects it."
  (%check-arguments 'git-diff:show-commit arguments)
  (let-values ([(files arguments) (%files-of arguments)])
    (let ([b (show-revision (git-mode:current-repository) revision arguments files)])
      (layout:select! (or (layout:reuse-view b) (layout:display-buffer b))))))

(commands:define-command (visit-commit)
  "Shows the commit at point in the commit buffer, in another view, and selects it."
  (let ([revision (%revision-at (views:current))])
    (unless revision
      (error 'git-diff:visit-commit "There is no thing at point that could be visited"))
    (let ([b (show-revision (git-mode:current-repository) revision (git:diff-arguments))])
      (layout:select! (or (layout:reuse-view b) (layout:display-buffer b))))))

(define (%show-or-scroll! who scroll)
  (let* ([v (views:current)] [repository (git-mode:current-repository)]
         [revision (or (%revision-at v) (%read-revision "Show commit: "))]
         [name (%commit-name repository revision)]
         [existing (let ([b (git-mode:unlocked-buffer repository revision-mode)])
                     (and b (pair? (views:showing b)) (equal? (%spec-range (buffers:with-buffer b (%spec-of))) name) b))])
    (if existing
        (let ([v (car (views:showing existing))])
          (guard (c [(views:scroll-limit? c)
                     (views:set-point! v (if (eq? scroll views:scroll-forward!) 0 (views:previous-stop v (document:length (buffers:document existing)))))])
            (scroll v)))
        (layout:display-buffer (show-revision repository revision (git:diff-arguments))))))

(commands:define-command (show-or-scroll-up)
  "Shows the commit at point in the commit buffer without selecting it; when that buffer already shows it, scrolls its view up a page."
  (%show-or-scroll! 'git-diff:show-or-scroll-up views:scroll-forward!))

(commands:define-command (show-or-scroll-down)
  "As git-diff:show-or-scroll-up, scrolling down."
  (%show-or-scroll! 'git-diff:show-or-scroll-down views:scroll-backward!))

(define (%list-diff section view)
  (case (ui:section-type section)
    [(unstaged) (%show-selected! (git-mode:current-repository) (unstaged-spec) (git:diff-arguments)) #t]
    [(staged) (%show-selected! (git-mode:current-repository) (staged-spec) (git:diff-arguments)) #t]
    [(unpushed) (%show-selected! (git-mode:current-repository) (range-spec (string-append (ui:section-value section) "...HEAD")) (git:diff-arguments)) #t]
    [(unpulled) (%show-selected! (git-mode:current-repository) (range-spec (string-append "HEAD..." (ui:section-value section))) (git:diff-arguments)) #t]
    [else #f]))

(commands:define-command (visit-list)
  "Shows the diff of the change list or range at point, in another view, and selects it."
  (let* ([v (views:current)] [b (views:buffer v)])
    (unless (let up ([s (ui:section-at v)]) (and s (or (%list-diff s v) (up (ui:section-parent s b)))))
      (error 'git-diff:visit-list "There is no thing at point that could be visited"))))

(define (%commit-diff section view)
  (let* ([revision (ui:section-value section)] [repository (git-mode:current-repository)]
         [parents (git:details-parents (git:commit-details repository revision))])
    (if (null? parents)
        (layout:select! (let ([b (show-revision repository revision (git:diff-arguments))]) (or (layout:reuse-view b) (layout:display-buffer b))))
        (%show-selected! repository (range-spec (string-append revision "^.." revision)) (git:diff-arguments)))
    #t))

(define (%region-commits view)
  (let ([ss (ui:section-selection view)])
    (and ss (for-all (lambda (s) (eq? (ui:section-type s) 'commit)) ss)
         (begin
           (views:set-mark! view #f)
           (%show-selected! (git-mode:current-repository)
                            (range-spec (string-append (ui:section-value (car (reverse ss))) ".." (ui:section-value (car ss))))
                            (git:diff-arguments))
           #t))))

(define (%same-again view)
  (let ([b (views:buffer view)])
    (cond
      [(eq? (modes:major-mode b) revision-mode)
       (layout:select! (or (layout:reuse-view b) (layout:display-buffer b)))
       #t]
      [(eq? (modes:major-mode b) mode)
       (%show-selected! (git-mode:current-repository) (buffers:with-buffer b (%spec-of)) (git:diff-arguments))
       #t]
      [else #f])))

(commands:define-command (dwim [arguments (transient:arguments menu)])
  "Shows the diff of the thing at point: a change list, a commit, a range list, the region's commits, this buffer's diff; else reads a range."
  (%check-arguments 'git-diff:dwim arguments)
  (let* ([v (views:current)] [b (views:buffer v)])
    (unless (or (%region-commits v)
                (%same-again v)
                (let up ([s (ui:section-at v)])
                  (and s (let ([target (tables:ref dwim-targets (ui:section-type s) #f)])
                           (or (and target (target s v)) (up (ui:section-parent s b)))))))
      (commands:run range))))

(define (%default-context repository)
  (let ([c (git:config repository "diff.context")]) (or (and c (string->number c)) 3)))

(define (%context arguments default)
  (let ([u (find (lambda (a) (and (fx> (string-length a) 2) (string=? (substring a 0 2) "-U"))) arguments)])
    (or (and u (string->number (substring u 2 (string-length u)))) default)))

(define (%set-context! n)
  (let* ([b (buffers:current)] [repository (git-mode:current-repository)] [default (%default-context repository)]
         [arguments (remp (lambda (a) (and (fx>= (string-length a) 2) (string=? (substring a 0 2) "-U"))) (git:diff-arguments))])
    (%set-local! git:diff-arguments (if (= n default) arguments (append arguments (list (string-append "-U" (number->string n))))))
    (git-mode:refresh-buffer b)))

(commands:define-command (more-context [count (commands:prefix-number)])
  "Adds COUNT lines of context to every diff of the current Git buffer."
  (%set-context! (max 0 (+ (%context (git:diff-arguments) (%default-context (git-mode:current-repository))) count))))

(commands:define-command (less-context [count (commands:prefix-number)])
  "Removes COUNT lines of context from every diff of the current Git buffer, never below none."
  (%set-context! (max 0 (- (%context (git:diff-arguments) (%default-context (git-mode:current-repository))) count))))

(commands:define-command (default-context)
  "Gives every diff of the current Git buffer the default context."
  (%set-context! (%default-context (git-mode:current-repository))))

(define (%top b type) (find (lambda (s) (eq? (ui:section-type s) type)) (ui:top-sections b)))

(define (%go! view section) (views:set-point! view (ui:section-heading-start section)))

(define (%jump-in-diff! view)
  (let* ([b (views:buffer view)] [s (ui:section-at view)] [stat (%top b 'diffstat)])
    (unless stat
      (error 'git-diff:jump "No diffstat"))
    (cond
      [(and s (eq? (ui:section-type s) 'file) (let ([p (ui:section-parent s b)]) (and p (eq? (ui:section-type p) 'diffstat))))
       (let ([f (find (lambda (t) (and (eq? (ui:section-type t) 'file) (equal? (ui:section-value t) (ui:section-value s)))) (ui:top-sections b))])
         (when f (%go! view f)))]
      [(and s (memq (ui:section-type s) '(file hunk)))
       (let* ([file (if (eq? (ui:section-type s) 'hunk) (ui:section-parent s b) s)]
              [row (find (lambda (r) (equal? (ui:section-value r) (ui:section-value file))) (ui:section-children stat))])
         (when row (ui:show-section! view stat) (%go! view row)))]
      [else (%go! view stat)])))

(commands:define-command (jump)
  "Moves point to the diffstat; on a row of it, to that file's diff; on a file or hunk, to its row. In a commit buffer away from a file, shows the jump menu."
  (let* ([v (views:current)] [b (views:buffer v)] [s (ui:section-at v)])
    (if (and (eq? (modes:major-mode b) revision-mode) (not (and s (memq (ui:section-type s) '(file hunk)))) (not (commands:prefix-argument)))
        (transient:show! jump-menu)
        (%jump-in-diff! v))))

(define (%jump-to! type)
  (let* ([v (views:current)] [s (%top (views:buffer v) type)])
    (unless s
      (error 'git-diff:jump (string-append "No " (symbol->string type))))
    (%go! v s)))

(commands:define-command (jump-to-headers) "Moves point to the commit's headers." (%jump-to! 'headers))
(commands:define-command (jump-to-message) "Moves point to the commit's message." (%jump-to! 'message))
(commands:define-command (jump-to-diffstat) "Moves point to the commit's diffstat." (%jump-to! 'diffstat))

(commands:define-command (jump-to-diff)
  "Moves point to the commit's first file."
  (let* ([v (views:current)] [s (%top (views:buffer v) 'file)])
    (unless s (error 'git-diff:jump "No diff"))
    (%go! v s)))

(transient:define-menu jump-menu "Jumping within a commit buffer." (title "Jump to"))

(define (%step! who from to empty)
  (let* ([b (buffers:current)] [items (buffers:with-buffer b (from))])
    (when (null? items)
      (error who empty))
    (%change! b #f
      (lambda ()
        (let ([now (%spec-of)])
          (if (eq? from %back)
              (%set-local! %back (cdr items) %forward (cons now (%forward)))
              (%set-local! %forward (cdr items) %back (cons now (%back))))
          (%set-local! %spec-of (car items)))))))

(commands:define-command (back)
  "Shows the diff the buffer showed before this one."
  (%step! 'git-diff:back %back %forward "No previous diff"))

(commands:define-command (forward)
  "Shows the diff the buffer showed after this one."
  (%step! 'git-diff:forward %forward %back "No next diff"))

(ui:define-button back-button back)

(ui:define-button forward-button forward)

(define (%history-buttons b)
  (let ([back? (pair? (buffers:with-buffer b (%back)))] [forward? (pair? (buffers:with-buffer b (%forward)))])
    (if (or back? forward?)
        (list (apply %line '()
                     (append (if back? (list (back-button '() "back")) '())
                             (if (and back? forward?) '(" ") '())
                             (if forward? (list (forward-button '() "forward")) '())
                             '("\n"))))
        '())))

(define (%refresh-revision! b)
  (buffers:with-buffer b
    (let* ([repository (git-mode:repository)] [revision (%spec-range (%spec-of))] [limit (%spec-files (%spec-of))]
           [arguments (git:diff-arguments)]
           [details (git:commit-details repository revision)] [files (git:show repository revision arguments limit)]
           [root (document:token (buffers:document b) 0)]
           [contents (lambda (related)
                       (append (list (%headers-section details related) (%line '() "\n") (%message-section details) (%line '() "\n"))
                               (%diffstat files revision)
                               (%file-sections files revision)
                               (apply append (map (lambda (entry) (entry revision)) (hooks:entries revision-sections)))
                               (%history-buttons b)))])
      (let ([first (contents #f)])
        (%set-local! git-mode:files limit)
        (buffers:reconcile! b root first))
      (when (exists (lambda (r) (memq r '(merged contained follows precedes))) (related-refs))
        (let ([related (git:related-refs repository revision (related-branches))])
          (buffers:reconcile! b (document:token (buffers:document b) 0) (contents related))))))
  (diff-sections:refine! b))

(define (%label text) (%styled '((face . "git-diff.header-label")) text))

(define (%draw-styled node view)
  (haml (:span ([data-face (document:node-attribute node 'face)]) (views:draw-children view node))))

(buffers:define-kind %styled (inline) (draw %draw-styled))

(define (%padded word) (string-append word (make-string (fxmax 1 (fx- 12 (string-length word))) #\space)))

(define (%headers-section details related)
  (apply ui:section '((type . headers) (value . #f))
         (append (apply append (map (lambda (r) (list r " ")) (git:details-refs details))) (list (git:details-name details)))
         (append
           (map (lambda (h)
                  (let-values ([(name value) (case h
                                               [(author) (values "Author:" (git:details-author details))]
                                               [(author-date) (values "AuthorDate:" (git:details-author-date details))]
                                               [(commit) (values "Commit:" (git:details-committer details))]
                                               [else (values "CommitDate:" (git:details-committer-date details))])])
                    (%line '() (%label (%padded name)) value "\n")))
                (revision-headers))
           (if (memq 'parents (related-refs))
               (map (lambda (p)
                      (git-mode:commit-section `((type . commit) (value . ,(git:commit-name p)))
                                               (list (%label (%padded "Parent:")) (git:commit-short-name p) " " (git:commit-subject p))))
                    (git:details-parents details))
               '())
           (if related
               (append
                 (%branches-row "Merged:" (and (memq 'merged (related-refs)) (git:related-merged related)))
                 (%branches-row "Contained:" (and (memq 'contained (related-refs)) (git:related-contained related)))
                 (%tag-row "Follows:" (and (memq 'follows (related-refs)) (git:related-follows related)))
                 (%tag-row "Precedes:" (and (memq 'precedes (related-refs)) (git:related-precedes related))))
               '()))))

(define (%branches-row label branches)
  (if (and branches (pair? branches))
      (list (apply %line '() (%label (%padded label))
                   (append (fold-right (lambda (b rest) (if (null? rest) (list b) (cons* b " " rest))) '() branches) '("\n"))))
      '()))

(define (%tag-row label tag)
  (if tag
      (list (%line '() (%label (%padded label)) (car tag) " (" (number->string (cdr tag)) ")\n"))
      '()))

(define (%message-section details)
  (let ([lines (%split (git:details-message details) #\newline)])
    (apply ui:section '((type . message) (value . #f)) (car lines) (cdr lines))))

(define (%refresh-with! files arguments)
  (%change! (buffers:current) #f
    (lambda ()
      (let ([spec (%spec-of)])
        (when (and spec (pair? files))
          (%set-local! %spec-of (%with-files spec files))))
      (%set-local! git:diff-arguments arguments))))

(commands:define-command (refresh [arguments (transient:arguments arguments-menu)])
  "Sets the buffer's diff arguments to ARGUMENTS and rebuilds it; a -- FILES among them limits a diff or commit buffer to those files."
  (%check-arguments 'git-diff:refresh arguments)
  (let-values ([(files arguments) (%files-of arguments)])
    (%refresh-with! files arguments)))

(commands:define-command (set-and-refresh [arguments (transient:arguments arguments-menu)])
  "As git-diff:refresh, and sets git:diff-arguments for the session once git accepts them."
  (%check-arguments 'git-diff:set-and-refresh arguments)
  (let-values ([(files arguments) (%files-of arguments)])
    (%refresh-with! files arguments)
    (call-as-owner %self (lambda () (options:set! git:diff-arguments arguments)))))

(commands:define-command (toggle-refiner [choose (commands:prefix-argument)])
  "Turns the buffer's refiner off, or on again; with C-u, reads which of diff-sections:refiners."
  (let ([b (buffers:current)])
    (cond
      [choose
       (%set-local! diff-sections:refiner
         (ask:choice "Refiner: " (map (lambda (e) (cons (diff-sections:refiner-name (car e)) (car e))) (tables:entries diff-sections:refiners))))]
      [(diff-sections:refiner-of b) (%set-local! diff-sections:refiner #f)]
      [else (call-as-owner %self (lambda () (options:unset-local! diff-sections:refiner)))])
    (git-mode:refresh-buffer b)))

(define (%value spec)
  (string-append
    (case (%spec-kind spec)
      [(unstaged) "unstaged"]
      [(staged) (or (%spec-range spec) "staged")]
      [else (%spec-range spec)])
    (if (null? (%spec-files spec)) "" (fold-left (lambda (value file) (string-append value " " file)) " --" (%spec-files spec)))))

(define (%locked-to repository major-mode spec)
  (find (lambda (o) (and (eq? (modes:major-mode o) major-mode) (buffers:with-buffer o (git-mode:locked?))
                         (let ([shown (buffers:with-buffer o (%spec-of))]) (and shown (spec=? shown spec)))))
        (git-mode:repository-buffers repository)))

(commands:define-command (toggle-lock)
  "Locks the buffer to what it shows, so the next diff command of its kind makes another buffer; in a locked buffer, unlocks it. When another buffer already shows it so, shows that one and kills this one."
  (let* ([b (buffers:current)] [repository (git-mode:current-repository)] [spec (%spec-of)])
    (unless (modes:derived? (modes:major-mode b) mode)
      (error 'git-diff:toggle-lock "Not a diff or commit buffer"))
    (let* ([locking? (not (git-mode:locked?))]
           [other (if locking?
                      (%locked-to repository (modes:major-mode b) spec)
                      (git-mode:unlocked-buffer repository (modes:major-mode b)))])
      (cond
        [other (layout:switch-to-buffer other) (buffers:kill! b)]
        [else
         (buffers:rename! b (git-mode:buffer-name b (and locking? (%value spec))))
         (%set-local! git-mode:locked? locking?)]))))

(commands:define-command (toggle-diffstat)
  "Shows or hides the buffer's diffstat."
  (%set-local! diffstat? (not (diffstat?)))
  (git-mode:refresh-buffer (buffers:current)))

(commands:define-command (read-layout [layout (ask:choice "Layout: " (map (lambda (l) (cons (symbol->string l) l)) '(unified split automatic)))])
  "Sets the buffer's diff-sections:layout to LAYOUT, unified, split or automatic."
  (%set-local! diff-sections:layout layout)
  (git-mode:refresh-buffer (buffers:current)))

(define (%diff-spec who)
  (let ([spec (%spec-of)])
    (unless spec
      (error who "Not in a diff buffer"))
    spec))

(options:define-option %dropped-files '() list? "The files a buffer's file filter dropped, set locally.")

(commands:define-command (toggle-file-filter)
  "Drops the buffer's -- files, or brings them back."
  (let ([spec (%diff-spec 'git-diff:toggle-file-filter)])
    (if (pair? (%spec-files spec))
        (%set-local! %dropped-files (%spec-files spec) %spec-of (%with-files spec '()))
        (%set-local! %spec-of (%with-files spec (%dropped-files)) %dropped-files '()))
    (git-mode:refresh-buffer (buffers:current))))

(define (%range-sides who spec message)
  (let* ([range (and (eq? (%spec-kind spec) 'committed) (%spec-range spec))] [dots (and range (%dots range))])
    (unless dots
      (error who message))
    (values (substring range 0 (car dots)) (cdr dots) (substring range (fx+ (car dots) (cdr dots)) (string-length range)))))

(commands:define-command (switch-range-type)
  "Turns A..B into A...B, and back."
  (let ([spec (%diff-spec 'git-diff:switch-range-type)])
    (let-values ([(a n b) (%range-sides 'git-diff:switch-range-type spec "No range to change")])
      (%change! (buffers:current) #f
        (lambda () (%set-local! %spec-of (range-spec (string-append a (if (= n 2) "..." "..") b) (%spec-files spec))))))))

(commands:define-command (flip)
  "Turns A..B into B..A."
  (let ([spec (%diff-spec 'git-diff:flip)])
    (let-values ([(a n b) (%range-sides 'git-diff:flip spec "No range to swap")])
      (%change! (buffers:current) #f
        (lambda () (%set-local! %spec-of (range-spec (string-append b (if (= n 2) ".." "...") a) (%spec-files spec))))))))

(define (%argument-entries)
  (list
    (list "Limit arguments"
          (transient:valued-switch "- -" "Limit to files" "-- " (lambda (q) (ask:line "Limit to file,s: ")))
          (transient:valued-switch "- i" "Ignore submodules" "--ignore-submodules="
                                   (lambda (q) (ask:line-with-candidates "Ignore submodules: " '("untracked" "dirty" "all"))))
          (transient:switch "- b" "Ignore whitespace changes" "--ignore-space-change")
          (transient:switch "- w" "Ignore all whitespace" "--ignore-all-space"))
    (list "Context arguments"
          (transient:valued-switch "- U" "Context lines" "-U" (lambda (q) (number->string (ask:number "Context lines: "))))
          (transient:switch "- W" "Show surrounding functions" "--function-context"))
    (list "Tune arguments"
          (transient:valued-switch "- A" "Diff algorithm" "--diff-algorithm="
                                   (lambda (q) (ask:line-with-candidates "Diff algorithm: " '("default" "myers" "minimal" "patience" "histogram"))))
          (transient:switch "- M" "Detect renames" "--find-renames")
          (transient:switch "- C" "Detect copies" "--find-copies")
          (transient:switch "- T" "Use textconv" "--textconv"))))

(transient:define-menu menu "Showing diffs." (title "Diff") (arguments git:diff-arguments))

(transient:define-menu arguments-menu "Changing a Git buffer's diff arguments." (title "Diff arguments") (arguments git:diff-arguments))

(commands:define-command (show-menu)
  "Shows the diff menu."
  (git-mode:current-repository)
  (transient:show! menu))

(commands:define-command (show-arguments-menu)
  "Shows the menu of the buffer's diff arguments."
  (git-mode:current-repository)
  (transient:show! arguments-menu))

(define (%show-description view)
  (let ([b (views:buffer view)])
    (and b (buffers:live? b)
         (cond
           [(eq? (modes:major-mode b) mode) (let ([spec (buffers:with-buffer b (%spec-of))]) (and spec (description spec)))]
           [(eq? (modes:major-mode b) revision-mode) (%value (buffers:with-buffer b (%spec-of)))]
           [else #f]))))

(status-line:define-segment heading (show %show-description))

(for-each (lambda (m) (for-each (lambda (group) (apply transient:add! m group)) (%argument-entries))) (list menu arguments-menu))
(transient:add! menu "Actions"
  (transient:command "d" "Dwim" dwim)
  (transient:command "r" "Diff range" range)
  (transient:command "u" "Diff unstaged" unstaged)
  (transient:command "s" "Diff staged" staged)
  (transient:command "w" "Diff worktree" worktree)
  (transient:command "c" "Show commit" show-commit))
(transient:add! arguments-menu "Refresh"
  (transient:command "g" "buffer" refresh)
  (transient:command "s" "buffer and set defaults" set-and-refresh))
(transient:add! arguments-menu "Toggle"
  (transient:command "t" "refiner" toggle-refiner)
  (transient:command "S" "diffstat" toggle-diffstat)
  (transient:command "L" "layout" read-layout)
  (transient:command "F" "file filter" toggle-file-filter))
(transient:add-computed! arguments-menu "Toggle"
  (lambda () (if (memq (modes:major-mode (buffers:current)) (list mode revision-mode)) (list (transient:command "b" "buffer lock" toggle-lock)) '())))
(transient:add-computed! arguments-menu "Do"
  (lambda ()
    (if (eq? (modes:major-mode (buffers:current)) mode)
        (list (transient:command "r" "switch range type" switch-range-type) (transient:command "f" "flip revisions" flip))
        '())))
(transient:add! jump-menu #f
  (transient:command "h" "Headers" jump-to-headers)
  (transient:command "m" "Message" jump-to-message)
  (transient:command "s" "Diffstat" jump-to-diffstat)
  (transient:command "d" "Diff" jump-to-diff))
(transient:add! git-mode:dispatch-menu #f (transient:command "d" "Diff" show-menu))
(keys:bind! git-mode:keymap "d" show-menu)
(keys:bind! git-mode:keymap "D" show-arguments-menu)
(keys:bind! git-mode:keymap "+" more-context)
(keys:bind! git-mode:keymap "-" less-context)
(keys:bind! git-mode:keymap "0" default-context)
(keys:bind! git-mode:keymap "SPC" show-or-scroll-up)
(keys:bind! git-mode:keymap "S-SPC" show-or-scroll-down)
(keys:bind! git-mode:keymap "DEL" show-or-scroll-down)
(keys:bind! keymap "SPC" views:scroll-up)
(keys:bind! keymap "S-SPC" views:scroll-down)
(keys:bind! keymap "DEL" views:scroll-down)
(keys:bind! keymap "j" jump)
(keys:bind! keymap "C-c C-b" back)
(keys:bind! keymap "C-c C-f" forward)
(keys:remap! git-mode:commit-section-keys git-mode:visit-thing visit-commit)
(keys:remap! git-mode:change-list-section-keys git-mode:visit-thing visit-list)
(keys:remap! git-mode:range-list-section-keys git-mode:visit-thing visit-list)
(tables:set! dwim-targets 'unstaged %list-diff)
(tables:set! dwim-targets 'staged %list-diff)
(tables:set! dwim-targets 'unpushed %list-diff)
(tables:set! dwim-targets 'unpulled %list-diff)
(tables:set! dwim-targets 'commit %commit-diff)
(tables:set! status-line:segments heading (status-line:left 55))
(tables:set! web:stylesheets 'git-diff "git-diff/git-diff.css")

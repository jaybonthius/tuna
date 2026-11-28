(import (tuna) (test) (test-user) (options) (tables) (buffers) (document) (views) (layout) (layout-split) (editing) (ui) (git) (git-mode)
        (git-status) (git-diff) (diff-sections) (transient-test) (git-status-test) (git-test repositories))

(define repo (git-status-test:fresh! "repo"))

(define status-view (git-status-test:view))

(define (press! keys) (git-status-test:press! keys))

(define (back-to-status!)
  (layout:select! status-view)
  (layout:switch-to-buffer (git-status-test:status-buffer))
  (git-status-test:settle!))

(define (diff-buffer) (buffers:find "*git-diff: repo*"))

(define (revision-buffer) (buffers:find "*git-revision: repo*"))

(define (segments) (map test-user:element-text (test-user:elements (test-user:screen) "status-line-segment")))

(define scrolled '())

(define (note-scroll direction)
  (lambda (next . arguments)
    (set! scrolled (cons (list direction (buffers:name (views:buffer (views:current)))) scrolled))))

(define scroll-up-note (note-scroll 'up))

(define scroll-down-note (note-scroll 'down))

(advice-add! views:scroll-up scroll-up-note)

(advice-add! views:scroll-down scroll-down-note)

(test "SPC on a commit row shows its commit buffer in another view, unselected, point staying; SPC again scrolls that view up, S-SPC and DEL down"
  (git-status-test:go-to-in! "Second commit" '(unpushed . "@{upstream}"))
  (let ([point (views:point status-view)])
    (press! "SPC")
    (check (eq? status-view (git-status-test:view)))
    (check-equal? point (views:point status-view))
    (check (pair? (views:showing (revision-buffer))))
    (check-equal? '() scrolled)
    (press! "SPC")
    (press! "S-SPC")
    (press! "DEL")
    (check-equal? '((up "*git-revision: repo*") (down "*git-revision: repo*") (down "*git-revision: repo*")) (reverse scrolled))
    (check (eq? status-view (git-status-test:view)))))

(define (lines-of b)
  (let loop ([cs (string->list (document:text (buffers:document b)))] [line '()] [acc '()])
    (cond
      [(null? cs) (reverse acc)]
      [(char=? (car cs) #\newline) (loop (cdr cs) '() (cons (list->string (reverse line)) acc))]
      [else (loop (cdr cs) (cons (car cs) line) acc)])))

(define asked-choices '())

(test "SPC with no revision at point asks Show commit: "
  (press! "M-<")
  (git-status-test:answer! "HEAD~2")
  (press! "SPC")
  (check-equal? '("Show commit: ") (git-status-test:take-asked!))
  (check (member "First commit" (lines-of (revision-buffer)))))

(test "D shows the arguments menu: the diff menu's argument groups, then Refresh, Toggle and Do"
  (back-to-status!)
  (press! "d u")
  (press! "D")
  (check-equal? '("Diff arguments" "Limit arguments" "Context arguments" "Tune arguments" "Refresh" "Toggle" "Do")
                (cons (car (transient-test:menu)) (map car (cdr (transient-test:menu)))))
  (check-equal? '(("g" "buffer") ("s" "buffer and set defaults")) (cdr (list-ref (transient-test:menu) 4)))
  (check-equal? '(("t" "refiner") ("S" "diffstat") ("L" "layout") ("F" "file filter") ("b" "buffer lock")) (cdr (list-ref (transient-test:menu) 5)))
  (press! "C-g"))

(test "D g sets the buffer's own diff arguments; D s sets them for the session too"
  (press! "D - b g")
  (check-equal? '(("--ignore-space-change") ()) (list (buffers:with-buffer (diff-buffer) (git:diff-arguments)) (git:diff-arguments)))
  (press! "D s")
  (check-equal? '("--ignore-space-change") (git:diff-arguments))
  (call-as-owner (module-owner '(git-diff)) (lambda () (options:unset! git:diff-arguments)))
  (press! "D - b g"))

(test "D t turns the buffer's refiner off and on again; with C-u it reads one of diff-sections:refiners by name"
  (let ([fake (diff-sections:make-refiner "fake" (lambda () #t) (lambda (request) (diff-sections:deliver! request '())))])
    (tables:set! diff-sections:refiners fake #t)
    (options:set! diff-sections:refiner fake)
    (press! "D t")
    (check-equal? #f (buffers:with-buffer (diff-buffer) (diff-sections:refiner)))
    (press! "D t")
    (check (eq? fake (buffers:with-buffer (diff-buffer) (diff-sections:refiner))))
    (options:set! ask:choice-reader (lambda (q choices) (set! asked-choices (map car choices)) (cdr (car choices))))
    (press! "D C-u t")
    (options:unset! ask:choice-reader)
    (check-equal? '("fake") asked-choices)
    (options:unset! diff-sections:refiner)
    (tables:remove! diff-sections:refiners fake)))

(test "D F drops the buffer's -- files and brings them back"
  (git-status-test:answer! "a.py,long.txt")
  (press! "D - - g")
  (check-equal? "Unstaged changes in files a.py, long.txt" (git-diff:description (git-diff:buffer-spec (diff-buffer))))
  (press! "D F")
  (check-equal? "Unstaged changes" (git-diff:description (git-diff:buffer-spec (diff-buffer))))
  (press! "D F")
  (check-equal? "Unstaged changes in files a.py, long.txt" (git-diff:description (git-diff:buffer-spec (diff-buffer))))
  (git-status-test:answer! "b.txt")
  (press! "d - - u")
  (check-equal? "Unstaged changes in file b.txt" (git-diff:description (git-diff:buffer-spec (diff-buffer)))))

(test "D L sets the layout locally, which no other buffer sees"
  (options:set! ask:choice-reader (lambda (q choices) (cdr (assoc "split" choices))))
  (press! "D L")
  (options:unset! ask:choice-reader)
  (check-equal? '(split unified) (list (buffers:with-buffer (diff-buffer) (diff-sections:layout))
                                       (buffers:with-buffer (git-status-test:status-buffer) (diff-sections:layout)))))

(test "+, - and 0 in the status buffer change its diffs' context; - and 0 there are no prefix keys"
  (back-to-status!)
  (press! "+ +")
  (check-equal? '("-U5") (buffers:with-buffer (git-status-test:status-buffer) (git:diff-arguments)))
  (press! "-")
  (check-equal? '("-U4") (buffers:with-buffer (git-status-test:status-buffer) (git:diff-arguments)))
  (press! "0")
  (check-equal? '() (buffers:with-buffer (git-status-test:status-buffer) (git:diff-arguments))))

(test "D t turns the refiner off, and on again to the one that was in effect, not the table's first"
  (let ([first (diff-sections:make-refiner "first" (lambda () #t) (lambda (request) (diff-sections:deliver! request '())))]
        [second (diff-sections:make-refiner "second" (lambda () #t) (lambda (request) (diff-sections:deliver! request '())))])
    (tables:set! diff-sections:refiners first #t)
    (tables:set! diff-sections:refiners second #t)
    (options:set! diff-sections:refiner second)
    (press! "d u")
    (press! "D t")
    (check-equal? #f (buffers:with-buffer (diff-buffer) (diff-sections:refiner)))
    (press! "D t")
    (check (eq? second (buffers:with-buffer (diff-buffer) (diff-sections:refiner))))
    (options:unset! diff-sections:refiner)
    (tables:remove! diff-sections:refiners first)
    (tables:remove! diff-sections:refiners second)))

(test "D b locks the buffer to its diff, renamed for it, so the next diff command makes another buffer; D b again unlocks it"
  (press! "d u")
  (git-status-test:answer! "HEAD~1..HEAD")
  (press! "d r")
  (let ([locked (diff-buffer)])
    (press! "D b")
    (check-equal? "*git-diff: repo*<HEAD~1..HEAD>" (buffers:name locked))
    (press! "d u")
    (let ([other (diff-buffer)])
      (check (and other (not (eq? other locked))))
      (check-equal? "Changes in HEAD~1..HEAD" (git-diff:description (git-diff:buffer-spec locked)))
      (check-equal? "Unstaged changes" (git-diff:description (git-diff:buffer-spec other)))
      (buffers:kill! other))
    (layout:switch-to-buffer locked)
    (press! "D b")
    (check-equal? "*git-diff: repo*" (buffers:name locked))
    (press! "d s")
    (check (eq? locked (diff-buffer)))))

(test "D b on a diff another buffer is already locked to shows that buffer and kills this one; the lock's name holds the diff's files"
  (press! "d u")
  (let ([first (diff-buffer)])
    (press! "D b")
    (check-equal? "*git-diff: repo*<unstaged>" (buffers:name first))
    (press! "d u")
    (let ([second (diff-buffer)])
      (check (not (eq? first second)))
      (check-equal? '() (git-status-test:press-reporting! "D b"))
      (check-equal? '(#f #t) (list (buffers:live? second) (eq? first (views:buffer (git-status-test:view))))))
    (git-status-test:answer! "a.py")
    (press! "d - - u")
    (press! "D b")
    (check-equal? "*git-diff: repo*<unstaged -- a.py>" (buffers:name (views:buffer (git-status-test:view))))
    (check (buffers:live? first))))

(test "D b in a locked buffer while another unlocked buffer of its kind exists shows that one and kills this one"
  (press! "d s")
  (let ([unlocked (find (lambda (b) (equal? "*git-diff: repo*" (buffers:name b))) (buffers:all))]
        [locked (buffers:find "*git-diff: repo*<unstaged>")])
    (layout:switch-to-buffer locked)
    (press! "D b")
    (check-equal? '(#f #t) (list (buffers:live? locked) (eq? unlocked (views:buffer (git-status-test:view)))))))

(test "D b finds a buffer locked to the same diff by its diff, not its name: a locked buffer whose diff changed keeps no claim to its old one"
  (git-status-test:answer! "HEAD~1..HEAD")
  (press! "d r")
  (press! "D b")
  (let ([first (views:buffer (git-status-test:view))])
    (press! "D f")
    (git-status-test:answer! "HEAD~1..HEAD")
    (press! "d r")
    (let ([second (views:buffer (git-status-test:view))])
      (check (not (eq? first second)))
      (press! "D b")
      (check-equal? '(#t #t #t #t) (list (buffers:live? first) (buffers:live? second)
                                        (buffers:with-buffer first (git-mode:locked?)) (buffers:with-buffer second (git-mode:locked?))))
      (git-status-test:answer! "HEAD..HEAD~1")
      (press! "d r")
      (let ([third (views:buffer (git-status-test:view))])
        (press! "D b")
        (check-equal? '(#f #t) (list (buffers:live? third) (eq? first (views:buffer (git-status-test:view)))))))))

(test "with a locked diff buffer, a diff git refuses makes no buffer, and a refresh of every Git buffer of the repository reports nothing"
  (git-status-test:answer! "HEAD~1..HEAD")
  (press! "d r")
  (press! "D b")
  (for-each buffers:kill! (filter (lambda (b) (equal? "*git-diff: repo*" (buffers:name b))) (buffers:all)))
  (check (exists (lambda (b) (buffers:with-buffer b (git-mode:locked?))) (git-mode:repository-buffers repo)))
  (git-status-test:answer! "no-such-ref")
  (check-equal? '("ambiguous argument 'no-such-ref': unknown revision or path not in the working tree.")
                (git-status-test:press-reporting-messages! "d r"))
  (check-equal? #f (buffers:find "*git-diff: repo*"))
  (back-to-status!)
  (check-equal? '() (git-status-test:press-reporting-messages! "G")))

(test "SPC at the end of the commit buffer goes back to its start, and S-SPC at its start to its end"
  (let* ([limit (test-user:open-client (lambda (name value) (if (equal? name "views-page") '(("limit" . #t)) 'null)))])
    (advice-remove! views:scroll-up scroll-up-note)
    (advice-remove! views:scroll-down scroll-down-note)
    (back-to-status!)
    (git-status-test:go-to-in! "Second commit" '(unpushed . "@{upstream}"))
    (press! "SPC")
    (let ([v (car (views:showing (revision-buffer)))])
      (views:set-point! v 20)
      (set! scrolled '())
      (test-user:press! limit "SPC")
      (git-status-test:settle!)
      (check (<= (views:point v) (ui:section-heading-start (car (ui:top-sections (revision-buffer))))))
      (test-user:press! limit "S-SPC")
      (git-status-test:settle!)
      (check-equal? (views:previous-stop v (document:length (buffers:document (revision-buffer)))) (views:point v)))))

(test "D in the status buffer or a commit buffer offers no Do group and no buffer lock"
  (back-to-status!)
  (press! "D")
  (check (not (assoc "Do" (cdr (transient-test:menu)))))
  (check (not (member '("b" "buffer lock") (cdr (assoc "Toggle" (cdr (transient-test:menu)))))))
  (press! "C-g")
  (git-diff:show-revision repo "HEAD" '())
  (layout:switch-to-buffer (revision-buffer))
  (press! "D")
  (check (not (assoc "Do" (cdr (transient-test:menu)))))
  (check (member '("b" "buffer lock") (cdr (assoc "Toggle" (cdr (transient-test:menu))))))
  (press! "C-g"))

(test "D r on a range with no merge base is refused and leaves the buffer's diff as it was"
  (back-to-status!)
  (let ([orphan (let ([out (git-status-test:git-out "repo" "commit-tree" "-m" "alone" "4b825dc642cb6eb9a060e54bf8d69288fbee4904")])
                  (substring out 0 (- (string-length out) 1)))])
    (git-status-test:answer! (string-append "HEAD.." orphan))
    (press! "d r")
    (check-equal? (list (string-append "Changes in HEAD.." orphan)) (filter (lambda (s) (git-status-test:contains? s "Changes in")) (segments)))
    (check (pair? (git-status-test:press-reporting-messages! "D r")))
    (check-equal? (string-append "Changes in HEAD.." orphan) (git-diff:description (git-diff:buffer-spec (diff-buffer))))
    (check-equal? '() (git-status-test:press-reporting-messages! "G"))))

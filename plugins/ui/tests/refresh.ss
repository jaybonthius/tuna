(import (tuna) (test) (test-user) (layout) (views) (buffers) (document) (modes) (tables) (editing) (ui) (ui-test) (ui-test status))

(define view ui-test:view)
(define visible ui-test:visible)
(define status-datum ui-test/status:status-datum)
(define hunk ui-test/status:hunk)
(define file ui-test/status:file)

(define (untracked . names)
  (apply ui:section '((type . untracked)) (format "Untracked files (~a)" (length names))
         (map (lambda (name) (ui:section `((type . file) (value . ,name)) name)) names)))

(define (changes type heading . paths)
  (apply ui:section `((type . ,type)) (format "~a (~a)" heading (length paths))
         (map (lambda (path) (file path (hunk (string-append "@@ " path " @@") (string-append "+" path)))) paths)))

(tables:set! ui:section-initial-visibility 'untracked 'hide)

(define r (buffers:make "*refresh*" (status-datum (untracked "n1" "n2" "n3") (changes 'unstaged "Unstaged changes" "a" "b" "c"))))
(buffers:set-silent! r #t)
(modes:set-major-mode ui:section-mode r)
(ui-test:show! r)

(define q (view))

(define (refresh! . sections) (buffers:reconcile! r (document:token (buffers:document r) 0) (cddr (apply status-datum sections))))
(define (hidden? . identity) (ui:section-hidden? q (ui:find-section r identity)))
(define (toggle! . identity)
  (views:set-point! q (ui:section-heading-start (ui:find-section r identity)))
  (test-user:press! "TAB"))

(test "a refresh keeps a hidden section hidden when its heading and first child change together"
  (test-user:settle)
  (check-equal? '("Head:     main Second commit" "Untracked files (3)…" "Unstaged changes (3)" "modified   a" "@@ a @@" "+a" "modified   b"
                  "@@ b @@" "+b" "modified   c" "@@ c @@" "+c")
                (visible q))
  (refresh! (untracked "n2" "n3") (changes 'unstaged "Unstaged changes" "a" "b" "c"))
  (check (hidden? '(untracked . #f)))
  (check (member "Untracked files (2)…" (visible q)))
  (toggle! '(untracked . #f))
  (check-equal? '("Head:     main Second commit" "Untracked files (2)" "n2" "n3") (list-head (visible q) 4)))

(test "staging the first file of a hidden section keeps it hidden"
  (toggle! '(unstaged . #f))
  (refresh! (untracked "n2" "n3") (changes 'unstaged "Unstaged changes" "b" "c") (changes 'staged "Staged changes" "a"))
  (check-equal? (list #t '("Head:     main Second commit" "Untracked files (2)" "n2" "n3" "Unstaged changes (2)…" "Staged changes (1)"
                           "modified   a" "@@ a @@" "+a"))
                (list (hidden? '(unstaged . #f)) (visible q)))
  (toggle! '(unstaged . #f))
  (check (member "modified   b" (visible q))))

(test "a file added last to a hidden section stays hidden with it"
  (toggle! '(unstaged . #f))
  (refresh! (untracked "n2" "n3") (changes 'unstaged "Unstaged changes" "b" "c" "d") (changes 'staged "Staged changes" "a"))
  (check (hidden? '(unstaged . #f)))
  (toggle! '(unstaged . #f))
  (check (member "modified   d" (visible q))))

(test "a hidden file moved among its siblings stays hidden"
  (toggle! '(file . "c") '(unstaged . #f))
  (refresh! (untracked "n2" "n3") (changes 'unstaged "Unstaged changes" "b" "d" "c"))
  (check-equal? (list #t "modified   c…") (list (hidden? '(file . "c") '(unstaged . #f)) (car (last-pair (visible q)))))
  (refresh! (untracked "n2" "n3") (changes 'unstaged "Unstaged changes" "c" "b" "d"))
  (check (hidden? '(file . "c") '(unstaged . #f)))
  (check (member "modified   c…" (visible q))))

(test "a hidden file that goes and comes back is hidden again, and showing its parent gives each child the visibility it had"
  (refresh! (untracked "n2" "n3") (changes 'unstaged "Unstaged changes" "b" "d"))
  (refresh! (untracked "n2" "n3") (changes 'unstaged "Unstaged changes" "b" "c" "d"))
  (check (hidden? '(file . "c") '(unstaged . #f)))
  (toggle! '(unstaged . #f))
  (toggle! '(unstaged . #f))
  (check-equal? '("Head:     main Second commit" "Untracked files (2)" "n2" "n3" "Unstaged changes (3)" "modified   b" "@@ b @@" "+b"
                  "modified   c…" "modified   d" "@@ d @@" "+d")
                (visible q)))

(test "a view that shows another buffer while a refresh runs repairs its folds when it shows the buffer again"
  (toggle! '(untracked . #f))
  (views:set-buffer! q (buffers:make "elsewhere" ""))
  (refresh! (untracked "n3") (changes 'unstaged "Unstaged changes" "b" "c" "d"))
  (views:set-buffer! q r)
  (check (hidden? '(untracked . #f)))
  (toggle! '(untracked . #f))
  (check-equal? '("Head:     main Second commit" "Untracked files (1)" "n3" "Unstaged changes (3)" "modified   b" "@@ b @@" "+b"
                  "modified   c…" "modified   d" "@@ d @@" "+d")
                (visible q)))

(test "a section with no body draws no chevron; hiding it folds nothing, so neither the fold's ellipsis nor the heading's is drawn"
  (let ([e (buffers:make "*empty*" (status-datum (ui:section '((type . recent)) "Recent commits"
                                                   (ui:section '((type . commit) (value . "abc")) "abc First")
                                                   (ui:section '((type . commit) (value . "def")) "def Second"))))])
    (modes:set-major-mode ui:section-mode e)
    (views:set-buffer! q e)
    (let ([count (lambda (class) (length (ui-test:elements q class)))])
      (check-equal? '(1 0) (list (count "ui-section-chevron") (count "ui-section-ellipsis")))
      (ui:hide-section! q (ui:find-section e '((commit . "abc") (recent . #f))))
      (check-equal? (list '() 1 0) (list (views:folds-at q (ui:section-heading-start (ui:find-section e '((commit . "abc") (recent . #f)))))
                                         (count "ui-section-chevron") (count "ui-section-ellipsis")))
      (ui:hide-section! q (ui:find-section e '((recent . #f))))
      (check-equal? '("▸" 1) (list (test-user:element-text (car (ui-test:elements q "ui-section-chevron"))) (count "ui-section-ellipsis"))))))

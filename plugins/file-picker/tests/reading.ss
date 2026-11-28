(import (tuna) (test) (test-user) (options) (hooks) (tables) (keys) (commands) (kill-ring) (faces) (views) (layout)
        (files) (ask) (minibuffer) (completion) (completion-list) (completion-annotations) (file-picker)
        (completion-test sessions) (minibuffer-test reading) (completion-test picking) (file-picker-test tree))

(define (home-relative path)
  (let ([home (getenv "HOME")])
    (substring path (string-length home) (string-length path))))

(define (choices) (completion-test/picking:choices))

(define (read-from directory)
  (minibuffer-test/reading:start! (lambda () (file-picker:read-file-name "File: " directory))))

(define (answer r) (home-relative (minibuffer-test/reading:result r)))

(define (quit-read! r)
  (test-user:press! "C-g")
  (check-raises cancelled? (minibuffer-test/reading:result r)))

(define (shown-path) (files:path (views:buffer (layout:selected-view))))

(test "C-x C-f reads a name from the home folder for a buffer that visits no file, written ~, listing its folders with a / and every file"
  (test-user:show! "|")
  (test-user:press! "C-x C-f")
  (check-equal? "~/" (minibuffer-test/reading:input))
  (test-user:type! "src/")
  (check-equal? '(".hidden" "blob.bin" "link.txt" "text.txt") (choices))
  (test-user:type! "te")
  (choices)
  (completion-test/picking:press-until-ended! "RET" file-picker:find-file)
  (check-equal? (file-picker-test/tree:path "src/text.txt") (shown-path)))

(test "the read starts from the folder of the current buffer's file, and takes a path that does not exist, with ~ expanded"
  (let ([r (minibuffer-test/reading:start! (lambda () (file-picker:read-file-name "File: ")))])
    (check-equal? "~/src/" (minibuffer-test/reading:input))
    (test-user:type! "new.txt")
    (choices)
    (test-user:press! "RET")
    (check-equal? "/src/new.txt" (answer r))
    (check-equal? '("~/src/new.txt" "~/src/text.txt") (list-head (file-picker:file-name-history) 2))))

(test "C-x C-f asks through ask:file-name, so a reader set in place of file-picker's answers it"
  (check (eq? file-picker:read-file-name (ask:file-name-reader)))
  (let ([asked '()])
    (options:set! ask:file-name-reader (lambda (question) (set! asked (cons question asked)) "~/src/text.txt"))
    (test-user:show! "|")
    (completion-test/picking:press-until-ended! "C-x C-f" file-picker:find-file)
    (check-equal? (list '("Find file: ") (file-picker-test/tree:path "src/text.txt")) (list asked (shown-path)))
    (options:unset! ask:file-name-reader)))

(test "a folder part that does not exist is expanded component by component, and choosing replaces the rest"
  (let ([r (read-from "~/")])
    (test-user:type! "c/t/m")
    (check-equal? '("code/tuna/main.sls") (choices))
    (test-user:press! "RET")
    (check-equal? "/code/tuna/main.sls" (answer r)))
  (let ([r (read-from "~/")])
    (test-user:type! "n/s")
    (check-equal? '("notes/sub/") (choices))
    (test-user:press! "TAB")
    (check-equal? "~/notes/sub/" (minibuffer-test/reading:input))
    (check-equal? '("b.sls") (choices))
    (quit-read! r)))

(test "at a folder's name no entry is selected, so RET answers the folder; C-n selects its first entry, and typing a name the first match; the read is not busy and the file read before sorts first"
  (let ([r (read-from "~/src/")])
    (check-equal? '("text.txt" ".hidden" "blob.bin" "link.txt") (choices))
    (check-equal? (list "~/src/" #f #f)
                  (list (minibuffer-test/reading:input) (completion-test/picking:selected) (completion:session-busy? (completion-test/picking:session))))
    (test-user:press! "C-n")
    (check-equal? "text.txt" (completion-test/picking:selected))
    (test-user:type! "te")
    (choices)
    (check-equal? "text.txt" (completion-test/picking:selected))
    (quit-read! r))
  (let ([r (read-from "~/src/")])
    (choices)
    (test-user:press! "RET")
    (check-equal? "/src/" (answer r))))

(define (discarded-drawn)
  (map test-user:element-text
       (filter (lambda (e) (equal? (symbol->string file-picker:discarded) (test-user:element-attribute e "data-face")))
               (apply append
                      (map (lambda (shadow) (test-user:elements-with shadow "data-face"))
                           (filter (lambda (e) (equal? (symbol->string faces:shadow) (test-user:element-attribute e "data-face")))
                                   (test-user:elements-with (test-user:screen) "data-face")))))))

(test "a ~/ or // after a folder starts the name again: the listing, the answer and the history come from the restarted name, and the discarded part is drawn dimmed in its own face"
  (let ([r (read-from "~/notes/")])
    (check-equal? '() (discarded-drawn))
    (test-user:type! "~/src/")
    (check-equal? (list "~/notes/~/src/" '(".hidden" "blob.bin" "link.txt" "text.txt")) (list (minibuffer-test/reading:input) (choices)))
    (check-equal? '("~/notes/") (discarded-drawn))
    (test-user:type! "te")
    (choices)
    (test-user:press! "RET")
    (check-equal? "/src/text.txt" (answer r))
    (check-equal? "~/src/text.txt" (car (file-picker:file-name-history))))
  (let ([r (read-from "~/notes/")])
    (test-user:type! "/")
    (check (member "tmp/" (choices)))
    (check-equal? (list "~/notes//" '("~/notes/")) (list (minibuffer-test/reading:input) (discarded-drawn)))
    (test-user:press! "DEL")
    (check-equal? '() (discarded-drawn))
    (quit-read! r)))

(test "file-picker:substitute-file-name keeps the part after the last / that a ~ alone or another / follows"
  (check-equal? '("~/b" "/c" "/a/~x/c" "~/notes/")
                (map file-picker:substitute-file-name '("~/a/~/b" "/a//b//c" "/a/~x/c" "~/notes/")))
  (check-raises assertion-violation? (file-picker:substitute-file-name 'p)))

(test "file-picker:file-name-prompt? tells the reader's prompts, so the page's after-command entry deletes the discarded part"
  (let ([tidy (lambda (command)
                (let ([p (minibuffer:current-prompt)])
                  (when (and p (file-picker:file-name-prompt? p))
                    (let* ([input (minibuffer:input p)] [kept (file-picker:substitute-file-name input)])
                      (unless (string=? kept input)
                        (minibuffer:set-input! p kept))))))])
    (hooks:add! commands:after-command tidy)
    (let ([r (read-from "~/notes/")])
      (test-user:type! "~/")
      (check-equal? (list "~/" '()) (list (minibuffer-test/reading:input) (discarded-drawn)))
      (quit-read! r))
    (hooks:remove! commands:after-command tidy))
  (let ([r (minibuffer-test/reading:start! (lambda () (minibuffer:read "Name: ")))])
    (check-equal? #f (file-picker:file-name-prompt? (minibuffer-test/reading:prompt)))
    (test-user:type! "a//b")
    (check-equal? '() (discarded-drawn))
    (quit-read! r))
  (check-raises assertion-violation? (file-picker:file-name-prompt? 'p)))

(test "each entry carries its size and time, read in the job, which completion-annotations shows"
  (let ([r (read-from "~/notes/")])
    (choices)
    (let* ([s (completion-test/picking:session)]
           [a (find (lambda (m) (string=? "a.txt" (completion:text s m))) (completion-test/sessions:matches s))]
           [columns (map cdr (completion:annotation s a))])
      (check-equal? "38" (car columns))
      (check-equal? " ago" (let ([age (cadr columns)]) (substring age (- (string-length age) 4) (string-length age)))))
    (quit-read! r)))

(test "a link to a folder is listed as a folder, a link to a file as a file"
  (file-picker-test/tree:link! (file-picker-test/tree:path "notes/sub") "notes/sublink")
  (file-picker-test/tree:link! (file-picker-test/tree:path "notes/a.txt") "notes/alink")
  (let ([r (read-from "~/notes/")])
    (check-equal? '("sub/" "a.txt" "alink" "sublink/")
                  (filter (lambda (text) (member text '("sub/" "sublink/" "alink" "a.txt"))) (choices)))
    (quit-read! r)))

(test "M-w copies a file's whole path as typed"
  (let ([r (read-from "~/src/")])
    (test-user:type! "te")
    (choices)
    (test-user:press! "M-w")
    (check-equal? "~/src/text.txt" (kill-ring:text (kill-ring:current)))
    (quit-read! r)))

(test "files try partial before completion:styles, which still finds what partial misses"
  (check (equal? (list completion:partial) (tables:ref completion:category-styles completion:file-category #f)))
  (options:set! completion:styles (list completion:flex))
  (let ([r (read-from "~/src/")])
    (test-user:type! "tet")
    (check-equal? '("text.txt") (choices))
    (quit-read! r))
  (options:unset! completion:styles))

(test "C-x 4 f visits the file chosen in another view, which it selects"
  (test-user:show! "|")
  (let ([first (layout:selected-view)])
    (test-user:press! "C-x 4 f")
    (test-user:press! "C-a C-k")
    (test-user:type! "~/notes/a.txt")
    (choices)
    (completion-test/picking:press-until-ended! "RET" file-picker:find-file-other-view)
    (check (not (eq? first (layout:selected-view))))
    (check-equal? (file-picker-test/tree:path "notes/a.txt") (shown-path))
    (test-user:press! "C-x 0")))

(test "C-x C-f on a folder raises is a folder"
  (check-raises (lambda (c) (and (message-condition? c) (string=? "is a folder" (condition-message c))))
                (file-picker:find-file (file-picker-test/tree:path "src"))))

(test "file-picker:read-file-name raises on a folder that is no string"
  (check-raises assertion-violation? (file-picker:read-file-name "File: " 'home)))

(test "a quit of C-x C-f leaves the shown buffer as it was"
  (let ([before (views:buffer (layout:selected-view))])
    (test-user:press! "C-x C-f")
    (test-user:type! "ab")
    (check-equal? '(cancelled) (completion-test/picking:quit!))
    (check-equal? (list #f #t) (list (minibuffer:current-prompt) (eq? before (views:buffer (layout:selected-view)))))))

(test "f finds a file chosen in any read of file names"
  (check (eq? file-picker:find-file (keys:lookup-in (list completion:file-action-keymap) "f"))))

(import (tuna) (test) (test-user) (options) (modes) (buffers) (views) (layout) (layout-split) (editing) (files) (ui) (git)
        (git-mode) (git-status) (git-status-test) (git-test repositories))

(define repo (git-status-test:sample! "repo"))

(define (commit-line name)
  (let ([c (car (git:commits repo "HEAD" 1))]) (string-append (git:commit-short-name c) " " name)))

(define a-py (files:visit (git-status-test:path "repo/a.py")))

(layout:switch-to-buffer a-py)

(define file-view (git-status-test:view))

(test "C-x g in a file of a repository shows *git: NAME* in another view, selects it, and puts point on the first section after the headers"
  (git-status-test:press! "C-x g")
  (check-equal? '("*git: repo*" #f "Untracked files (1)")
    (list (git-status-test:shown-buffer) (eq? file-view (git-status-test:view)) (git-status-test:point-line)))
  (check-equal? "a.py" (buffers:name (views:buffer file-view))))

(test "the headers, then the sections in Magit's order, each only when it holds something; untracked files and the files of the change lists start hidden"
  (check-equal? (list "Head:     main Second commit" "Merge:    origin/main First commit" "Untracked files (1)…"
                      "Unstaged changes (3)" "modified   a.py…" "modified   b.txt…" "deleted    gone.txt…" "Staged changes (1)"
                      "modified   b.txt…" "Unmerged into origin/main (1)" (commit-line "main Second commit"))
                (git-status-test:status)))

(test "a commit line is its abbreviated hash, the refs pointing at it and its summary, a section of type commit"
  (git-status-test:go-to! (commit-line "main"))
  (let ([s (ui:section-at (git-status-test:view))])
    (check-equal? (list 'commit (git:commit-name (car (git:commits repo "HEAD" 1)))) (list (ui:section-type s) (ui:section-value s)))))

(test "the status buffer's mode derives from git-mode:mode, from ui:section-mode, from modes:special; it is read-only"
  (let ([b (git-status-test:status-buffer)])
    (check-equal? '(git-status:mode git-mode:mode ui:section-mode modes:special) (modes:ancestry (modes:major-mode b)))
    (check-equal? "Git" (modes:lighter git-status:mode))
    (check (git-status:buffer? b))
    (check (not (git-status:buffer? a-py)))
    (check-raises error? (buffers:insert! b 3 "x"))))

(test "C-x g where the status buffer is shown selects that view and refreshes, making no new view"
  (layout:select! file-view)
  (git-test/repositories:write-file! "repo/c.txt" "c\n")
  (let ([views (length (layout:views))])
    (git-status-test:press! "C-x g")
    (check-equal? (list "*git: repo*" views) (list (git-status-test:shown-buffer) (length (layout:views))))
    (check (member "Untracked files (2)…" (git-status-test:status)))))

(test "C-x g with a modified buffer of the repository asks to save it first, through files' question"
  (delete-file (git-status-test:path "repo/c.txt"))
  (layout:select! file-view)
  (buffers:insert! a-py 1 "zero\n")
  (git-status-test:answer! #t)
  (git-status-test:press! "C-x g")
  (check-equal? '("Save file ~/repo/a.py? ") (git-status-test:take-asked!))
  (check (not (buffers:modified? a-py)))
  (check-equal? "zero\none\nTWO\nthree\nfour\nfive\nsix\nseven\neight\nNINE\nten\neleven\n" (git-status-test:read-file "repo/a.py")))

(test "C-x g outside any repository reads one; a folder that is none is offered git init, and n does nothing"
  (for-each (lambda (f) (mkdir (git-status-test:path f))) '("plain" "other"))
  (layout:switch-to-buffer (files:visit (git-status-test:path "plain/notes.txt")))
  (git-status-test:answer! (git-status-test:path "other") #f)
  (git-status-test:press! "C-x g")
  (check-equal? (list "Git repository: " (string-append "Create repository in " (git-status-test:path "other/") "? "))
                (git-status-test:take-asked!))
  (check-equal? '("notes.txt" #f) (list (git-status-test:shown-buffer) (file-directory? (git-status-test:path "other/.git")))))

(test "y makes the repository and shows it; a repository with no commit shows Magit's words for the summary"
  (git-status-test:answer! (git-status-test:path "plain") #t)
  (git-status-test:press! "C-x g")
  (git-status-test:take-asked!)
  (check-equal? "*git: plain*" (git-status-test:shown-buffer))
  (let ([branch (git:status-branch (git:status (git:find-repository (git-status-test:path "plain"))))])
    (check-equal? (list (string-append "Head:     " branch " In the beginning there was darkness")) (git-status-test:status))))

(test "C-u C-x g inside a repository reads one; C-u C-u C-x g reads any folder, offering git init"
  (git-status-test:answer! (git-status-test:path "repo"))
  (git-status-test:press! "C-u C-x g")
  (check-equal? '(("Git repository: ") "*git: repo*") (list (git-status-test:take-asked!) (git-status-test:shown-buffer)))
  (git-status-test:answer! (git-status-test:path "other") #t)
  (git-status-test:press! "C-u C-u C-x g")
  (check-equal? (list (list "Git repository: " (string-append "Create repository in " (git-status-test:path "other/") "? ")) "*git: other*" #t)
                (list (git-status-test:take-asked!) (git-status-test:shown-buffer) (file-directory? (git-status-test:path "other/.git")))))

(define (opened-at)
  (for-each buffers:kill! (filter git-status:buffer? (buffers:all)))
  (layout:switch-to-buffer a-py)
  (git-status-test:press! "C-x g")
  (git-status-test:point-line))

(test "git-status:initial-section chooses where point starts: the Nth section, the first of some identities, or the first line"
  (options:set! git-status:initial-section 2)
  (check-equal? "Unstaged changes (3)" (opened-at))
  (options:set! git-status:initial-section '(((staged . #f))))
  (check-equal? "Staged changes (1)" (opened-at))
  (options:set! git-status:initial-section #f)
  (check-equal? "Head:     main Second commit" (opened-at))
  (options:unset! git-status:initial-section))

(test "C-x g where git cannot run raises, rather than reading a folder"
  (layout:switch-to-buffer a-py)
  (options:set! git:program "no-such-git")
  (let ([reported (git-status-test:press-reporting! "C-x g")])
    (options:unset! git:program)
    (check-equal? '(spawn-process) (map car reported))
    (check-equal? '() (git-status-test:take-asked!))))

(test "I in the dispatch menu reads a folder; for a repository's root or a folder inside one it asks first, n raising Abort; y or a new folder makes the repository and shows it"
  (layout:switch-to-buffer (buffers:find "*git: repo*"))
  (git-status-test:answer! (git-status-test:path "repo/sub") #f)
  (check-equal? '((git-status:init "Abort")) (git-status-test:press-reporting! "? I"))
  (check-equal? (list (list "Create repository in: "
                            (string-append (git-status-test:path "repo/") " is a repository.  Create another in "
                                           (git-status-test:path "repo/sub/") "? "))
                      #f)
                (list (git-status-test:take-asked!) (file-directory? (git-status-test:path "repo/sub"))))
  (git-status-test:answer! (git-status-test:path "repo/") #f)
  (check-equal? '((git-status:init "Abort")) (git-status-test:press-reporting! "? I"))
  (check-equal? (list "Create repository in: " (string-append "Reinitialize existing repository " (git-status-test:path "repo/") "? "))
                (git-status-test:take-asked!))
  (git-status-test:answer! (git-status-test:path "fresh"))
  (git-status-test:press! "? I")
  (check-equal? '(("Create repository in: ") "*git: fresh*" #t)
                (list (git-status-test:take-asked!) (git-status-test:shown-buffer) (file-directory? (git-status-test:path "fresh/.git")))))

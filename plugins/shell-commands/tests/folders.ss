(import (tuna) (test) (test-runner) (test-user) (options) (buffers) (views) (layout) (commands) (files) (processes)
        (projects) (completion) (command-picker) (grep) (runs) (shell-commands) (shell-commands-test))

(define ended shell-commands-test:ended)

(define home-path shell-commands-test:home-path)

(define (session) (views:call-with-view (layout:selected-view) completion:current-session))

(define (texts s)
  (let ([ms (completion:session-matches s)])
    (map (lambda (k) (completion:text s (completion:matches-ref ms k))) (iota (completion:matches-count ms)))))

;; M-s r's matches come from rg in a job, after the key has returned.
(define (grep-texts! text)
  (test-user:press! "M-s r")
  (test-user:type! text)
  (test-runner:wait-until (lambda () (let ([s (session)]) (and s (not (completion:session-busy? s)) (pair? (texts s))))))
  (let ([found (texts (session))])
    (check (for-all cancelled? (test-runner:reports-during (lambda () (test-user:press! "C-g")))))
    found))

(for-each shell-commands-test:folder! '("src" "src/x" "proj" "proj/sub"))
(shell-commands-test:write-file! "src/x/notes.txt" "a needle here\n")

(define in-src (runs:start-for-user "*src*" "true" (processes:options [directory "~/src/x/"])))

(commands:define-command (project-compile)
  "Runs compile in the current project's root, or in the buffer's folder outside a project, in a buffer of that folder's own."
  (let* ([folder (files:directory (buffers:current))]
         [project (projects:find folder)]
         [root (if project (projects:root project) folder)])
    (options:with ([files:directory-override (cons (buffers:current) root)]
                   [shell-commands:compile-buffer-name (lambda () (string-append "*compilation " root "*"))])
      (commands:run shell-commands:compile))))

(define (compile-from! b)
  (layout:switch-to-buffer b)
  (test-user:press! "M-x")
  (test-user:type! "project-compile")
  (test-user:press! "RET C-a C-k")
  (test-user:type! "pwd")
  (test-user:press! "RET"))

(define (built root)
  (let ([b (buffers:find (string-append "*compilation " root "*"))])
    (ended b)
    (shell-commands-test:output b)))

(test "a run records its folder absolute, so files:directory has the form projects:find takes; the header shows it with ~"
  (ended in-src)
  (check-equal? (list (home-path "src/x/") "~/src/x/" #f)
                (list (files:directory in-src) (shell-commands-test:header-folder in-src) (projects:find (files:directory in-src))))
  (let ([relative (runs:start-for-user "*relative*" "pwd" (processes:options [directory "."]))])
    (ended relative)
    (check-equal? (string-append (current-directory) "/") (files:directory relative))))

(test "a ~user folder is refused and leaves no buffer"
  (check-raises (test-runner:raised-with 'files:expanded-path "a path starting with ~user")
                (runs:start-for-user "*user*" "true" (processes:options [directory "~root/"])))
  (check-equal? #f (buffers:find "*user*")))

(test "M-s r in a run's buffer searches the run's folder"
  (layout:switch-to-buffer in-src)
  (check-equal? '("notes.txt:1:a needle here") (grep-texts! "needle")))

(test "project-compile builds in the project's root from a run's buffer inside it, and in the run's folder outside a project"
  (options:set! projects:extra-root-markers '(".project"))
  (shell-commands-test:touch! "proj/.project")
  (let ([in-proj (runs:start-for-user "*proj*" "true" (processes:options [directory "~/proj/sub/"]))])
    (ended in-proj)
    (compile-from! in-proj)
    (check-equal? (home-path "proj") (built (home-path "proj/"))))
  (compile-from! in-src)
  (check-equal? (home-path "src/x") (built (home-path "src/x/"))))

(test "a folder that climbs with .. is made canonical, so projects:find walks the run's real ancestors and M-s r searches the run's folder"
  (shell-commands-test:folder! "work")
  (shell-commands-test:touch! "work/.project")
  (let ([up (runs:start-for-user "*up*" "pwd" (processes:options [directory "~/work/../src/x"]))])
    (ended up)
    (check-equal? (list (home-path "src/x/") (home-path "src/x") #f)
                  (list (files:directory up) (shell-commands-test:output up) (projects:find (files:directory up))))
    (layout:switch-to-buffer up)
    (check-equal? '("notes.txt:1:a needle here") (grep-texts! "needle"))))

(test "an absolute folder with .. is made canonical too, so project-compile builds in the project's root"
  (buffers:kill! (buffers:find (string-append "*compilation " (home-path "proj/") "*")))
  (let ([climbing (runs:start-for-user "*climbing*" "pwd" (processes:options [directory (home-path "src/../proj/sub")]))])
    (ended climbing)
    (check-equal? (home-path "proj/sub/") (files:directory climbing))
    (compile-from! climbing)
    (check-equal? (home-path "proj") (built (home-path "proj/")))))

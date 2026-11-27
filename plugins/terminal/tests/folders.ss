(import (tuna) (test) (test-runner) (test-user) (hooks) (buffers) (files) (processes) (minibuffer) (echo-area)
        (file-picker) (shell-commands) (grep) (terminal) (terminal-test) (completion-test sessions) (shell-commands-test))

(define (at path) (terminal-test:home-file path))

(for-each (lambda (f) (mkdir (at f))) '("proj" "proj/src"))
(with-output-to-file (at "proj/src/notes.txt") (lambda () (display "a needle in proj\n")))

(define t
  (terminal:start (list "sh" "-c" (string-append "printf '\\033]7;file://localhost" (at "proj/src/../") "\\007'; sleep 30"))))

(define (quit!)
  (check (for-all cancelled? (test-runner:reports-during (lambda () (test-user:press! "C-g"))))))

(test "a terminal's buffer gives files:directory the folder its program last reported with OSC 7"
  (test-runner:wait-until (lambda () (equal? (at "proj/") (terminal:directory t))))
  (check-equal? (at "proj/") (files:directory t)))

(test "C-x C-f, M-!, M-s r and compile started from a terminal start in its folder"
  (terminal-test:show! t)
  (test-user:press! "C-x C-f")
  (check-equal? "~/proj/" (minibuffer:input (minibuffer:current-prompt)))
  (quit!)
  (test-user:press! "C-c C-t")
  (test-user:press! "M-!")
  (test-user:type! "pwd")
  (test-user:press! "RET")
  (test-runner:wait-until (lambda () (equal? (at "proj") (echo-area:current-message))))
  (test-user:press! "M-s r")
  (test-user:type! "needle")
  (let ([s (completion-test/sessions:session)])
    (test-runner:wait-until (lambda () (pair? (completion-test/sessions:texts s))))
    (completion-test/sessions:wait-matches s)
    (check-equal? '("src/notes.txt:1:a needle in proj") (completion-test/sessions:texts s)))
  (quit!)
  (shell-commands-test:run shell-commands:compile "pwd")
  (let ([built (buffers:find "*compilation*")])
    (check-equal? 0 (shell-commands-test:ended built))
    (check-equal? (at "proj/") (files:directory built))))

(test "a terminal started in a folder written with ~ or .. records it with ~ expanded and .. removed"
  (let ([u (terminal:start '("sleep" "30") (processes:options [directory "~/proj/src/.."]))])
    (check-equal? (list (at "proj") (at "proj/")) (list (terminal:directory u) (files:directory u)))))

(test "a report of a folder that is not here is refused and the terminal keeps its folder; each folder taken runs directory-changed"
  (let ([changes '()])
    (hooks:add! terminal:directory-changed (lambda (t) (set! changes (cons (terminal:directory t) changes))))
    (let ([v (terminal:start (list "sh" "-c" (string-append "printf '\\033]7;file://localhost/no/such/folder\\007reported\\n'; read x; printf '\\033]7;file://localhost" (at "proj/src") "\\007'; sleep 30"))
                             (processes:options [directory "~/"]))])
      (terminal-test:wait-for v "reported")
      (check-equal? (list '() (at "")) (list changes (terminal:directory v)))
      (terminal:send! v "\r")
      (test-runner:wait-until (lambda () (pair? changes)))
      (check-equal? (list (list (at "proj/src")) (at "proj/src")) (list changes (terminal:directory v))))))

(test "a kitty-shell-cwd:// path is taken as written, without percent decoding"
  (mkdir (at "a%41b"))
  (let ([k (terminal:start (list "sh" "-c" (string-append "printf '\\033]7;kitty-shell-cwd://localhost" (at "a%%41b") "\\007'; sleep 30")))])
    (test-runner:wait-until (lambda () (equal? (at "a%41b") (terminal:directory k))))
    (check-equal? (at "a%41b") (terminal:directory k))))

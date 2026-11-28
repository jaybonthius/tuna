(import (tuna) (test) (test-user) (test-runner) (options) (diff-sections) (git) (git-mode) (git-status) (difftastic) (difftastic-test)
        (git-status-test) (git-test repositories))

(git-test/repositories:write-file! "fake difft"
  (string-append "#!/bin/sh\nif [ \"$1\" = --version ]; then echo 'Difftastic 0.68.0'; exit 0; fi\n"
                 "for w in \"$@\"; do echo \"$w\"; done > \"$HOME/words\"\n"
                 "echo run >> \"$HOME/runs\"\n"
                 "echo \"{\\\"path\\\":\\\"$5\\\",\\\"status\\\":\\\"unchanged\\\"}\"\n"))
(git-test/repositories:run! "" "chmod" "+x" (git-test/repositories:path "fake difft"))
(options:set! difftastic:program (git-test/repositories:path "fake difft"))
(options:set! difftastic:arguments '("--ignore comments" "it's"))

(test "difftastic:program and each of difftastic:arguments reach the program as one word each, before git's"
  (difftastic-test:rewrapped! "repo")
  (test-runner:wait-until (lambda () (file-exists? (git-test/repositories:path "words"))))
  (test-runner:wait-until (lambda () (pair? (difftastic-test:refined-faces))))
  (let ([words (let ([text (call-with-input-file (git-test/repositories:path "words") get-string-all)])
                 (let loop ([cs (string->list text)] [w '()] [acc '()])
                   (cond
                     [(null? cs) (reverse acc)]
                     [(char=? (car cs) #\newline) (loop (cdr cs) '() (cons (list->string (reverse w)) acc))]
                     [else (loop (cdr cs) (cons (car cs) w) acc)])))])
    (check-equal? '("--display" "json" "--ignore comments" "it's" "a.py") (list-head words 5)))
  (check (for-all (lambda (f) (equal? "diff-sections.reformatted" (car f))) (difftastic-test:refined-faces))))

(define (runs) (let ([t (call-with-input-file (git-test/repositories:path "runs") get-string-all)]) (quotient (string-length t) 4)))

(test "a change of difftastic:arguments or difftastic:program forgets the answers held, so a refresh asks difft again"
  (let ([before (runs)] [repo (git:find-repository (git-test/repositories:path "repo"))])
    (git-mode:refresh-repository repo)
    (git-status-test:settle!)
    (check-equal? before (runs))
    (options:set! difftastic:arguments '("--ignore-comments"))
    (git-mode:refresh-repository repo)
    (git-status-test:settle!)
    (test-runner:wait-until (lambda () (> (runs) before)))
    (check (> (runs) before))))

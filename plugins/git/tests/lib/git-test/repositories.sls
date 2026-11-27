#!tuna
(import (processes))

(define (path name) (string-append (getenv "HOME") "/" name))

;; A test's home has no git configuration, and git commits only with a
;; name and an address.
(define %identity
  '(("GIT_AUTHOR_NAME" . "Tuna") ("GIT_AUTHOR_EMAIL" . "tuna@example.org")
    ("GIT_COMMITTER_NAME" . "Tuna") ("GIT_COMMITTER_EMAIL" . "tuna@example.org")))

(define (run! folder program . arguments)
  (let-values ([(status output errors)
                (processes:run program arguments #f (processes:options [directory (path folder)] [environment %identity]))])
    (unless (eqv? status 0)
      (error 'git-test/repositories:run! (utf8->string output) (cons program arguments)))
    output))

(define (git! folder . arguments) (apply run! folder "git" arguments))

(define (write-file! name text)
  (run! "" "mkdir" "-p" (path-parent (path name)))
  (call-with-output-file (path name) (lambda (p) (put-string p text)) 'replace))

;; Chez writes every file name as UTF-8, so a name that is not is made
;; by printf from its octal escapes, such as "caf\\351.txt".
(define (write-escaped-file! folder escaped-name)
  (run! folder "sh" "-c" "printf x > \"$(printf \"$1\")\"" "sh" escaped-name))

(define (sample! name)
  (let ([origin (string-append "origin-" name ".git")] [file (lambda (f) (string-append name "/" f))])
    (git! "" "init" "-q" "--bare" "-b" "main" origin)
    (git! "" "init" "-q" "-b" "main" name)
    (write-file! (file "a.py") "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n")
    (write-file! (file "b.txt") "alpha\nbeta\n")
    (write-file! (file "gone.txt") "gone\n")
    (git! name "add" "-A")
    (git! name "commit" "-qm" "First commit")
    (git! name "remote" "add" "origin" (string-append "../" origin))
    (git! name "push" "-q" "-u" "origin" "main")
    (write-file! (file "b.txt") "alpha\nbeta\ngamma\n")
    (git! name "commit" "-qam" "Second commit")
    (write-file! (file "a.py") "one\nTWO\nthree\nfour\nfive\nsix\nseven\neight\nNINE\nten\n")
    (write-file! (file "b.txt") "alpha\nBETA\ngamma\n")
    (git! name "add" "b.txt")
    (write-file! (file "b.txt") "alpha\nBETA\ngamma\ndelta\n")
    (delete-file (path (file "gone.txt")))
    (write-file! (file "new.txt") "new\n")))

(define (conflict! name)
  (let ([file (string-append name "/f.txt")])
    (git! "" "init" "-q" "-b" "main" name)
    (write-file! file "base\n")
    (git! name "add" "f.txt")
    (git! name "commit" "-qm" "base")
    (git! name "checkout" "-q" "-b" "other")
    (write-file! file "other\n")
    (git! name "commit" "-qam" "other")
    (git! name "checkout" "-q" "main")
    (write-file! file "mine\n")
    (git! name "commit" "-qam" "mine")
    ;; git merge exits 1 when it leaves a conflict.
    (let-values ([(status output errors)
                  (processes:run "git" '("merge" "-q" "other") #f
                    (processes:options [directory (path name)] [environment %identity]))])
      (unless (eqv? status 1)
        (error 'git-test/repositories:conflict! (utf8->string output))))))

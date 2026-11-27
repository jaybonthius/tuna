#!tuna
(import (options) (ask) (buffers) (views) (layout) (processes) (git) (with-editor) (test-runner))

(define (home-path name) (string-append (getenv "HOME") "/" name))

(define (write-file! name text)
  (call-with-output-file (home-path name) (lambda (p) (put-string p text)) 'replace))

(define %said '())

(define %asked '())

;; Saving pauses the command in a job, so what it says can come after
;; the keys have settled; given a count, this waits for that many.
(define take-said!
  (case-lambda
    [() (let ([s (reverse %said)]) (set! %said '()) s)]
    [(n)
     (test-runner:wait-until (lambda () (>= (length %said) n)))
     (take-said!)]))

(define (take-asked!) (let ([s (reverse %asked)]) (set! %asked '()) s))

(define (shown) (let ([b (views:buffer (layout:selected-view))]) (and b (buffers:name b))))

(define (wait-until-shown name)
  (test-runner:wait-until (lambda () (equal? (shown) name)))
  (views:buffer (layout:selected-view)))

(define (show-buffer! name) (layout:switch-to-buffer (buffers:make (buffers:free-name name) "")))

(define (request-folders)
  (filter (lambda (name) (and (>= (string-length name) 10) (string=? "tuna-edit." (substring name 0 10))))
          (directory-list (getenv "TMPDIR"))))

(define (repository! name)
  (let ([repo (git:init (home-path name))])
    (git:set-config! repo "user.name" "Tuna")
    (git:set-config! repo "user.email" "tuna@example.org")
    (staged! repo "a.txt")
    repo))

(define (staged! repo file)
  (write-file! (string-append (git:repository-name repo) "/" file) (string-append file "\n"))
  (git:stage repo (list file)))

(define (subjects repo) (utf8->string (git:query repo '("log" "--format=%s"))))

;; git commit run as git-commit runs it: the command is marked canceled
;; when the user canceled its message.
(define (commit! repo)
  (let ([editing (with-editor:output-wrapper)])
    (values
      (git:start repo '("commit") (lambda (c) (when (with-editor:canceled? editing) (git:set-command-canceled! c)))
                 (processes:options [environment (with-editor:environment "GIT_EDITOR")]) editing)
      editing)))

(define (ended command)
  (test-runner:wait-until (lambda () (git:command-exit command)))
  (git:command-exit command))

(options:set! ask:message-writer (lambda (text) (set! %said (cons text %said))))

(options:set! ask:y-or-n-reader (lambda (question) (set! %asked (cons question %asked)) #t))

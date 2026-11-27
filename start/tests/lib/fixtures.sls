#!tuna
(import (plugins) (plugins process))

(define (home-path . parts)
  (apply string-append (getenv "HOME") (map (lambda (part) (string-append "/" part)) parts)))

(define (configuration-path) (home-path ".config" "tuna" "init.ss"))

;; Chez finds a module stale when its source is newer than its object, and
;; file times step with the kernel's clock tick, 1 to 10 ms, so a rewrite
;; in the tick of the last compile would look unchanged.
(define (next-file-tick)
  (suspend
    (lambda (resume)
      (fork-task
        (lambda (restore)
          (sleep (make-time 'time-duration 10000000 0))
          (resume void))))))

(define (write-file! path text)
  (let make ([folder (path-parent path)])
    (unless (or (string=? folder "") (file-directory? folder))
      (make (path-parent folder))
      (mkdir folder)))
  (next-file-tick)
  (call-with-output-file path (lambda (p) (put-string p text)) 'replace))

(define (read-file path) (call-with-input-file path get-string-all))

(define (forms-text forms)
  (call-with-string-output-port
    (lambda (p) (for-each (lambda (form) (write form p) (newline p)) forms))))

;; One form per line, so the form at index i is on line i + 1.
(define (module-text forms) (string-append "#!tuna\n" (forms-text forms)))

(define (write-module! root name forms)
  (write-file! (format "~a/~a~{/~a~}.sls" root (car name) (cdr name)) (module-text forms)))

(define (write-lib-module! name forms) (write-module! (home-path ".config" "tuna" "lib") name forms))

(define (write-configuration! forms) (write-file! (configuration-path) (forms-text forms)))

(define (load-configuration! forms)
  (write-configuration! forms)
  (plugins:load-configuration!))

(define (reported-position c)
  (let ([form (cond
                [(source-condition? c) (source-condition-form c)]
                [(syntax-violation? c) (syntax-violation-form c)]
                [else #f])])
    (and form
         (let ([a (syntax->annotation form)])
           (and a
                (call-with-values
                  (lambda () (locate-source-object-source (annotation-source a) #t #t))
                  (case-lambda
                    [(path line char) (list path line char)]
                    [() #f])))))))

(define (reported-line c)
  (let ([position (reported-position c)])
    (and position (cadr position))))

(define (message c)
  (and (message-condition? c)
       (if (and (format-condition? c) (irritants-condition? c))
           (apply format (condition-message c) (condition-irritants c))
           (condition-message c))))

;; Modules under test cannot see a test file's definitions, so they tell
;; what they did here.
(define %notes '())

(define (note! x) (set! %notes (cons x %notes)))

(define (take-notes!)
  (let ([notes (reverse %notes)])
    (set! %notes '())
    notes))

(define (changes-of definition)
  (map (lambda (change) (list (owner-name (car change)) (cadr change))) (definition-changes definition)))

(define (change-kinds owner) (map car (owner-changes owner)))

(define (at-repl form) (call-as-owner (plugins:repl-owner) (lambda () (plugins:eval-form form))))

(define (as-configuration form)
  (call-as-owner (plugins:configuration-owner) (lambda () (plugins:eval-form form))))

(define (raised-message thunk)
  (guard (c [(message-condition? c) (message c)]) (thunk) #f))

(define (git! folder . arguments)
  (let-values ([(status output)
                (run-program "git"
                  (append (list "-C" folder "-c" "user.name=Tuna" "-c" "user.email=tuna@example.org"
                                "-c" "commit.gpgsign=false" "-c" "protocol.file.allow=always")
                          arguments))])
    (unless (zero? status) (errorf 'fixtures:git! "git ~s failed in ~a: ~a" arguments folder output))
    (string-trim output)))

(define (remote-folder name) (home-path "remotes" name))

(define (remote-url name) (string-append "file://" (remote-folder name)))

;; Each file is a path in the repository and its text, or #f to delete it.
(define commit!
  (case-lambda
    [(name files) (commit! name files "main")]
    [(name files branch)
     (let ([folder (remote-folder name)])
       (unless (file-directory? (string-append folder "/.git"))
         (write-file! (string-append folder "/.keep") "")
         (git! folder "init" "-q" "-b" "main"))
       (unless (string=? branch (git! folder "symbolic-ref" "--short" "HEAD"))
         (if (zero? (let-values ([(status output) (run-program "git" (list "-C" folder "show-ref" "-q" "--verify" (string-append "refs/heads/" branch)))]) status))
             (git! folder "checkout" "-q" branch)
             (git! folder "checkout" "-q" "-b" branch)))
       (for-each
         (lambda (file)
           (let ([path (string-append folder "/" (car file))])
             (if (cdr file)
                 (write-file! path (cdr file))
                 (when (file-exists? path) (delete-file path)))))
         files)
       (git! folder "add" "-A")
       (git! folder "commit" "-q" "--allow-empty" "-m" "commit")
       (git! folder "rev-parse" "HEAD"))]))

(define (commits! name file-lists)
  (let loop ([file-lists file-lists])
    (if (null? file-lists)
        '()
        (let ([commit (commit! name (car file-lists))])
          (cons commit (loop (cdr file-lists)))))))

(define (string-trim s)
  (let loop ([end (string-length s)])
    (if (and (> end 0) (char-whitespace? (string-ref s (- end 1))))
        (loop (- end 1))
        (substring s 0 end))))

(define (short commit) (substring commit 0 7))

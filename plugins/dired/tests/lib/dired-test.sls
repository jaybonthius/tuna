#!tuna
(import (test-runner) (test-user) (options) (ask) (echo-area) (document) (buffers) (views) (layout) (dired))

(define (home-path name) (string-append (getenv "HOME") "/" name))

(define (touch! path . text)
  (let ([path (home-path path)])
    (let loop ([folder (path-parent path)])
      (unless (file-exists? folder)
        (loop (path-parent folder))
        (mkdir folder)))
    (call-with-output-file path (lambda (p) (for-each (lambda (t) (display t p)) text)) 'replace)))

(define (folder! path) (mkdir (home-path path)))

(define %symlink (begin (load-shared-object #f) (foreign-procedure "symlink" (string string) int)))

(define (symlink! target path) (%symlink target (home-path path)))

(define (exists? path) (file-exists? (home-path path) #f))

(define (view) (layout:selected-view))

(define (entries b)
  (let ([doc (buffers:document b)])
    (let loop ([p 0] [acc '()])
      (let ([t (document:token doc p)])
        (cond
          [(eof-object? t) (reverse acc)]
          [(and (document:node? t) (eq? (document:node-kind t) 'dired:%entry)) (loop (+ p 1) (cons t acc))]
          [else (loop (+ p 1) acc)])))))

(define (entry-name e) (path-last (dired:entry-path e)))

(define (lines b)
  (map (lambda (e)
         (let ([m (dired:entry-mark e)])
           (string-append (if m (string m) " ") " " (entry-name e))))
       (entries b)))

(define (shown-lines) (lines (views:buffer (view))))

(define (goto! name)
  (let ([e (find (lambda (e) (equal? (entry-name e) name)) (entries (views:buffer (view))))])
    (views:set-point! (view) (+ 1 (document:node-start e)))))

(define (point-name)
  (let ([e (dired:entry-at (view))])
    (and e (entry-name e))))

(define (shown)
  (map (lambda (v) (list (buffers:name (views:buffer v)) (eq? v (view))))
       (filter (lambda (v) (not (buffers:internal-name? (buffers:name (views:buffer v))))) (layout:views))))

(define %asked '())

(define (answer reply) (lambda (question . folder) (set! %asked (cons question %asked)) reply))

(define (questions) (let ([q (reverse %asked)]) (set! %asked '()) q))

;; A command that reads a folder or works on files pauses for a job, so
;; it goes on after the keys have settled; these wait for what it ends
;; with.
(define (press-until! keys done?)
  (test-user:press! keys)
  (test-runner:wait-until done?))

(define (press-for-message! keys)
  (echo-area:message! "")
  (press-until! keys echo-area:current-message)
  (echo-area:current-message))

(define (press-until-shown! keys name)
  (press-until! keys (lambda () (equal? name (buffers:name (views:buffer (view)))))))

(define (relisted! b thunk)
  (let ([version (buffers:version b)])
    (thunk)
    (test-runner:wait-until (lambda () (not (= version (buffers:version b)))))))

(define (press-until-read! keys)
  (let ([b (views:buffer (view))])
    (press-until! keys
      (lambda ()
        (equal? (list-sort string<? (append '("." "..") (directory-list (dired:folder b))))
                (list-sort string<? (map entry-name (entries b))))))))

(define (press-until-listed! keys)
  (relisted! (views:buffer (view)) (lambda () (test-user:press! keys))))

(define (view-element)
  (let ([id (number->string (views:id (view)))])
    (find (lambda (e) (equal? id (test-user:element-attribute e "data-view")))
          (test-user:elements-with (test-user:screen) "data-view"))))

(define (holding? node class text)
  (exists (lambda (e) (equal? text (test-user:element-text e))) (test-user:elements node class)))

(define (click-link! text)
  (test-user:click-element! (find (lambda (e) (equal? text (test-user:element-text e))) (drawn "ui-link"))))

(define (click-name! name)
  (let ([e (find (lambda (e) (equal? (entry-name e) name)) (entries (views:buffer (view))))])
    (test-user:click! (view) (+ 1 (document:node-start e)))))

(define (drawn class) (test-user:elements (view-element) class))

(define (drawn-texts class) (map test-user:element-text (drawn class)))

(define (drawn-field class name)
  (let ([entry (find (lambda (e) (holding? e "dired-name" name)) (drawn "dired-entry"))])
    (test-user:element-text (car (test-user:elements entry class)))))

(define (starts-with? prefix s)
  (and (string? s) (<= (string-length prefix) (string-length s)) (string=? prefix (substring s 0 (string-length prefix)))))

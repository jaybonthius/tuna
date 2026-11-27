#!tuna
;; Each start makes the buffer and the atom again, as a configuration
;; would, since a saved view waits for a buffer of its name.
(import (tuna) (buffers) (document) (views) (views-test md))

(define (make-notes!) (buffers:make "notes" "one two\nthree four\nfive six\n"))

(define (make-host!) (buffers:make "*host*" (views-test/md:doc '() (views:view '((view . 300) (buffer . "notes"))))))

(define (atom-view host) (views:atom-view (document:token (buffers:document host) 1)))

(define (home-file name) (string-append (getenv "HOME") "/" name))

(define (saved-histories)
  (let ([f (home-file ".local/share/tuna/saved/tuna/views/histories.ss")])
    (and (file-exists? f) (call-with-input-file f read))))

(define (saved-views)
  (let ([f (home-file ".local/share/tuna/saved/tuna/views/state.ss")])
    (and (file-exists? f) (call-with-input-file f read))))

;; Views writes its saved data when a batch ends, and a file's forms run
;; in one batch until something pauses them.
(define (end-batch!)
  (suspend (lambda (resume) (spawn-task (lambda (restore) (resume void))))))

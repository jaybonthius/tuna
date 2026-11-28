#!tuna
(import (test-runner) (sampler) (only (host) host-read-link))

;; An earlier want may have left a last time, so the first reading for
;; this want is the one that moves it.
(define (wanting source seconds thunk)
  (let ([o (make-owner '(viewer sampler-test))] [before (sampler:last-time source)])
    (guard (c [#t (unload-owner! o) (raise c)])
      (call-as-owner o (lambda () (sampler:want source seconds)))
      (test-runner:wait-until (lambda () (not (eqv? before (sampler:last-time source)))))
      (thunk))
    (unload-owner! o)))

(define (reading! source)
  (let ([before (sampler:last-time source)])
    (sampler:read-now! source)
    (test-runner:wait-until (lambda () (not (eqv? before (sampler:last-time source)))))))

(define %symlink (begin (load-shared-object #f) (foreign-procedure "symlink" (string string) int)))

;; A pair of readings of a copied tree: a producer's root option names a
;; link, set once, and the test points the link at another tree between
;; readings, since setting the option would restart the source and lose
;; the reading a rate needs. The link is replaced by a rename, so a
;; reading never finds it missing.
(define (point! link target)
  (let ([new (string-append link ".new")])
    (unless (= 0 (%symlink target new))
      (error 'point! "cannot make the link" new target))
    (rename-file new link)))

(define (scratch name) (string-append (getenv "HOME") "/" name))

(define (read-text path)
  (let ([text (call-with-port (open-file-input-port path (file-options) (buffer-mode block) (native-transcoder))
                get-string-all)])
    (if (eof-object? text) "" text)))

(define (write-text! path text)
  (call-with-port (open-file-output-port path (file-options no-fail) (buffer-mode block) (native-transcoder))
    (lambda (p) (put-string p text))))

;; A tree copied from /sys keeps its links, whose targets lie inside the
;; copy, so each is made again rather than followed.
(define (copy-tree! from to)
  (mkdir to)
  (for-each
    (lambda (name)
      (let ([source (string-append from "/" name)] [target (string-append to "/" name)])
        (cond
          [(file-symbolic-link? source)
           (unless (= 0 (%symlink (host-read-link source) target))
             (error 'copy-tree! "cannot make the link" target))]
          [(file-directory? source #f) (copy-tree! source target)]
          [else (write-text! target (read-text source))])))
    (directory-list from)))

;; A copy of a fixture tree in the test's home, with one file's text
;; changed, for a reading the machine cannot be made to give.
(define (variant! name from file change)
  (let ([to (scratch name)])
    (copy-tree! from to)
    (write-text! (string-append to "/" file) (change (read-text (string-append to "/" file))))
    to))

(import (tuna) (test) (hooks) (options) (buffers) (files) (files-test))

(define (raised-by who) (lambda (c) (and (who-condition? c) (eq? who (condition-who c)))))

(for-each files-test:folder! '("~/src" "~/src/d" "~/src/e"))
(files-test:write-text! "~/src/d/a.txt" "a\n")

(define a (files:visit "~/src/d/a.txt"))

(define plain (buffers:make "plain" "text\n"))

(test "files:directory asks files:directory-finders by depth; files' own entry answers a file buffer with its file's folder, and a buffer no entry answers has the home folder"
  (check-equal? (list (files-test:expand "~/src/d/") (files-test:expand "~/")) (map files:directory (list a plain)))
  (check-equal? (list (files-test:expand "~/src/d/") #f) (list (files:file-directory a) (files:file-directory plain)))
  (check-equal? (files-test:expand "~/src/d/") (buffers:with-buffer a (files:directory)))
  (check-raises (raised-by 'files:directory) (files:directory "notes")))

(define chosen (make-eq-hashtable))

(define (chosen-folder b) (eq-hashtable-ref chosen b #f))

(test "an entry answering for a buffer that visits no file gives it a folder, and one placed before files' own gives a file buffer another"
  (hooks:add! files:directory-finders chosen-folder -20)
  (eq-hashtable-set! chosen plain "/tmp")
  (eq-hashtable-set! chosen a "/srv/elsewhere/")
  (check-equal? '("/srv/elsewhere/" "/tmp/") (map files:directory (list a plain)))
  (hooks:remove! files:directory-finders chosen-folder)
  (check-equal? (list (files-test:expand "~/src/d/") (files-test:expand "~/")) (map files:directory (list a plain))))

(define (nowhere b) 'nowhere)

(define (relative b) "~/src/")

(test "a finder's answer that is no folder starting with / is refused at that finder"
  (for-each
    (lambda (finder)
      (hooks:add! files:directory-finders finder)
      (check-raises (raised-by 'files:directory) (files:directory plain))
      (hooks:remove! files:directory-finders finder))
    (list nowhere relative)))

(define seen #f)

(define (note-folder b) (set! seen (files:directory)))

(test "files:directory-override, bound with options:with, gives one buffer a folder for what runs inside it, before any entry; another buffer, and a file visited inside it, keep their own"
  (files-test:write-text! "~/src/e/b.txt" "b\n")
  (hooks:add! files:after-visit note-folder)
  (let ([b #f])
    (check-equal? (list "/srv/project/" (files-test:expand "~/") (files-test:expand "~/src/e/"))
      (options:with ([files:directory-override (cons a "/srv/project")])
        (set! b (files:visit "~/src/e/b.txt"))
        (list (files:directory a) (files:directory plain) (files:directory b)))))
  (hooks:remove! files:after-visit note-folder)
  (check-equal? (list (files-test:expand "~/src/e/") (files-test:expand "~/src/d/")) (list seen (files:directory a)))
  (check-raises assertion-violation? (options:with ([files:directory-override (cons a "relative/")]) (files:directory a)))
  (check-raises assertion-violation? (options:with ([files:directory-override "/srv"]) (files:directory a))))

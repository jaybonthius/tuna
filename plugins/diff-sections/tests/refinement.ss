(import (tuna) (test) (test-user) (options) (tables) (buffers) (document) (views) (ui) (diff) (diff-sections) (diff-sections-test))

(define files
  (diff-sections-test:parse
    "diff --git a/a.py b/a.py\nindex 1111111..2222222 100644\n--- a/a.py\n+++ b/a.py\n@@ -1,4 +1,3 @@\n one\n-foo(x,\n- y)\n+foo(x, y)\n four\n"
    "diff --git a/b.py b/b.py\nindex 3333333..4444444 100644\n--- a/b.py\n+++ b/b.py\n@@ -1,2 +1,2 @@\n-x = 2\n+x = 3\n keep\n"
    "diff --git a/c.py b/c.py\nindex 5555555..6666666 100644\n--- a/c.py\n+++ b/c.py\n@@ -1 +1 @@\n-a  =  1\n+a = 1\n"))

(define requests '())

(define available #t)

(define fake (diff-sections:make-refiner "fake" (lambda () available) (lambda (request) (set! requests (append requests (list request))))))

(define sources '())

(define (source container external paths)
  (set! sources (cons (list container external (map diff:file-path paths)) sources))
  #vu8())

(define (refinement file novel pairs unchanged?)
  (diff-sections:make-refinement (diff:file-path-bytes file) (diff:file-old-blob file) (diff:file-new-blob file) novel pairs unchanged?))

(define (requested) (map (lambda (r) (map diff:file-path (diff-sections:request-files r))) requests))

(define (take-requests!) (let ([r requests]) (set! requests '()) r))

(define b
  (diff-sections-test:show!
    (diff-sections:file-section (car files))
    (diff-sections:file-section (cadr files))
    (diff-sections:file-section (caddr files) '((hidden . #t)))))

(define (faces)
  (map (lambda (e) (list (test-user:element-attribute e "data-face") (test-user:element-text e)))
       (filter (lambda (e) (member (test-user:element-attribute e "data-face")
                                   '("diff-sections.novel-added" "diff-sections.novel-removed" "diff-sections.reformatted")))
               (test-user:elements-with (test-user:screen) "data-face"))))

(buffers:with-buffer b (options:set-local! diff-sections:refiner fake diff-sections:source source))

(test "diff-sections:refine! asks the refiner once for the file sections a view shows, which a run of the source covers alone"
  (diff-sections:refine! b)
  (check-equal? '(("a.py" "b.py")) (requested))
  (check (diff-sections:request? (car requests)))
  ((diff-sections:request-run (car requests)) "difft")
  (check-equal? '((#f "difft" ("a.py" "b.py"))) sources))

(test "a file asked for is not asked for again while its answer is awaited"
  (diff-sections:refine! b)
  (check-equal? '(("a.py" "b.py")) (requested)))

(test "an answer draws a new token in a stronger face, and a changed line with no new token dimmed; the text is unchanged"
  (let ([text (diff-sections-test:text b)])
    (diff-sections:deliver! (car (take-requests!))
      (list (refinement (car files) '() '((1 . 1) (2 . #f) (3 . 2) (4 . 3)) #f)
            (refinement (cadr files) '((old 1 4 5) (new 1 4 5)) '((1 . 1) (2 . 2)) #f)))
    (check-equal? text (diff-sections-test:text b))
    (test-user:settle)
    (check-equal? '(("diff-sections.reformatted" "foo(x,") ("diff-sections.reformatted" " y)") ("diff-sections.reformatted" "foo(x, y)")
                    ("diff-sections.novel-removed" "2") ("diff-sections.novel-added" "3"))
                  (faces))))

(test "a refinement's pairs give the rows of the two columns, in place of the k-th line beside the k-th"
  (check-equal? '(("both" "--diff-sections-row: 1") ("left" "--diff-sections-row: 2") ("left" "--diff-sections-row: 3")
                  ("right" "--diff-sections-row: 3") ("both" "--diff-sections-row: 4"))
                (map (lambda (e) (list (test-user:element-attribute e "data-side") (test-user:element-attribute e "style")))
                     (list-head (diff-sections-test:drawn "diff-sections-line") 5))))

(test "a file shown later is asked for when a view shows it"
  (take-requests!)
  (ui:show-section! (diff-sections-test:view) (ui:find-section b '((file . "c.py"))))
  (check-equal? '(("c.py")) (requested)))

(test "a file whose change is formatting only has every changed line dimmed"
  (diff-sections:deliver! (car (take-requests!)) (list (refinement (caddr files) '() '((1 . 1)) #t)))
  (test-user:settle)
  (check-equal? '(("diff-sections.reformatted" "a  =  1") ("diff-sections.reformatted" "a = 1")) (list-tail (faces) 5)))

(test "a refresh that keeps a file's two blobs and path asks nothing again"
  (buffers:reconcile! b (document:token (buffers:document b) 0)
                      (list (diff-sections:file-section (car files)) (diff-sections:file-section (cadr files)) (diff-sections:file-section (caddr files))))
  (diff-sections:refine! b)
  (check-equal? '() (requested)))

(test "with no refiner, the spans go at once"
  (buffers:with-buffer b (options:set-local! diff-sections:refiner #f))
  (diff-sections:refine! b)
  (test-user:settle)
  (check-equal? '() (faces))
  (buffers:with-buffer b (options:set-local! diff-sections:refiner fake)))

(test "an unavailable refiner is not asked"
  (set! available #f)
  (buffers:reconcile! b (document:token (buffers:document b) 0) (list (diff-sections:file-section (car (diff-sections-test:parse "diff --git a/d.py b/d.py\nindex 7..8 100644\n--- a/d.py\n+++ b/d.py\n@@ -1 +1 @@\n-d\n+D\n")))))
  (diff-sections:refine! b)
  (check-equal? '() (requested))
  (set! available #t))

(test "refiners and refinements are checked where they are made"
  (check-raises assertion-violation? (diff-sections:make-refiner 'fake (lambda () #t) (lambda (r) r)))
  (check-raises assertion-violation? (diff-sections:make-refinement #vu8(97) "1" "2" '((left 1 0 1)) '() #f))
  (check-raises assertion-violation? (options:set! diff-sections:refiner "fake"))
  (check-equal? "fake" (diff-sections:refiner-name fake)))

(test "a binary file and a combined diff are never asked for; a file the refiner answers nothing for is drawn plain"
  (let* ([others (diff-sections-test:parse
                   "diff --git a/x.bin b/x.bin\nindex 1..2 100644\nBinary files a/x.bin and b/x.bin differ\n"
                   "diff --cc f.txt\nindex 1,2..0\n--- a/f.txt\n+++ b/f.txt\n@@@ -1,3 -1,3 +1,4 @@@\n  one\n++<<<<<<< HEAD\n +MINE\n+ OTHER\n  three\n"
                   "diff --git a/n.txt b/n.txt\nnew file mode 100644\nindex 0000000..9999999\n--- /dev/null\n+++ b/n.txt\n@@ -0,0 +1 @@\n+new\n")])
    (take-requests!)
    (buffers:reconcile! b (document:token (buffers:document b) 0) (map diff-sections:file-section others))
    (diff-sections:refine! b)
    (check-equal? '(("n.txt")) (requested))
    (diff-sections:deliver! (car (take-requests!)) '())
    (test-user:settle)
    (check-equal? '() (faces))))

(test "an answer for a file no longer in the buffer is dropped, and the file is asked for again when it comes back"
  (let ([file (car (diff-sections-test:parse "diff --git a/g.py b/g.py\nindex aaaaaaa..bbbbbbb 100644\n--- a/g.py\n+++ b/g.py\n@@ -1 +1 @@\n-g = 1\n+g = 2\n"))])
    (buffers:reconcile! b (document:token (buffers:document b) 0) (list (diff-sections:file-section file)))
    (diff-sections:refine! b)
    (let ([request (car (take-requests!))])
      (buffers:reconcile! b (document:token (buffers:document b) 0) (list (diff-sections:file-section (car files))))
      (diff-sections:deliver! request (list (refinement file '((new 1 4 5)) '((1 . 1)) #f)))
      (buffers:reconcile! b (document:token (buffers:document b) 0) (list (diff-sections:file-section file)))
      (diff-sections:refine! b)
      (check-equal? '(("g.py")) (requested)))))

(test "rows rearranged by an answer leave the cursor on its line; where the answer's pairs cross, the later pair's removed line stands alone"
  (let ([file (car (diff-sections-test:parse "diff --git a/h.py b/h.py\nindex ccccccc..ddddddd 100644\n--- a/h.py\n+++ b/h.py\n@@ -1,2 +1,2 @@\n-a\n-b\n+B\n+A\n"))])
    (buffers:reconcile! b (document:token (buffers:document b) 0) (list (diff-sections:file-section file)))
    (take-requests!)
    (diff-sections:refine! b)
    (views:set-point! (diff-sections-test:view) (+ 1 (diff-sections-test:line-position b "+B")))
    (diff-sections:deliver! (car (take-requests!)) (list (refinement file '() '((1 . 2) (2 . 1)) #f)))
    (test-user:settle)
    (check-equal? (+ 1 (diff-sections-test:line-position b "+B")) (views:point (diff-sections-test:view)))
    (check-equal? '(("left" "--diff-sections-row: 2") ("left" "--diff-sections-row: 3") ("right" "--diff-sections-row: 1") ("right" "--diff-sections-row: 2"))
                  (map (lambda (e) (list (test-user:element-attribute e "data-side") (test-user:element-attribute e "style")))
                       (diff-sections-test:drawn "diff-sections-line")))))

(define (fresh-file name blob)
  (car (diff-sections-test:parse
         (string-append "diff --git a/" name " b/" name "\nindex 1234567.." blob " 100644\n--- a/" name "\n+++ b/" name
                        "\n@@ -1 +1 @@\n-k = 1\n+k = 2\n"))))

(test "a refiner whose plugin has unloaded is no refiner: a buffer that still names it asks nothing and draws plain"
  (let* ([file (fresh-file "p.py" "aaaa001")] [o (make-owner '(refiner gone))] [asked '()]
         [gone (call-as-owner o (lambda () (diff-sections:make-refiner "gone" (lambda () #t) (lambda (request) (set! asked (cons request asked))))))])
    (buffers:reconcile! b (document:token (buffers:document b) 0) (list (diff-sections:file-section file)))
    (buffers:with-buffer b (options:set-local! diff-sections:refiner gone))
    (unload-owner! o)
    (diff-sections:refine! b)
    (check-equal? '() asked)
    (check (not (diff-sections:refiner-of b)))
    (test-user:settle)
    (check-equal? '() (faces))
    (buffers:with-buffer b (options:set-local! diff-sections:refiner fake))))

(test "an answer repaints every buffer that shows its file, not only the one that asked"
  (let* ([file (fresh-file "q.py" "aaaa002")]
         [other (diff-sections-test:show! (diff-sections:file-section file))])
    (buffers:with-buffer other (options:set-local! diff-sections:refiner fake diff-sections:source source))
    (diff-sections-test:show-buffer! b)
    (buffers:reconcile! b (document:token (buffers:document b) 0) (list (diff-sections:file-section file)))
    (take-requests!)
    (diff-sections:refine! b)
    (diff-sections-test:show-buffer! other)
    (diff-sections:refine! other)
    (check-equal? '(("q.py")) (requested))
    (diff-sections:deliver! (car (take-requests!)) (list (refinement file '((new 1 4 5)) '((1 . 1)) #f)))
    (test-user:settle)
    (check-equal? '(("diff-sections.reformatted" "k = 1") ("diff-sections.novel-added" "2")) (faces))))

(test "answers are held by refiner: another refiner is asked for a file the first has answered"
  (let* ([file (fresh-file "r.py" "aaaa003")]
         [other-requests '()]
         [other (diff-sections:make-refiner "other" (lambda () #t) (lambda (request) (set! other-requests (cons request other-requests))))])
    (buffers:reconcile! b (document:token (buffers:document b) 0) (list (diff-sections:file-section file)))
    (diff-sections-test:show-buffer! b)
    (take-requests!)
    (diff-sections:refine! b)
    (diff-sections:deliver! (car (take-requests!)) (list (refinement file '((new 1 4 5)) '((1 . 1)) #f)))
    (buffers:with-buffer b (options:set-local! diff-sections:refiner other))
    (diff-sections:refine! b)
    (check-equal? '(("r.py")) (map (lambda (r) (map diff:file-path (diff-sections:request-files r))) other-requests))
    (test-user:settle)
    (check-equal? '() (faces))
    (buffers:with-buffer b (options:set-local! diff-sections:refiner fake))
    (diff-sections:forget! fake)
    (diff-sections:refine! b)
    (check-equal? '(("r.py")) (requested))))

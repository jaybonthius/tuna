(import (test) (test-runner))

(define (home name) (string-append (getenv "HOME") "/" name))

(define (saved-file home name) (string-append home "/.local/share/tuna/saved/tuna/layout/" name ".ss"))

(define (make-folders! path)
  (let loop ([i 1])
    (cond
      [(>= i (string-length path)) (void)]
      [(char=? #\/ (string-ref path i))
       (let ([folder (substring path 0 i)])
         (unless (file-exists? folder) (mkdir folder))
         (loop (+ i 1)))]
      [else (loop (+ i 1))])))

(define (write-datum! file datum)
  (make-folders! file)
  (call-with-output-file file (lambda (p) (write datum p)) 'replace))

(define (read-datum file) (call-with-input-file file read))

(define (passes file home)
  (let-values ([(status errors) (test-runner:run-file file home)])
    (check-equal? 0 status)
    (check-equal? "" errors)))

(test "the layout, the selection order and the zoom outlast a restart, with each view's point; the zoom is saved as the view's number and how far out its level is"
  (let ([h (home "restarted")])
    (passes "restart/first.ss" h)
    (let ([expected (read-datum (string-append h "/expected.ss"))])
      (check-equal? (list (cadr expected) (cons (caddr expected) 1)) (read-datum (saved-file h "saved-selection"))))
    (passes "restart/second.ss" h)))

(test "a saved layout its check refuses is set aside, and the default used"
  (for-each
    (lambda (name datum)
      (let ([h (home name)])
        (test-runner:make-home! h)
        (write-datum! (saved-file h "saved-layout") datum)
        (passes "restart/refused.ss" h)
        (check (file-exists? (string-append (saved-file h "saved-layout") ".rejected")))))
    '("no-unlocked-view" "level-in-level" "text" "view-twice")
    '((layout:level () #(views:view ((view . 1) (buffer . "notes") (locked . #t))))
      (layout:level () (layout:level () #(views:view ((view . 1) (buffer . "notes")))))
      (layout:level () (layout-split:container ((direction . row)) "text"))
      (layout:level ()
        (layout-split:container ((direction . row))
          #(views:view ((view . 1) (buffer . "notes"))) #(views:view ((view . 1) (buffer . "notes"))))))))

(test "with no buffer, or only internal ones, the layout starts on a new *scratch*"
  (passes "restart/no-buffer.ss" (home "no-buffer"))
  (passes "restart/internal.ss" (home "internal")))

(define two-and-a-bar
  '(layout:level ()
     (layout-split:container ((direction . column))
       (layout:level ()
         (layout-split:container ((direction . row))
           #(views:view ((view . 1) (buffer . "notes"))) #(views:view ((view . 2) (buffer . "notes")))))
       #(views:view ((view . 3) (buffer . "notes") (depth . 90) (locked . #t))))))

(test "a saved order headed by a locked part selects the view the user worked in, and the locked part keeps its place after it"
  (let ([h (home "locked-first")])
    (test-runner:make-home! h)
    (write-datum! (saved-file h "saved-layout") two-and-a-bar)
    (write-datum! (saved-file h "saved-selection") '((3 1 2) #f))
    (write-datum! (string-append h "/expected.ss") '(1 (1 3 2) #f))
    (passes "restart/selection.ss" h)))

(test "a placed part that is not locked is a view the user may work in"
  (let ([h (home "placed-first")])
    (test-runner:make-home! h)
    (write-datum! (saved-file h "saved-layout")
      '(layout:level ()
         (layout-split:container ((direction . column))
           (layout:level ()
             (layout-split:container ((direction . row))
               #(views:view ((view . 1) (buffer . "notes"))) #(views:view ((view . 2) (buffer . "notes")))))
           #(views:view ((view . 3) (buffer . "notes") (depth . 90))))))
    (write-datum! (saved-file h "saved-selection") '((3 1 2) #f))
    (write-datum! (string-append h "/expected.ss") '(3 (3 1 2) #f))
    (passes "restart/selection.ss" h)))

(test "a saved zoom whose view is gone ends"
  (let ([h (home "zoom-gone")])
    (test-runner:make-home! h)
    (write-datum! (saved-file h "saved-layout") two-and-a-bar)
    (write-datum! (saved-file h "saved-selection") '((1 2) (9 . 1)))
    (write-datum! (string-append h "/expected.ss") '(1 (1 2) #f))
    (passes "restart/selection.ss" h)))

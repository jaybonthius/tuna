(import (tuna) (test) (views) (buffers) (views-test session) (views-test md))

(define (found) (filter views:find (map (lambda (i) (+ i 1)) (iota 400))))

(define notes (views-test/session:make-notes!))
(views-test/session:make-host!)

(test "of the views atoms drew before, only the one an atom names by number came back"
  (check (for-all (lambda (id) (= id 300)) (found))))

(views:draw
  (views:make (buffers:make "chat"
                (views-test/md:doc '()
                  (views:view '((buffer . "notes")))
                  (views:view '((view . 300) (buffer . "notes")))
                  (views:view '((view . 300) (buffer . "notes"))))))
  #f)

(views-test/session:end-batch!)

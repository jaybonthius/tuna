;;; Whether a memo piece is drawn again (tuna/lib/memo): what a change to
;;; a source does to what was drawn from it.
(import :tuna/lib/memo)
(export drawn-again?)

;; Draw a piece that calls (READ), call (CHANGE), and draw it again:
;; whether the second pass drew it rather than reusing it.
(def (drawn-again? (read : :procedure) (change : :procedure)) => :boolean
  (let ((cache (new-memo-cache))
        (count 0))
    (def (pass)
      (call-with-memo-pass cache #f
        (lambda () (memo 'piece [] (lambda (inputs) (set! count (+ count 1)) (read) #t)))))
    (pass)
    (change)
    (pass)
    (= count 2)))

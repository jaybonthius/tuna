(import (tuna) (testing) (tuna plugins) (document) (web))
(use-plugin layout)
(use-plugin layout-split)
(use-plugin editing)
(use-plugin echo-area)
(use-plugin undo)
(use-plugin modes)
(use-plugin minibuffer)
(use-plugin completion)
(use-plugin ui)
(use-plugin layout-float)
(use-plugin completion-popup)
(use-plugin chez-scheme)
(use-plugin dabbrev)

(define client (web:add-client! 1))

(define (press! . keys)
  (for-each
    (lambda (key)
      (parameterize ([web:current-client client])
        (views:call-with-view (layout:selected-view) (lambda () (keys:press! client key)))))
    keys))

(define (type! text)
  (for-each (lambda (c) (press! (if (char=? c #\space) "SPC" (string c)))) (string->list text)))

(define (in-client thunk)
  (parameterize ([web:current-client client])
    (views:call-with-view (layout:selected-view) thunk)))

(define (view) (layout:selected-view))

(define (text b) (document:text (buffers:document b)))

(define (show! b)
  (views:set-buffer! (view) b)
  (views:set-point! (view) (- (document:length (buffers:document b)) 1))
  b)

(define (point) (views:point (view)))

;; Chez's map may call its procedure in any order.
(define (expansions . keys)
  (let loop ([keys keys] [acc '()])
    (if (null? keys)
        (reverse acc)
        (begin (press! (car keys)) (loop (cdr keys) (cons (word-before-point) acc))))))

(define (word-before-point)
  (let ([b (views:buffer (view))])
    (let-values ([(start end) (syntax:symbol-bounds b (point))])
      (and start (document:text (buffers:document b) start (point))))))

(define (session) (in-client completion:current-session))


(define (match-list s) (let ([ms (completion:session-matches s)]) (do ([k (- (completion:matches-count ms) 1) (- k 1)] [acc '() (cons (completion:matches-ref ms k) acc)]) ((< k 0) acc))))

(define (texts s) (map (lambda (m) (completion:text s m)) (match-list s)))

;; The key's command starts the session, so none after it means none.
(define (settled-texts)
  (cond
    [(session)
     => (lambda (s)
          (testing:wait-until (lambda () (not (completion:session-busy? s))))
          (texts s))]
    [else #f]))

(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c) (condition-message c) c))])
    (thunk)))
(import (console))

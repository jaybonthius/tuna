#!tuna
(import (web) (views) (buffers) (layout) (commands) (keys) (tables) (test-user))

(tables:define-table keymap "Harpo's horn.")

(commands:define-command (honk) "Does nothing." (void))

(commands:define-command (squeak) "Does nothing either." (void))

(define (%one-of element class)
  (let ([found (test-user:elements element class)])
    (and (pair? found) (car found))))

(define (%entry e)
  (let* ([text-element (%one-of e "which-key-text")] [text (test-user:element-text text-element)]
         [all (test-user:element-text e)])
    (append (list (substring all 0 (fx- (string-length all) (string-length text))) text)
            (if (member "which-key-label" (%classes text-element)) '(label) '()))))

(define (%classes element)
  (let ([value (or (test-user:element-attribute element "class") "")])
    (let loop ([chars (string->list value)] [word '()] [words '()])
      (let ([add (lambda () (if (null? word) words (cons (list->string (reverse word)) words)))])
        (cond
          [(null? chars) (reverse (add))]
          [(char=? (car chars) #\space) (loop (cdr chars) '() (add))]
          [else (loop (cdr chars) (cons (car chars) word) words)])))))

(define popup
  (case-lambda
    [() (popup (test-user:client))]
    [(client)
     (let ([shown (%one-of (test-user:screen client) "which-key")])
       (and shown
            (cons (test-user:element-text (%one-of shown "which-key-prefix"))
                  (map %entry (test-user:elements shown "which-key-entry")))))]))

(define (shows?) (and (popup) #t))

;; A click as views' page script sends one in the selected view.
(define (click! button at)
  (let* ([v (layout:selected-view)] [b (views:buffer v)])
    (web:post-input! (test-user:client)
      (list (cons "type" "mouse") (cons "action" "click") (cons "button" button) (cons "clicks" 1)
            (cons "modifiers" (vector)) (cons "view" (views:id v)) (cons "showing" (views:shown-count v))
            (cons "version" (buffers:version b)) (cons "at" at)))
    (test-user:settle)))

(define (wheel! direction at)
  (let* ([v (layout:selected-view)] [b (views:buffer v)])
    (web:post-input! (test-user:client)
      (list (cons "type" "mouse") (cons "action" "wheel") (cons "direction" direction)
            (cons "modifiers" (vector)) (cons "view" (views:id v)) (cons "showing" (views:shown-count v))
            (cons "version" (buffers:version b)) (cons "at" at)))
    (test-user:settle)))

(keys:bind! keymap "h" honk)
(keys:bind! keymap "s" squeak)

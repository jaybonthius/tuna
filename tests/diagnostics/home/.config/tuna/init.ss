(import (tuna) (testing) (tuna plugins) (document) (web) (haml))
(define said '())
(use-plugin ask
  (config
    (set-option! ask:message-writer (lambda (text) (set! said (cons text said))))))
(define (take-said!) (let ([s (reverse said)]) (set! said '()) s))
(use-plugin layout)
(use-plugin layout-split)
(use-plugin editing)
(use-plugin files)
(use-plugin processes)
(use-plugin echo-area)
(use-plugin markdown)
(use-plugin docs-at-point
  (config
    (set-option! docs-at-point:delay 0.05)))
(use-plugin docs-at-point-display)
(use-plugin diagnostics
  (config
    (set-option! diagnostics:check-delay 0.05)))

(define client (web:add-client! 1))

(define (press! . keys)
  (for-each
    (lambda (key)
      (parameterize ([web:current-client client])
        (views:call-with-view (layout:selected-view) (lambda () (keys:press! client key)))))
    keys))

(define (mouse! view . fields)
  (parameterize ([web:current-client client])
    ((table-ref web:input-handlers "mouse") client
     (append fields
             `(("type" . "mouse") ("button" . 1) ("clicks" . 1) ("modifiers" . #())
               ("view" . ,(views:id view)) ("version" . ,(buffers:version (views:buffer view)))
               ("showing" . ,(views:shown-count view)))))))

(define (view) (layout:selected-view))

(define (mode! b on?) (buffers:with-buffer b (set-option-local! diagnostics:mode on?)))


(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c) (condition-message c) c))])
    (thunk)))

(define (index-of s part)
  (let loop ([i 0])
    (cond
      [(> (+ i (string-length part)) (string-length s)) #f]
      [(string=? (substring s i (+ i (string-length part))) part) i]
      [else (loop (+ i 1))])))

(define (text b) (document:text (buffers:document b)))

;; A diagnostic as its range's text, its severity and its message.
(define (seen d)
  (let ([b (diagnostics:diagnostic-buffer d)])
    (list (if b
              (document:text (buffers:document b) (diagnostics:diagnostic-start d) (diagnostics:diagnostic-end d))
              (list (diagnostics:diagnostic-start d) (diagnostics:diagnostic-end d)))
          (diagnostics:diagnostic-severity d) (diagnostics:diagnostic-message d))))

(define (all-seen b) (map seen (diagnostics:in b)))

;; The drawn spans of each severity's layer, as their text and value.
(define (marks b)
  (let ([doc (buffers:document b)])
    (apply append
      (map (lambda (type)
             (map (lambda (s) (list (document:text doc (car s) (cadr s)) (cdr (assq 'face (caddr s)))
                                    (cdr (assq 'title (caddr s)))))
                  (buffers:spans (buffers:layer b type) 0 (document:length doc))))
           (list diagnostics:error-marks diagnostics:warning-marks diagnostics:info-marks diagnostics:hint-marks)))))

(define (word b s)
  (let ([t (text b)])
    (let loop ([i 0])
      (if (string=? (substring t i (+ i (string-length s))) s) (+ i 1) (loop (+ i 1))))))

(define (warn b s message)
  (diagnostics:make-diagnostic (word b s) (+ (word b s) (string-length s)) (diagnostics:severity warning) message))

(define (err b s message)
  (diagnostics:make-diagnostic (word b s) (+ (word b s) (string-length s)) (diagnostics:severity error) message))

(define folder
  (let ([f (format "~a/diagnostics-test" (getenv "HOME"))])
    (unless (file-exists? f) (mkdir f))
    f))

(define notes (buffers:make "notes" "alpha beta gamma\ndelta epsilon\n\nzeta eta\n"))
(layout:switch-to-buffer notes)
(set-idle! #t)
(import (console))

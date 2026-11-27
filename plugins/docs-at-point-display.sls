#!tuna
(import (docs-at-point) (echo-area) (layout) (markdown) (buffers) (document) (views) (modes) (commands) (keys) (haml) (hooks) (options) (tables))

(options:define-option echo-lines #f (lambda (v) (or (not v) (and (fixnum? v) (fx> v 0))))
  "How many lines of docs the echo area shows; #f for as many as it holds.")

(define (%thing-spans doc)
  (let ([thing (docs-at-point:doc-thing doc)] [face (docs-at-point:doc-face doc)])
    (if (and thing face) (list (list 0 (string-length thing) face)) '())))

(define (%echo-line doc)
  (let ([echo (docs-at-point:doc-echo doc)] [thing (docs-at-point:doc-thing doc)])
    (and echo
         (let ([lead (if thing (string-append thing ": ") "")])
           (cons (string-append lead echo)
                 (append
                   (%thing-spans doc)
                   (if (string=? echo (docs-at-point:doc-text doc))
                       (map (lambda (s) (list (fx+ (car s) (string-length lead)) (fx+ (cadr s) (string-length lead)) (caddr s)))
                            (docs-at-point:doc-spans doc))
                       '())))))))

(define (%nth-newline text n)
  (let loop ([i 0] [n n])
    (cond
      [(fx= i (string-length text)) #f]
      [(char=? (string-ref text i) #\newline) (if (fx= n 1) i (loop (fx+ i 1) (fx- n 1)))]
      [else (loop (fx+ i 1) n)])))

(define (%echo-of docs)
  (let loop ([lines (filter values (map %echo-line docs))] [text #f] [spans '()])
    (cond
      [(null? lines)
       (let* ([most (echo-lines)] [cut (and text most (%nth-newline text most))])
         (if cut
             (values (string-append (substring text 0 cut) "…")
                     (filter (lambda (s) (fx< (car s) (cadr s)))
                             (map (lambda (s) (list (car s) (fxmin (cadr s) cut) (caddr s))) spans)))
             (values text spans)))]
      [else
       (let* ([line (car lines)] [at (if text (fx+ (string-length text) 1) 0)])
         (loop (cdr lines)
               (if text (string-append text "\n" (car line)) (car line))
               (append spans (map (lambda (s) (list (fx+ (car s) at) (fx+ (cadr s) at) (caddr s))) (cdr line)))))])))

(define %echo-text #f)
(define %echo-spans '())
(define %echoed #f)

;; The place the docs are about: the view's number and, weakly, the
;; buffer it showed, so neither a dropped view nor a killed buffer is held.
(define %echo-view-id #f)
(define %echo-buffer (weak-cons #f #f))

;; A message other than the docs shown last belongs to someone else, and
;; docs never cover it.
(define (%echo!)
  (let ([current (echo-area:current-message)])
    (unless (and current (not (equal? current %echoed)))
      (cond
        [%echo-text
         (%say! %echo-text %echo-spans)
         (set! %echoed %echo-text)]
        [else
         (when current (%say! "" '()))
         (set! %echoed #f)]))))

(define (%say! text spans)
  (options:with ([echo-area:log-max 0])
    (parameterize ([echo-area:spans spans])
      (echo-area:message! "~a" text))))

(define (%clear-own!)
  (when (and %echoed (equal? (echo-area:current-message) %echoed))
    (%say! "" '()))
  (set! %echoed #f))

;; Docs describe their view's buffer: shown where the user is in another
;; buffer, a prompt's included, they would describe what the user is not
;; looking at, and where the mode is off the user has turned them off.
(define (%at-docs-place?)
  (let ([view (layout:selected-view)])
    (and view (eqv? (views:id view) %echo-view-id) (views:buffer view)
         (eq? (views:buffer view) (car %echo-buffer))
         (views:call-with-view view docs-at-point:mode))))

(define (show-in-echo-area view docs asked?)
  (let-values ([(text spans) (%echo-of docs)])
    (set! %echo-text text)
    (set! %echo-spans spans)
    (set! %echo-view-id (views:id view))
    (set! %echo-buffer (weak-cons (views:buffer view) #f))
    (if (or asked? (%at-docs-place?)) (%echo!) (%clear-own!))))

;; Kept when cleared, so they show again once the user is back at their
;; place, where no new ask comes since the place is the last ask's.
(define (%show-again command)
  (when %echo-text
    (if (%at-docs-place?) (%echo!) (%clear-own!))))

(tables:define-table docs-keymap "The keymap of docs-at-point-display:docs-mode.")

(hooks:define-hook docs-mode-hook "Called in each buffer that turns on docs-at-point-display:docs-mode.")

(modes:define-major-mode docs-mode
  (parent modes:special)
  (lighter "Docs")
  (keymap docs-keymap)
  (hook docs-mode-hook)
  (plugin-only #t))

(define (%draw-page node view) (haml (:div (views:draw-children view node))))

(buffers:define-kind %page (content nodes) (draw %draw-page))

;; The docs are written with splice!, which asks no layer, and nothing
;; else may edit them.
(buffers:define-layer %read-only (read-only) (sticky both))

(buffers:define-layer %faces)

(define %buffer #f)

;; The view's number, not the view, so a dropped view is not held.
(define %view-id #f)

(define (%docs-buffer)
  (unless (and %buffer (buffers:live? %buffer))
    (let ([b (or (buffers:find "*Docs*") (buffers:make "*Docs*" (%page '())))])
      (buffers:set-silent! b #t)
      (modes:set-major-mode docs-mode b)
      (set! %buffer b)))
  %buffer)

(define (%datums-and-spans doc)
  (append
    (if (docs-at-point:doc-thing doc)
        (list (cons (markdown:heading (list (cons 'level 2)) (string-append (docs-at-point:doc-thing doc) "\n"))
                    (%thing-spans doc)))
        '())
    (if (docs-at-point:doc-markdown? doc)
        (map (lambda (block) (cons block '())) (markdown:blocks (docs-at-point:doc-text doc)))
        (list (cons (markdown:code-block (list (cons 'language "")) (string-append (docs-at-point:doc-text doc) "\n"))
                    (docs-at-point:doc-spans doc))))))

;; Each block's spans count from its text, which starts after its node's
;; opening.
(define (%block-spans b pairs)
  (let* ([doc (buffers:document b)] [starts '()])
    (document:for-each-child (document:token doc 0) 0 (document:length doc)
      (lambda (child at) (when (document:node? child) (set! starts (cons at starts)))))
    (apply append
      (map (lambda (pair start)
             (map (lambda (s) (list (fx+ start 1 (car s)) (fx+ start 1 (cadr s)) (list (cons 'face (caddr s))))) (cdr pair)))
           pairs (reverse starts)))))

(define (show-in-buffer view docs asked?)
  (when (or asked? (and %buffer (buffers:live? %buffer)))
    (let* ([b (%docs-buffer)] [doc (buffers:document b)] [pairs (apply append (map %datums-and-spans docs))])
      (set! %view-id (views:id view))
      (buffers:splice! b 0 (document:length doc) (document:from-datum (apply %page '() (map car pairs))))
      (let ([n (document:length (buffers:document b))])
        (buffers:set-spans! (buffers:layer b %read-only) 0 n (list (list 0 n '())))
        (buffers:set-spans! (buffers:layer b %faces) 0 n (%block-spans b pairs)))
      (when asked?
        (views:set-point! (layout:display-buffer b) 0)))))

(commands:define-command (refresh)
  "Asks the sources again for the view the docs in *Docs* are about."
  (unless %view-id
    (error 'docs-at-point-display:refresh "No docs to refresh"))
  (let ([view (views:find %view-id)])
    (unless view
      (error 'docs-at-point-display:refresh "The view the docs are about is gone"))
    (docs-at-point:ask-sources view)))

(commands:define-command (show-docs)
  "Shows the docs at point in *Docs* and the echo area, asking the sources now; in *Docs*, asks again for the view its docs are about."
  (let ([view (layout:selected-view)])
    (if (and %buffer (eq? (views:buffer view) %buffer))
        (refresh)
        (docs-at-point:ask-sources view))))

(define (%set-up-docs-buffer)
  (options:set-local! buffers:revert-function refresh)
  (options:set-local! docs-at-point:mode #f))

(hooks:add! docs-mode-hook %set-up-docs-buffer)
(hooks:add! docs-at-point:displays show-in-echo-area)
(hooks:add! docs-at-point:displays show-in-buffer)
(hooks:add! commands:after-command %show-again)
(keys:bind! keys:global "C-h ." show-docs)

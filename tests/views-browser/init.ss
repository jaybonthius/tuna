(import (tuna) (tuna plugins) (haml))
(use-plugin jobs)
(use-plugin document)
(use-plugin buffers)
(use-plugin commands)
(use-plugin web)
(use-plugin design-tokens)
(use-plugin faces)
(use-plugin views)
(use-plugin kill-ring)
(use-plugin keys)
(use-plugin ui)
(use-plugin layout)
(use-plugin repeat)
(use-plugin layout-split)
(use-plugin layout-tabs)
(use-plugin modes)
(use-plugin files)
(use-plugin undo)
(use-plugin editing)
(use-plugin echo-area)
(use-plugin status-line)
(use-plugin minibuffer)
(use-plugin completion)
(use-plugin completion-list)
(use-plugin command-picker)
(use-plugin line-picker)
(use-plugin jump-history)
(use-plugin search)
(use-plugin isearch)
(use-plugin xref)
(use-plugin command-line)
(use-plugin markdown)
(use-plugin chat)
(use-plugin transient)
(import (console))

(define (sv) (layout:selected-view))
(define (run-command c . args) (views:with-view (sv) (apply commands:run c args)))

(define (padded n width)
  (let ([s (number->string n)])
    (string-append (make-string (max 0 (- width (string-length s))) #\0) s)))

;; Lines "line 001" to "line N", each ending in a newline.
(define (numbered-lines n width)
  (let loop ([i n] [acc '()])
    (if (= i 0) (apply string-append acc) (loop (- i 1) (cons (string-append "line " (padded i width) "\n") acc)))))

(define (show! name content)
  (let ([b (buffers:find name)])
    (when b (buffers:kill! b))
    (layout:switch-to-buffer (buffers:make name content))
    #t))

(define (show-lines! n) (show! "*lines*" (numbered-lines n (max 3 (string-length (number->string n))))))

(define (wrap! on?) (views:set-option! (sv) views:wrap-lines on?) #t)

(define (line-start n) (document:line-start (buffers:document (views:buffer (sv))) n))
(define (line-of p) (document:line (buffers:document (views:buffer (sv))) p))
;; A buffer's text starts at position 1, after its node's opening.
(define (column-of p) (- p (max 1 (line-start (line-of p)))))

;; Point as line and column, and the line at the view's top in the page
;; of the only client.
(define (point-at) (let ([p (views:point (sv))]) (list (line-of p) (column-of p))))
(define (top-line) (line-of (views:top (sv) (car (web:clients)))))

(define (goto-line! n) (views:set-point! (sv) (line-start n)) #t)

;; A chat of replies whose paragraphs hold emphasis and code, drawn by the
;; chat and markdown plugins as Pi's chats are.
(define (chat-reply k)
  `(chat:reply ()
     ,@(markdown:blocks
         (format "Reply ~a explains *this* and `that` at some length, so that a narrow view wraps it onto rows of its own.\n\nA second paragraph, with a [link](https://example.org) and **strong** words, follows the first.\n\n- one item\n- two items\n" k))))

(define (show-chat! n)
  (show! "*chat*" `(chat:transcript () ,@(map chat-reply (iota n))))
  (wrap! #t))

;; Ten short lines, a line of 300 characters, ten more short lines.
(define (show-long-line!)
  (show! "*long*"
    (string-append (numbered-lines 10 2)
                   (apply string-append (map (lambda (i) (string (integer->char (+ 97 (mod i 26))))) (iota 300))) "\n"
                   (let loop ([i 10] [acc '()]) (if (= i 0) (apply string-append acc) (loop (- i 1) (cons (format "after ~a\n" (padded (- i 1) 2)) acc))))))
  (wrap! #f))

(define (rows-buffer! n)
  (let ([b (or (buffers:find "*rows*") (buffers:make "*rows*" (ui:list '())))])
    (ui:set-rows! b (document:token (buffers:document b) 0) n (lambda (i) (ui:label (format "row ~a" i))) (lambda (i) #f))
    (layout:switch-to-buffer b)
    #t))

(define (fold-lines! from to) (views:fold! (sv) (line-start from) (- (line-start (+ to 1)) 1)) #t)
(define (unfold-lines! from) (views:unfold! (sv) (line-start from)) #t)

(define (show-view-html) (html->string (views:draw (sv) (car (web:clients)))))

;; Mouse items that reach Tuna, so a test sees a press the browser kept.
(define mouse-items 0)
(let ([handle (table-ref web:input-handlers "mouse")])
  (table-set! web:input-handlers "mouse" (lambda (client item) (set! mouse-items (+ mouse-items 1)) (handle client item))))

(define (hand-moves-point! on?) (views:set-option! (sv) views:hand-scroll-moves-point on?) #t)

;; A file whose second line calls what line 150 defines, and a backend
;; that finds the definition, as M-. finds one.
(define (target-lines)
  (string-append ";;; target.el\n" "(defun scrolling-caller () (scrolling-target-function))\n"
                 (apply string-append (map (lambda (i) (format ";; filler ~a\n" (padded (+ i 3) 3))) (iota 147)))
                 "(defun scrolling-target-function ()\n  \"Target.\"\n  42)\n"
                 (apply string-append (map (lambda (i) (format ";; filler ~a\n" (padded (+ i 153) 3))) (iota 47)))))

(define target-backend
  (xref:backend "target"
    [identifier-at-point (lambda (v) "scrolling-target-function")]
    [definitions (lambda (name) (list (xref:make-item name (string-append (current-directory) "/target.el") 150 0)))]))

(add-hook! xref:backends (lambda (view) target-backend))

(define (show-target!)
  (let ([path (string-append (current-directory) "/target.el")])
    (when (file-exists? path) (delete-file path))
    (with-output-to-file path (lambda () (display (target-lines))))
    (layout:switch-to-buffer (files:visit path))
    (views:set-point! (sv) (+ (line-start 2) 44))
    #t))

;; Atoms standing alone between lines of text, each drawn as a row.
(define (draw-cell node view) (haml (:div.cell "cell")))
(buffers:define-kind cells)
(buffers:define-kind cell (content atom) (draw draw-cell))

;; A hundred groups of three cells, each group its own node.
(define (show-cells!)
  (show! "*cells*"
    (apply buffers:text '() "head\n"
      (append (apply append (map (lambda (i) (list (cells '() (cell '()) (cell '()) (cell '())) "\n")) (iota 100)))
              (list "tail\n")))))

;; The start of group K's node.
(define (group-start k)
  (let ([doc (buffers:document (views:buffer (sv)))])
    (let loop ([p 0] [k k])
      (let ([t (document:token doc p)])
        (cond
          [(and (document:node? t) (eq? (document:node-kind t) (buffers:kind-name (buffers:constructor-kind cells))))
           (if (= k 0) p (loop (document:node-end t) (- k 1)))]
          [else (loop (+ p 1) k)])))))

(define (tail! on?) (views:set-option! (sv) views:tail on?) #t)

(define (append-lines! n)
  (let ([b (views:buffer (sv))])
    (buffers:insert! b (- (document:length (buffers:document b)) 1) (numbered-lines n 3))
    #t))

(define (insert-lines-at! line n)
  (buffers:insert! (views:buffer (sv)) (line-start line) (numbered-lines n 3))
  #t)

(define (narrow-lines! from to) (views:narrow! (sv) (line-start from) (line-start (+ to 1))) #t)
(define (widen!) (views:widen! (sv)) #t)

;; A list of N rows with a heading over each group of ten.
(define (grouped-rows! n)
  (let ([b (or (buffers:find "*grouped*") (buffers:make "*grouped*" (ui:list '())))])
    (ui:set-rows! b (document:token (buffers:document b) 0) n (lambda (i) (ui:label (format "row ~a" i))) (lambda (i) #f)
                  (lambda (i) (format "group ~a" (quotient i 10))))
    (layout:switch-to-buffer b)
    #t))

(commands:define-command (menu-entry) "Does nothing." (void))
(transient:define-menu small-menu "A menu of one entry." (title "Menu"))
(transient:add! small-menu "Actions" (transient:command "e" "Entry" menu-entry))
(define (show-menu!) (transient:show! small-menu) #t)

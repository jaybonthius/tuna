#!tuna
(import (web) (keys) (layout) (views) (buffers) (document) (haml))

(define-record-type %page
  (sealed #t)
  (fields (mutable screen) (mutable sxml) (mutable title) (mutable calls) (mutable reports) answer))

(define %pages (make-weak-eq-hashtable))

(define %answered? #f)

(define open-client
  (case-lambda
    [() (open-client (lambda (name value) 'null))]
    [(answer)
     (unless (procedure? answer)
       (assertion-violation 'test-user:open-client "not a procedure" answer))
     (let* ([page (make-%page #f #f #f '() 0 answer)]
            [client (web:open-client
                      (lambda (client screen title)
                        (%page-screen-set! page screen)
                        (%page-sxml-set! page #f)
                        (%page-title-set! page title))
                      (lambda (client name value) (%page-calls-set! page (cons (cons name value) (%page-calls page))))
                      (lambda (client name value)
                        (set! %answered? #t)
                        ((%page-answer page) name value)))])
       (hashtable-set! %pages client page)
       client)]))

(define %first (open-client))

(define (client) %first)

(define (%page-of who client)
  (or (hashtable-ref %pages client #f)
      (assertion-violation who "not a client test-user opened" client)))

;; A task spawned now runs after the tasks queued before it, and the
;; resume it queues while this task is paused runs only once their batch
;; has ended, so the screens are drawn by then.
(define (%wait-for-batch)
  (suspend (lambda (resume) (spawn-task (lambda (restore) (resume void))))))

;; A task the batch woke, such as a command that a key's read or a
;; prompt's answer resumed, continues only in the next batch, and no
;; kernel name tells whether one was woken, so a second wait always
;; follows. A page answers in a draw, so a command that asked it more
;; than once continues later still.
(define (settle)
  (set! %answered? #f)
  (%wait-for-batch)
  (%wait-for-batch)
  (when %answered? (settle)))

;; Each key is posted once Tuna has handled the one before, as a user who
;; types after the screen changes does, so its quit mark is the one the
;; page would have from keys by then: none while a command reads a key.
(define (%press-key! client key)
  (web:post-input! client
    (if (member key (keys:page-quit-keys client))
        (list (cons "type" "key") (cons "name" key) (cons "quit" #t))
        (list (cons "type" "key") (cons "name" key))))
  (settle))

(define press!
  (case-lambda
    [(keys) (press! %first keys)]
    [(client keys)
     (%page-of 'test-user:press! client)
     (for-each (lambda (key) (%press-key! client key)) (keys:sequence-keys keys))]))

(define (%char-key c)
  (case c
    [(#\space) "SPC"]
    [(#\newline) "RET"]
    [(#\tab) "TAB"]
    [else (and (not (eq? (char-general-category c) 'Cc)) (string c))]))

(define type!
  (case-lambda
    [(text) (type! %first text)]
    [(client text)
     (%page-of 'test-user:type! client)
     (unless (string? text)
       (assertion-violation 'test-user:type! "not a string" text))
     (let ([keys (map %char-key (string->list text))])
       (unless (for-all values keys)
         (assertion-violation 'test-user:type! "a character that is no key" text))
       (for-each (lambda (key) (%press-key! client key)) keys))]))

(define (%check-point-mark who point-mark)
  (unless (char? point-mark)
    (assertion-violation who "not a character" point-mark)))

(define show!
  (case-lambda
    [(text) (show! text #\|)]
    [(text point-mark)
     (unless (string? text)
       (assertion-violation 'test-user:show! "not a string" text))
     (%check-point-mark 'test-user:show! point-mark)
     (let ([marks (filter (lambda (i) (char=? (string-ref text i) point-mark)) (iota (string-length text)))])
       (unless (= (length marks) 1)
         (assertion-violation 'test-user:show! "not one point mark in the text" text point-mark))
       (let* ([at (car marks)]
              [b (buffers:make (buffers:free-name "*test*")
                   (string-append (substring text 0 at) (substring text (fx+ at 1) (string-length text))))]
              [v (layout:selected-view)])
         (views:set-buffer! v b)
         (views:set-point! v (document:position (buffers:document b) at (document:unit characters)))))]))

(define text
  (case-lambda
    [() (text #\|)]
    [(point-mark)
     (%check-point-mark 'test-user:text point-mark)
     (let* ([v (layout:selected-view)] [doc (buffers:document (views:buffer v))] [at (views:point v)])
       (string-append (buffers:text-between doc 0 at) (string point-mark)
                      (buffers:text-between doc at (document:length doc))))]))

(define (%given who client accessor)
  (let ([page (%page-of who client)])
    (unless (%page-screen page)
      (assertion-violation who "no screen has been given to the client" client))
    (accessor page)))

(define (%sxml who client)
  (let ([page (%page-of who client)])
    (or (%page-sxml page)
        (let ([sxml (html->sxml (%given who client %page-screen))])
          (%page-sxml-set! page sxml)
          sxml))))

(define screen
  (case-lambda
    [() (screen %first)]
    [(client) (%sxml 'test-user:screen client)]))

(define title
  (case-lambda
    [() (title %first)]
    [(client) (%given 'test-user:title client %page-title)]))

(define (%element? v)
  (and (list? v) (pair? v) (symbol? (car v)) (not (eq? (car v) '\x40;))))

(define (%check-element who v)
  (unless (%element? v)
    (assertion-violation who "not an SXML element" v)))

(define (%attributes element)
  (let ([rest (cdr element)])
    (if (and (pair? rest) (pair? (car rest)) (eq? (caar rest) '\x40;)) (cdar rest) '())))

(define (%children element)
  (let ([rest (cdr element)])
    (if (and (pair? rest) (pair? (car rest)) (eq? (caar rest) '\x40;)) (cdr rest) rest)))

(define (%attribute element name)
  (let ([a (find (lambda (a) (string=? (symbol->string (car a)) name)) (%attributes element))])
    (and a (cadr a))))

(define (%words value)
  (let loop ([chars (string->list value)] [word '()] [words '()])
    (let ([add (lambda () (if (null? word) words (cons (list->string (reverse word)) words)))])
      (cond
        [(null? chars) (reverse (add))]
        [(char-whitespace? (car chars)) (loop (cdr chars) '() (add))]
        [else (loop (cdr chars) (cons (car chars) word) words)]))))

(define (%elements-where sxml keep?)
  (let walk ([node sxml])
    (if (%element? node)
        (let ([below (apply append (map walk (%children node)))])
          (if (keep? node) (cons node below) below))
        '())))

(define (elements sxml class)
  (%check-element 'test-user:elements sxml)
  (unless (string? class)
    (assertion-violation 'test-user:elements "not a string" class))
  (%elements-where sxml
    (lambda (node)
      (let ([value (%attribute node "class")])
        (and value (member class (%words value)))))))

(define (elements-with sxml name)
  (%check-element 'test-user:elements-with sxml)
  (unless (string? name)
    (assertion-violation 'test-user:elements-with "not a string" name))
  (%elements-where sxml (lambda (node) (%attribute node name))))

(define (element-text element)
  (%check-element 'test-user:element-text element)
  (call-with-string-output-port
    (lambda (p)
      (let walk ([node element])
        (cond
          [(string? node) (put-string p node)]
          [(%element? node) (for-each walk (%children node))])))))

(define (element-attribute element name)
  (%check-element 'test-user:element-attribute element)
  (unless (string? name)
    (assertion-violation 'test-user:element-attribute "not a string" name))
  (%attribute element name))

(define (%ancestry root element)
  (let walk ([node root] [above '()])
    (cond
      [(eq? node element) (cons node above)]
      [(%element? node) (exists (lambda (child) (walk child (cons node above))) (%children node))]
      [else #f])))

(define (%out-to-view ancestry)
  (let loop ([chain ancestry] [kept '()])
    (cond
      [(null? chain) #f]
      [(%attribute (car chain) "data-view") (reverse (cons (car chain) kept))]
      [else (loop (cdr chain) (cons (car chain) kept))])))

;; A view's own elements stop at a view drawn inside it, whose clicks are
;; its own.
(define (%own-elements view-element keep?)
  (let walk ([node view-element])
    (if (and (%element? node) (or (eq? node view-element) (not (%attribute node "data-view"))))
        (let ([below (apply append (map walk (%children node)))])
          (if (and (not (eq? node view-element)) (keep? node)) (cons node below) below))
        '())))

(define (%number element name) (string->number (%attribute element name)))

;; A mark is the keymap's number and a word for the page; an item
;; carries the number alone.
(define (%keymaps chain)
  (fold-right (lambda (e marks)
                (let ([mark (%attribute e "data-keymap")])
                  (if mark (cons (string->number (car (%words mark))) marks) marks)))
              '() chain))

(define (%view-element who client view)
  (let ([id (number->string (views:id view))])
    (or (find (lambda (e) (equal? id (%attribute e "data-view")))
              (%elements-where (%sxml who client) (lambda (e) (%attribute e "data-view"))))
        (assertion-violation who "the view is not on the client's last screen" view))))

;; A user clicks what the client was last drawn, so the view's version,
;; its showing count and the keymap marks come from that screen, and text
;; on a line not drawn cannot be clicked.
(define (%text-ancestry who client view position)
  (unless (views:view? view)
    (assertion-violation who "not a view" view))
  (let ([b (views:buffer view)])
    (unless b
      (assertion-violation who "a view showing no buffer" view))
    (let ([doc (buffers:document b)])
      (unless (and (fixnum? position) (fx<= 0 position) (fx< position (document:length doc)))
        (assertion-violation who "not a position in the view's buffer" position))
      (let* ([view-element (%view-element who client view)]
             [line (number->string (document:line doc position))]
             [lines (%own-elements view-element
                      (lambda (e)
                        (and (equal? line (%attribute e "data-line"))
                             (member "line" (%words (or (%attribute e "class") ""))))))])
        (when (null? lines)
          (assertion-violation who "the position's line is not drawn" position))
        (%ancestry view-element (car lines))))))

(define (%text-place position) (list (cons "at" position) (cons "count" 0)))

;; An element is pressed off any text of its own, where the page names
;; the tokens of the innermost element standing for them.
(define (%element-press who client element)
  (let ([chain (%ancestry (%sxml who client) element)])
    (unless chain
      (assertion-violation who "not an element of the client's last screen" element))
    (let ([own (%out-to-view chain)])
      (unless own
        (assertion-violation who "an element in no view" element))
      (let ([token (find (lambda (e)
                           (and (%attribute e "data-to") (not (%attribute e "data-view"))
                                (not (member "segment" (%words (or (%attribute e "class") ""))))))
                         own)])
        (unless token
          (assertion-violation who "an element that stands for no tokens" element))
        (values (car (last-pair own)) (list (cons "token" (%number token "data-at"))) (%keymaps own))))))

;; keys reads a mouse key's parts only from an event, so the key is put
;; in one; the item made of them must name the key back.
(define (%button-fields who key action)
  (let ([event (and (string? key) (if (eq? action 'drag) (list key #t #t) (list key #t)))])
    (unless (and event (keys:event? event) (memq action (keys:event-modifiers event)))
      (assertion-violation who (if (eq? action 'drag) "not a mouse drag key" "not a mouse click key") key))
    (let* ([type (symbol->string (keys:event-basic-type event))]
           [fields (list (cons "button" (string->number (substring type 6 (string-length type))))
                         (cons "clicks" (keys:event-clicks event))
                         (cons "modifiers"
                               (list->vector
                                 (fold-right (lambda (m names)
                                               (case m
                                                 [(control) (cons "control" names)]
                                                 [(meta) (cons "alt" names)]
                                                 [(shift) (cons "shift" names)]
                                                 [(super) (cons "super" names)]
                                                 [else names]))
                                             '() (keys:event-modifiers event)))))])
      (unless (equal? key (keys:item-key (cons* (cons "type" "mouse") (cons "action" (symbol->string action)) fields)))
        (assertion-violation who "not a mouse key a page sends" key))
      fields)))

(define (%press-fields button-fields keymaps)
  (if (null? keymaps)
      button-fields
      (append button-fields (list (cons "keymaps" (list->vector keymaps))))))

(define (%mouse-item view-element action place fields)
  (append (list (cons "type" "mouse") (cons "action" action) (cons "view" (%number view-element "data-view"))
                (cons "version" (%number view-element "data-version"))
                (cons "showing" (%number view-element "data-showing")))
          place fields))

(define (%post-click! client view-element place fields)
  (web:post-input! client (%mouse-item view-element "down" place fields))
  (web:post-input! client (%mouse-item view-element "click" place fields))
  (settle))

(define click!
  (case-lambda
    [(view position) (click! %first view position "<mouse-1>")]
    [(view position key) (click! %first view position key)]
    [(client view position key)
     (let ([ancestry (%text-ancestry 'test-user:click! client view position)])
       (%post-click! client (car (last-pair ancestry)) (%text-place position)
                     (%press-fields (%button-fields 'test-user:click! key 'click) (%keymaps ancestry))))]))

(define click-element!
  (case-lambda
    [(element) (click-element! %first element "<mouse-1>")]
    [(element key) (click-element! %first element key)]
    [(client element key)
     (let-values ([(view-element place keymaps) (%element-press 'test-user:click-element! client element)])
       (%post-click! client view-element place
                     (%press-fields (%button-fields 'test-user:click-element! key 'click) keymaps)))]))

;; A move carries a report number, as the page's does, which the view's
;; next screen gives back.
(define drag!
  (case-lambda
    [(view from to) (drag! %first view from to "<drag-mouse-1>")]
    [(view from to key) (drag! %first view from to key)]
    [(client view from to key)
     (let* ([ancestry (%text-ancestry 'test-user:drag! client view from)]
            [view-element (car (last-pair ancestry))]
            [fields (%press-fields (%button-fields 'test-user:drag! key 'drag) (%keymaps ancestry))]
            [page (%page-of 'test-user:drag! client)])
       (%text-ancestry 'test-user:drag! client view to)
       (%page-reports-set! page (fx+ (%page-reports page) 1))
       (web:post-input! client (%mouse-item view-element "down" (%text-place from) fields))
       (web:post-input! client
         (%mouse-item view-element "move" (%text-place to)
                      (list (cons "modifiers" (vector)) (cons "report" (%page-reports page)))))
       (web:post-input! client (%mouse-item view-element "drag" (%text-place to) fields))
       (settle))]))

(define take-page-calls!
  (case-lambda
    [() (take-page-calls! %first)]
    [(client)
     (let* ([page (%page-of 'test-user:take-page-calls! client)] [calls (reverse (%page-calls page))])
       (%page-calls-set! page '())
       calls)]))

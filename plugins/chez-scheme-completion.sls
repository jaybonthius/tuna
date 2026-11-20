#!tuna
(import (completion) (chez-scheme) (syntax) (buffers) (document) (views))

;; The entry runs after every command while its session lives, so the
;; candidates of a names vector are made once and kept while it lives.
(define %sources (make-weak-eq-hashtable))

(define (%make-sources names keep?)
  (let ([tuna (chez-scheme:tuna-libraries)])
    (let loop ([i (fx- (vector-length names) 1)] [described '()] [others '()])
      (if (fx< i 0)
          (list (completion:source (candidates (list->vector described)) (category completion:name-category))
                (completion:source (candidates (list->vector others)) (category completion:identifier-category)))
          (let* ([name (vector-ref names i)]
                 [text (symbol->string (chez-scheme:name-spelling name))]
                 [kind (chez-scheme:name-kind name)])
            (cond
              [(not (keep? kind)) (loop (fx- i 1) described others)]
              [(member (chez-scheme:name-library name) tuna)
               (loop (fx- i 1) (cons (vector text (chez-scheme:name-export name) kind) described) others)]
              [else (loop (fx- i 1) described (cons (vector text text kind) others))]))))))

;; As Emacs's elisp-completion-at-point offers only functions and macros
;; at a call's head: a variable there is never what is meant.
(define (%callable? kind) (not (eq? kind (chez-scheme:binding-kind variable))))

(define (%any-kind? kind) #t)

(define (%sources-for buffer head?)
  (let* ([names (chez-scheme:names buffer)]
         [both (or (eq-hashtable-ref %sources names #f)
                   (let ([both (cons (%make-sources names %any-kind?) (%make-sources names %callable?))])
                     (eq-hashtable-set! %sources names both)
                     both))])
    (if head? (cdr both) (car both))))

;; A bracket quoted or written as #( opens data, not a call, and a square
;; bracket opens a clause or a binding, whose first symbol may be a
;; variable.
(define (%head? doc start)
  (and (fx> start 0)
       (eqv? (document:token doc (fx- start 1)) #\()
       (not (and (fx> start 1) (memv (document:token doc (fx- start 2)) '(#\' #\` #\#))))))

;; In ,@name the @ belongs to the unquote, though Scheme's symbols may
;; hold it.
(define (%name-start doc start end)
  (if (and (fx> start 0) (fx< start end)
           (eqv? (document:token doc start) #\@)
           (eqv? (document:token doc (fx- start 1)) #\,))
      (fx+ start 1)
      start))

(define (name-region)
  (let* ([view (views:current)] [buffer (and view (views:buffer view))])
    (and buffer
         (let ([point (views:point view)])
           (let-values ([(start end) (syntax:symbol-bounds buffer point chez-scheme:mode)])
             (and start
                  (let ([start (%name-start (buffers:document buffer) start end)])
                    (and (fx<= start point)
                         (completion:region start end
                           (%sources-for buffer (%head? (buffers:document buffer) start)))))))))))

(define (%add-name-region) (add-local-hook! completion:find-region name-region))

(add-hook! chez-scheme:mode-hook %add-name-region)

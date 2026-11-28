#!tuna
(import (completion) (buffers) (document) (views) (syntax) (syntax characters) (modes) (commands) (keys) (jobs) (ask) (hooks) (options))

(define %self (current-owner))

(completion:define-category word-category "Words already written in buffers, valued by the word.")

(define (%same-major-mode? buffer)
  (eq? (modes:major-mode buffer) (modes:major-mode (buffers:current))))

(define (%internal-or-messages? buffer)
  (let ([name (buffers:name buffer)])
    (or (buffers:internal-name? name) (string=? name "*Messages*"))))

(define (%no-buffer? buffer) #f)

(options:define-option check-other-buffers #t boolean?
  "Whether dabbrev:expand also looks in buffers other than the current one: the friend buffers, then, with dabbrev:check-all-buffers, the rest.")

(options:define-option check-all-buffers #t boolean?
  "Whether dabbrev:expand looks in every buffer dabbrev:ignored-buffer-predicate does not ignore, after the friend buffers.")

(options:define-option friend-buffer-predicate %same-major-mode? procedure?
  "A procedure of a buffer that returns true when dabbrev looks in it right after the current buffer; by default, when its major mode is the current buffer's.")

(options:define-option ignored-buffer-predicate %internal-or-messages? procedure?
  "A procedure of a buffer that returns true when dabbrev never looks in it; by default, for internal buffers and *Messages*.")

(options:define-option region-buffer-predicate %no-buffer? procedure?
  "A procedure of a buffer that returns true when dabbrev:word-region also offers its words; by default, for none, so only the current buffer's.")

(options:define-option case-fold-search #t boolean?
  "Whether dabbrev finds words whatever their case.")

(options:define-option upcase-means-case-search #f boolean?
  "Whether an abbreviation with a capital letter finds only words in its case, even while dabbrev:case-fold-search is true.")

(options:define-option backward-only #f boolean?
  "Whether dabbrev:expand looks only before point in the current buffer, before it looks in other buffers.")

(options:define-option case-replace #t boolean?
  "Whether, while dabbrev:case-fold-search is true, an expansion takes the case of the text it replaces.")

(options:define-option case-distinction #t boolean?
  "Whether, while dabbrev:case-fold-search is true, words that differ only in case count as one expansion.")

(jobs:define-worker (%expansions input emit receive)
  (import (dabbrev words))
  (apply
    (lambda (abbrev fold? distinct? recase? items)
      (let ([find (make-expansion-finder abbrev fold? distinct?)])
        (let loop ([items items] [index 0])
          (unless (null? items)
            (apply search-words
              (append (car items)
                      (list find
                            (lambda (found)
                              (emit (cons index (list->vector found)))
                              (receive)))))
            (loop (cdr items) (fx+ index 1))))))
    input))

(jobs:define-worker (%completions input emit)
  (import (dabbrev words))
  (apply
    (lambda (abbrev fold? distinct? recase? items)
      (let* ([find (make-expansion-finder abbrev fold? distinct?)]
             [capitalize (lambda (word)
                           (let ([out (string-downcase word)])
                             (let loop ([i 0] [after-word? #f])
                               (when (fx< i (string-length out))
                                 (let ([c (string-ref out i)])
                                   (unless after-word? (string-set! out i (char-upcase c)))
                                   (loop (fx+ i 1) (or (char-alphabetic? c) (char-numeric? c))))))
                             out))]
             [cased (cond
                      [(not recase?) (lambda (word) word)]
                      [(string=? abbrev (string-upcase abbrev)) string-upcase]
                      [(char-upper-case? (string-ref abbrev 0)) capitalize]
                      [else string-downcase])])
        (for-each
          (lambda (item)
            (apply search-words
              (append item (list find (lambda (found) (emit (list->vector (map cased found))))))))
          items)))
    input))

(define (%characters buffer)
  (string-append (syntax:buffer-word-characters buffer) (syntax:buffer-symbol-characters buffer)))

;; The worker reads back from before and on from after, so the symbol
;; being expanded, between them, is never one of the words.
(define (%item buffer before after)
  (list (buffers:document buffer) (%characters buffer) before after))

(define (%whole buffer) (%item buffer 0 0))

(define (%shown? buffer) (pair? (views:showing buffer)))

(define (%searchable-buffers buffer)
  (let ([ignored? (ignored-buffer-predicate)])
    (filter (lambda (b) (not (or (eq? b buffer) (ignored? b)))) (buffers:all))))

(define (%other-buffers buffer all?)
  (let* ([others (%searchable-buffers buffer)]
         [friend? (friend-buffer-predicate)]
         [friends (buffers:with-buffer buffer (filter friend? others))]
         [chosen (if all? (append friends (remp (lambda (b) (memq b friends)) others)) friends)])
    (append (filter %shown? chosen) (remp %shown? chosen))))

(define (%word-before view)
  (let* ([b (views:buffer view)] [point (views:point view)])
    (let-values ([(start end) (syntax:symbol-bounds b point)])
      (if (and start (fx< start point))
          (values start end)
          (values #f #f)))))

(define (%search-input abbrev items)
  (let ([fold? (and (case-fold-search)
                    (or (not (upcase-means-case-search)) (string=? abbrev (string-downcase abbrev))))])
    (list abbrev fold? (and fold? (case-distinction)) (and fold? (case-replace)) items)))

(define (%region others)
  (let ([view (views:current)])
    (and view
         (let-values ([(start end) (%word-before view)])
           (and start
                (let* ([b (views:buffer view)] [point (views:point view)]
                       [abbrev (document:text (buffers:document b) start point)])
                  (completion:fallback-region start point
                    (list (completion:source
                            (job %completions
                                 (%search-input abbrev (cons (%item b start end) (map %whole (filter buffers:live? others)))))
                            (category word-category))))))))))

(define (word-region)
  (let ([view (views:current)])
    (and view
         (let ([b (views:buffer view)])
           (%region (filter (region-buffer-predicate) (%searchable-buffers b)))))))

(commands:define-command (completion [n (and (commands:prefix-argument) (commands:prefix-number))])
  "Completes the text before point from its expansions in the current buffer; with N, also from the friend buffers, and with N of 16, as C-u C-u gives, from every buffer not ignored."
  (let* ([view (views:current)] [b (views:buffer view)]
         [others (cond
                   [(not n) '()]
                   [(eqv? n 16) (%other-buffers b #t)]
                   [else (%other-buffers b #f)])])
    (let-values ([(start end) (%word-before view)])
      (unless start
        (error 'dabbrev:completion "No possible abbreviation preceding point"))
      (let ([abbrev (document:text (buffers:document b) start (views:point view))])
        (completion:start-from-entry (lambda () (%region others))
          (lambda ()
            (ask:message (string-append "No dynamic expansion for ‘" abbrev "’ found" (if n "" " in this-buffer")))))))))

;; One expansion at a time, as Emacs keeps dabbrev's state in globals: M-/
;; right after M-/, with point where the last one left it, goes on. Keys
;; run while an M-/ waits for words, so a second M-/ waits behind it, one
;; that a fresh M-/ replaces does nothing when it wakes, and an expansion
;; is dropped once the text or point it would replace has changed. The
;; job sends one chunk's expansions and waits to be asked again, and is
;; asked only once they are all offered, so a press costs the distance to
;; its next expansion and the queue never holds more than a chunk's.
(define-record-type %expansion
  (sealed #t)
  (fields view buffer abbrev recase? start names (mutable text) (mutable words) (mutable last-index)
          (mutable job) (mutable asked?) (mutable done?) (mutable waiters)))

(define %last #f)

(define (%resume-all! e)
  (let ([waiters (%expansion-waiters e)])
    (%expansion-waiters-set! e '())
    (for-each (lambda (resume) (resume (lambda () #f))) waiters)))

(define (%forget!)
  (let ([e %last])
    (when e
      (set! %last #f)
      (let ([job (%expansion-job e)])
        (when job (jobs:stop! job)))
      (%resume-all! e))))

(define (%start-job! e input)
  (call-as-owner %self
    (lambda ()
      (%expansion-job-set! e
        (jobs:start %expansions input
          (lambda (found)
            (when (eq? %last e)
              (%expansion-words-set! e (map (lambda (word) (cons (car found) word)) (vector->list (cdr found))))
              (%expansion-asked?-set! e #f)
              (%resume-all! e)))
          (lambda (ended)
            (%expansion-done?-set! e #t)
            (%resume-all! e)))))))

(define (%next-word! e)
  (let loop ()
    (cond
      [(not (eq? %last e)) #f]
      [(pair? (%expansion-words e))
       (let ([w (car (%expansion-words e))])
         (%expansion-words-set! e (cdr (%expansion-words e)))
         w)]
      [(%expansion-done? e) #f]
      [else
       (unless (%expansion-asked? e)
         (%expansion-asked?-set! e #t)
         (jobs:send! (%expansion-job e) 'more))
       (let ([mine #f])
         (guard (c [#t (%expansion-waiters-set! e (remq mine (%expansion-waiters e)))
                       (when (eq? %last e) (%forget!))
                       (raise c)])
           (suspend
             (lambda (resume)
               (set! mine resume)
               (%expansion-waiters-set! e (append (%expansion-waiters e) (list resume)))))))
       (loop)])))

(define (%at-end? e view)
  (and (eq? view (%expansion-view e))
       (eq? (views:buffer view) (%expansion-buffer e))
       (not (buffers:anchor-deleted? (%expansion-start e)))
       (let* ([doc (buffers:document (%expansion-buffer e))] [start (buffers:anchor-position (%expansion-start e))]
              [text (%expansion-text e)] [end (fx+ start (string-length text))])
         (and (fx= (views:point view) end)
              (fx<= end (document:length doc))
              (string=? (document:text doc start end) text)))))

(define (%lower? s) (string=? s (string-downcase s)))

(define (%upper? s) (string=? s (string-upcase s)))

(define (%upcase-initials s word?)
  (let ([out (string-copy s)])
    (let loop ([i 0] [previous #\newline])
      (when (fx< i (string-length out))
        (let ([c (string-ref out i)])
          (unless (word? previous)
            (string-set! out i (char-upcase c)))
          (loop (fx+ i 1) c))))
    out))

(define (%case-like original replacement word?)
  (let loop ([i 0] [previous #\newline] [lower? #f] [upper? #f] [plain-initial? #f] [multiletter? #f])
    (if (fx< i (string-length original))
        (let* ([c (string-ref original i)] [initial? (not (word? previous))])
          (cond
            [(char-lower-case? c)
             (loop (fx+ i 1) c #t upper? (or plain-initial? initial?) (or multiletter? (not initial?)))]
            [(char-upper-case? c)
             (loop (fx+ i 1) c lower? #t plain-initial? (or multiletter? (not initial?)))]
            [else (loop (fx+ i 1) c lower? upper? (or plain-initial? initial?) multiletter?)]))
        (cond
          [(and (not lower?) multiletter?) (string-upcase replacement)]
          [(and (not plain-initial?) multiletter?) (%upcase-initials replacement word?)]
          [(and (not plain-initial?) upper?) (string-upcase replacement)]
          [else replacement]))))

(define (%cased e word)
  (let* ([abbrev (%expansion-abbrev e)] [n (string-length abbrev)]
         [first-letter (let loop ([i 0])
                         (cond
                           [(fx= i n) #f]
                           [(char-alphabetic? (string-ref abbrev i)) i]
                           [else (loop (fx+ i 1))]))]
         [rest (substring word 1 (string-length word))])
    (if (and (%expansion-recase? e) first-letter
             (not (and (not (and (or (%lower? rest) (%upper? rest))
                                 (or (%lower? abbrev) (and (%upper? abbrev) (fx> (fx- n first-letter) 1)))))
                       (string=? abbrev (substring word 0 n))))
             (not (and (%lower? word) (%lower? abbrev))))
        (let ([words (syntax:buffer-word-characters (%expansion-buffer e))])
          (%case-like (%expansion-text e) (string-downcase word) (lambda (c) (word-char? c words))))
        word)))

(define (%put! e text)
  (let* ([b (%expansion-buffer e)] [start (buffers:anchor-position (%expansion-start e))]
         [end (fx+ start (string-length (%expansion-text e)))])
    (buffers:replace! b start end text)
    (views:set-point! (%expansion-view e) (fx+ start (string-length text)))
    (%expansion-text-set! e text)))

(define (%expand-next! e)
  (let ([found (%next-word! e)])
    (cond
      [(not (eq? %last e)) (void)]
      [(not (%at-end? e (%expansion-view e))) (%forget!)]
      [found
       (let ([index (car found)])
         (when (fx> index 0)
           (ask:message (string-append "Expansion found in ‘" (list-ref (%expansion-names e) index) "’")))
         (%expansion-last-index-set! e index)
         (%put! e (%cased e (cdr found))))]
      [else
       (let ([abbrev (%expansion-abbrev e)] [again? (%expansion-last-index e)])
         (unless (string=? (%expansion-text e) abbrev)
           (%put! e abbrev))
         (%forget!)
         (error 'dabbrev:expand
           (string-append (if again? "No further dynamic expansion for ‘" "No dynamic expansion for ‘")
                          abbrev "’ found")))])))

(define (%expand-first! view)
  (%forget!)
  (let ([b (views:buffer view)] [point (views:point view)])
    (let-values ([(start end) (%word-before view)])
      (unless start
        (error 'dabbrev:expand "No possible abbreviation preceding point"))
      (let* ([abbrev (document:text (buffers:document b) start point)]
             [others (if (check-other-buffers) (%other-buffers b (check-all-buffers)) '())]
             [after (if (backward-only) (document:length (buffers:document b)) end)]
             [input (%search-input abbrev (cons (%item b start after) (map %whole others)))]
             [e (make-%expansion view b abbrev (cadddr input) (buffers:anchor b start) (map buffers:name (cons b others))
                                 abbrev '() #f #f #t #f '())])
        (set! %last e)
        (%start-job! e input)
        (%expand-next! e)))))

(commands:define-command (expand)
  "Replaces the text before point with the nearest word that starts with it: before point, then after it, then in other buffers. Again right away, it puts the next such word in its place, and with none left, the text first typed."
  (let ([view (views:current)] [e %last])
    (if (and e (eq? (commands:last-command) expand) (%at-end? e view))
        (%expand-next! e)
        (%expand-first! view))))

;; Only M-/ right after M-/ continues an expansion, so once another
;; command ends, the job waiting for a request and the documents it holds
;; are of no use; a press still waiting for words keeps it.
(define (%forget-after command)
  (let ([e %last])
    (when (and e (not (eq? command expand)) (null? (%expansion-waiters e)))
      (%forget!))))

(keys:bind! keys:global "M-/" expand)
(keys:bind! keys:global "C-M-/" completion)
(hooks:add! commands:after-command %forget-after)
(on-unload %forget!)

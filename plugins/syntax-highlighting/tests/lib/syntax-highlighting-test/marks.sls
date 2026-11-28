#!tuna
(import (test-runner) (document) (modes) (auto-mode) (buffers) (views) (jobs) (syntax-highlighting) (syntax-highlighting-test highlight) (hooks) (options) (tables))

(options:define-option mark "#" string? "The character that starts a marked word.")
(options:define-option input-raises? #f boolean? "Whether the input procedure raises.")

(tables:define-table keymap "Keys.")
(hooks:define-hook mode-hook "Setup.")
(modes:define-major-mode mode (keymap keymap) (hook mode-hook) (language "marks"))

(tables:define-table derived-keymap "Keys.")
(hooks:define-hook derived-hook "Setup.")
(modes:define-major-mode derived (parent mode) (keymap derived-keymap) (hook derived-hook))

(tables:define-table own-keymap "Keys.")
(hooks:define-hook own-hook "Setup.")
(modes:define-major-mode own (keymap own-keymap) (hook own-hook) (language "marks"))

(tables:define-table raising-keymap "Keys.")
(hooks:define-hook raising-hook "Setup.")
(modes:define-major-mode raising (keymap raising-keymap) (hook raising-hook))

(tables:define-table ranged-keymap "Keys.")
(hooks:define-hook ranged-hook "Setup.")
(modes:define-major-mode ranged (keymap ranged-keymap) (hook ranged-hook))

(options:define-option range '(0 0) list? "The range the ranged highlighter answers for.")

(tables:define-table pieces-keymap "Keys.")
(hooks:define-hook pieces-hook "Setup.")
(modes:define-major-mode pieces (keymap pieces-keymap) (hook pieces-hook))

(tables:define-table misshapen-keymap "Keys.")
(hooks:define-hook misshapen-hook "Setup.")
(modes:define-major-mode misshapen (keymap misshapen-keymap) (hook misshapen-hook))

(options:define-option shape "not a list" string? "What the misshapen highlighter answers: not a list, or not a layer's spans.")

(tables:define-table unnamed-keymap "Keys.")
(hooks:define-hook unnamed-hook "Setup.")
(modes:define-major-mode unnamed (keymap unnamed-keymap) (hook unnamed-hook))

(tables:define-table unknown-keymap "Keys.")
(hooks:define-hook unknown-hook "Setup.")
(modes:define-major-mode unknown (keymap unknown-keymap) (hook unknown-hook) (language "nothing"))

(tables:define-table counting-keymap "Keys.")
(hooks:define-hook counting-hook "Setup.")
(modes:define-major-mode counting (keymap counting-keymap) (hook counting-hook))

(buffers:define-layer parens (priority -5) (evaporate))

(jobs:define-worker (%marks input emit receive)
  (import (syntax-highlighting job) (syntax-highlighting-test highlight))
  (serve input emit receive (make-marks-highlight)))

(jobs:define-worker (%counting input emit receive)
  (import (syntax-highlighting job) (syntax-highlighting-test highlight))
  (serve input emit receive (make-counting-highlight)))

(jobs:define-worker (%raising input emit receive)
  (import (syntax-highlighting job) (syntax-highlighting-test highlight))
  (serve input emit receive (make-raising-highlight)))

(jobs:define-worker (%ranged input emit receive)
  (import (syntax-highlighting job) (syntax-highlighting-test highlight))
  (serve input emit receive (make-ranged-highlight)))

(jobs:define-worker (%pieces input emit receive)
  (import (syntax-highlighting job) (syntax-highlighting-test highlight))
  (serve input emit receive (make-pieces-highlight)))

(jobs:define-worker (%misshapen input emit receive)
  (import (syntax-highlighting job) (syntax-highlighting-test highlight))
  (serve input emit receive (make-misshapen-highlight)))

(define %inputs '())

(define (inputs-count) (length %inputs))

(define (inputs)
  (let ([found (reverse %inputs)])
    (set! %inputs '())
    found))

(define (inputs-become expected) (test-runner:wait-until (lambda () (equal? expected (reverse %inputs)))))

(define (%input buffer data)
  (set! %inputs (cons (list (buffers:name buffer) data (length (views:showing buffer))) %inputs))
  (when (input-raises?)
    (error 'marks:input "the input raised"))
  (list (mark)))

(define %counted '())

(define (counted)
  (let ([found (reverse %counted)])
    (set! %counted '())
    found))

(define (%counting-input buffer data)
  (set! %counted (cons (list data (syntax-highlighting:data-version buffer)) %counted))
  #f)

(define (%own-input buffer data)
  (set! %inputs (cons (list (buffers:name buffer) data (length (views:showing buffer))) %inputs))
  (list "!"))

(define (%pieces-input buffer data)
  (set! %inputs (cons (list (buffers:name buffer) data) %inputs))
  (list (string-append (getenv "HOME") "/gates/" (buffers:name buffer))))

(define (%texts b type)
  (buffers:spans (buffers:layer b type) 0 (document:length (buffers:document b))))

(define (faces b)
  (map (lambda (s) (list (document:text (buffers:document b) (car s) (cadr s)) (cdr (assq 'face (caddr s)))))
       (%texts b syntax-highlighting:faces)))

(define (paren-texts b)
  (map (lambda (s) (document:text (buffers:document b) (car s) (cadr s))) (%texts b parens)))

;; Highlighting runs in a job, so a check waits until the spans are the
;; ones it expects.
(define (faces-become b expected) (test-runner:wait-until (lambda () (equal? expected (faces b)))))

(define (parens-become b expected) (test-runner:wait-until (lambda () (equal? expected (paren-texts b)))))

(tables:set! syntax-highlighting:highlighters "marks"
  (syntax-highlighting:make-highlighter %marks (list syntax-highlighting:faces parens) %input))
(tables:set! syntax-highlighting:highlighters own
  (syntax-highlighting:make-highlighter %marks (list syntax-highlighting:faces parens) %own-input))
(tables:set! syntax-highlighting:highlighters counting
  (syntax-highlighting:make-highlighter %counting (list syntax-highlighting:faces) %counting-input))
(tables:set! syntax-highlighting:highlighters raising
  (syntax-highlighting:make-highlighter %raising (list syntax-highlighting:faces) %input))
(tables:set! syntax-highlighting:highlighters ranged
  (syntax-highlighting:make-highlighter %ranged (list syntax-highlighting:faces) (lambda (buffer data) (range))))
(tables:set! syntax-highlighting:highlighters pieces
  (syntax-highlighting:make-highlighter %pieces (list syntax-highlighting:faces) %pieces-input))
(tables:set! syntax-highlighting:highlighters misshapen
  (syntax-highlighting:make-highlighter %misshapen (list syntax-highlighting:faces) (lambda (buffer data) (shape))))
(tables:set! auto-mode:file-names "mk" mode)


#!tuna
(import (modes) (auto-mode) (buffers) (views) (jobs) (syntax-highlighting) (marks highlight))

(define-option mark "#" string? "The character that starts a marked word.")
(define-option input-raises? #f boolean? "Whether the input procedure raises.")

(define-table keymap "Keys.")
(define-hook mode-hook "Setup.")
(modes:define-major-mode mode (keymap keymap) (hook mode-hook) (language "marks"))

(define-table derived-keymap "Keys.")
(define-hook derived-hook "Setup.")
(modes:define-major-mode derived (parent mode) (keymap derived-keymap) (hook derived-hook))

(define-table own-keymap "Keys.")
(define-hook own-hook "Setup.")
(modes:define-major-mode own (keymap own-keymap) (hook own-hook) (language "marks"))

(define-table raising-keymap "Keys.")
(define-hook raising-hook "Setup.")
(modes:define-major-mode raising (keymap raising-keymap) (hook raising-hook))

(define-table ranged-keymap "Keys.")
(define-hook ranged-hook "Setup.")
(modes:define-major-mode ranged (keymap ranged-keymap) (hook ranged-hook))

(define-option range '(0 0) list? "The range the ranged highlighter answers for.")

(define-table pieces-keymap "Keys.")
(define-hook pieces-hook "Setup.")
(modes:define-major-mode pieces (keymap pieces-keymap) (hook pieces-hook))

(define-table unnamed-keymap "Keys.")
(define-hook unnamed-hook "Setup.")
(modes:define-major-mode unnamed (keymap unnamed-keymap) (hook unnamed-hook))

(define-table unknown-keymap "Keys.")
(define-hook unknown-hook "Setup.")
(modes:define-major-mode unknown (keymap unknown-keymap) (hook unknown-hook) (language "nothing"))

(buffers:define-layer parens (priority -5) (evaporate))

(jobs:define-worker (%marks input emit receive)
  (import (syntax-highlighting job) (marks highlight))
  (serve input emit receive (make-marks-highlight)))

(jobs:define-worker (%raising input emit receive)
  (import (syntax-highlighting job) (marks highlight))
  (serve input emit receive (make-raising-highlight)))

(jobs:define-worker (%ranged input emit receive)
  (import (syntax-highlighting job) (marks highlight))
  (serve input emit receive (make-ranged-highlight)))

(jobs:define-worker (%pieces input emit receive)
  (import (syntax-highlighting job) (marks highlight))
  (serve input emit receive (make-pieces-highlight)))

(define %inputs '())

(define (inputs)
  (let ([found (reverse %inputs)])
    (set! %inputs '())
    found))

(define (%input buffer data)
  (set! %inputs (cons (list (buffers:name buffer) data (length (views:showing buffer))) %inputs))
  (when (input-raises?)
    (error 'marks:input "the input raised"))
  (list (mark)))

(define (%own-input buffer data)
  (set! %inputs (cons (list (buffers:name buffer) data (length (views:showing buffer))) %inputs))
  (list "!"))

(define (%pieces-input buffer data)
  (set! %inputs (cons (list (buffers:name buffer) data) %inputs))
  (list (string-append (getenv "HOME") "/gates/" (buffers:name buffer))))

(table-set! syntax-highlighting:highlighters "marks"
  (syntax-highlighting:make-highlighter %marks (list syntax-highlighting:faces parens) %input))
(table-set! syntax-highlighting:highlighters own
  (syntax-highlighting:make-highlighter %marks (list syntax-highlighting:faces parens) %own-input))
(table-set! syntax-highlighting:highlighters raising
  (syntax-highlighting:make-highlighter %raising (list syntax-highlighting:faces) %input))
(table-set! syntax-highlighting:highlighters ranged
  (syntax-highlighting:make-highlighter %ranged (list syntax-highlighting:faces) (lambda (buffer data) (range))))
(table-set! syntax-highlighting:highlighters pieces
  (syntax-highlighting:make-highlighter %pieces (list syntax-highlighting:faces) %pieces-input))
(table-set! auto-mode:file-names "mk" mode)

;;; Plain data: the values that may cross from one thread to another, and
;;; that memo compares by value (ADR 3, ADR 17). A library (ADR 12).
;;;
;;; Test mode (`set-plain-data-checking!`, turned on by the test kernel)
;;; makes `check-plain-data!` fail on anything else, where code hands a
;;; value to another thread.
prelude: :gerbil/core

(export plain-value? plain-equal?
        set-plain-data-checking! plain-data-checking? check-plain-data!)

;; Whether X is plain data: a number, character, string, symbol, keyword,
;; boolean, (), or a pair or vector of plain data. Objects are not: `equal?`
;; walks their fields, all the way through what they refer to.
(def (plain-value? (x : :t)) => :boolean
  (cond
   ((pair? x) (and (plain-value? (car x)) (plain-value? (cdr x))))
   ((vector? x)
    (let lp ((i 0))
      (or (fx= i (vector-length x))
          (and (plain-value? (vector-ref x i)) (lp (fx1+ i))))))
   (else (or (number? x) (string? x) (symbol? x) (keyword? x) (char? x) (boolean? x) (null? x)))))

;; A and B are the same value: `equal?` when both are plain data,
;; otherwise the same object.
(def (plain-equal? (a : :t) (b : :t)) => :boolean
  (or (eq? a b)
      (and (plain-value? a) (plain-value? b) (equal? a b))))

;;; Test mode

;; A module flag, not a parameter, so threads that inherit no parameters
;; see it too.
(def checking? #f)

(def (set-plain-data-checking! (on? : :boolean)) => :void
  (set! checking? on?))

(def (plain-data-checking?) => :boolean
  checking?)

;; In test mode, raise an error saying WHAT must be plain data unless X
;; is.
(def (check-plain-data! (what : :string) (x : :t)) => :void
  (when (and checking? (not (plain-value? x)))
    (error (string-append what " must be plain data"))))

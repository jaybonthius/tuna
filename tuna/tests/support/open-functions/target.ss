prelude: :tuna/prelude
package: tuna/tests/support/open-functions
(import "foreign-macro")
(export typed inside optional keyword rest curried local closed
        literal-procedure case-procedure clauses defaulted default-count
        multiple-values nullable self-loop mutual-a mutual-b tail-trace
        public-call token foreign-made macro-made (struct-out sample))

(def (typed (n : :fixnum)) => :fixnum (fx+ n 1))
(def (inside (n : :fixnum)) => :fixnum (typed n))
(def (optional (n : :fixnum) (add : :fixnum := 2)) => :fixnum (fx+ n add))
(def (keyword (n : :fixnum) add: (add : :fixnum := 3)) => :fixnum (fx+ n add))
(def (rest (n : :fixnum) . ns) => :pair (cons n ns))
(def ((curried (n : :fixnum)) (add : :fixnum)) => :fixnum (fx+ n add))
(def (local (n : :fixnum)) => :fixnum
  (def (inner (x : :fixnum)) => :fixnum (fx1+ x))
  (inner n))
(def/closed (closed (n : :fixnum)) => :fixnum (fx1+ n))
(def literal-procedure (lambda ((n : :fixnum)) => :fixnum (fx1+ n)))
(def case-procedure (case-lambda (() => :fixnum 0) (((n : :fixnum)) => :fixnum n)))
(def* clauses (() => :fixnum 0) (((n : :fixnum)) => :fixnum n)
  (((n : :fixnum) . ns) => :pair (cons n ns)))
(def default-count 0)
(def (defaulted (n : :fixnum := (begin (set! default-count (fx1+ default-count)) 3))) => :fixnum n)
(def (multiple-values) => :values (values 1 2))
(def (nullable (n : :fixnum)) => (Maybe :fixnum) (and (not (fxzero? n)) n))
(def (self-loop (n : :fixnum)) => :fixnum
  (if (fxzero? n) 0 (self-loop (fx1- n))))
(def (mutual-a (n : :fixnum)) => :boolean
  (if (fxzero? n) #t (mutual-b (fx1- n))))
(def (mutual-b (n : :fixnum)) => :boolean
  (if (fxzero? n) #f (mutual-a (fx1- n))))
(def (tail-trace (n : :fixnum)) => :string
  (if (fxzero? n)
    (:- (continuation-capture
          (lambda (k)
            (let (port (open-output-string))
              (display-continuation-backtrace k port 0 0 0 1000000 0)
              (get-output-string port)))) :string)
    (tail-trace (fx1- n))))

(def token (vector 'single-instance))
(def (helper (n : :fixnum)) => :fixnum (fx+ n 3))
(def (secret (n : :fixnum)) => :fixnum (helper n))
(def (public-call (n : :fixnum)) => :fixnum (secret n))
(defrule (make-definition name)
  (def (name (n : :fixnum)) => :fixnum (fx+ n 5)))
(make-definition macro-made)
(foreign-definition foreign-made)
(defstruct sample ((value : :fixnum)) final: #t)
(defmethod {value sample}
  (lambda ((self : sample)) => :fixnum self.value))

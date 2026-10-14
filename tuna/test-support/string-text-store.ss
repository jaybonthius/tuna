;;; The toy text store: each version is one immutable string, and every
;;; edit copies it. It proves the text store can be swapped, and it is the
;;; oracle for the rope's tests.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel
        :tuna/services/text-store)
(export string-text-store-plugin
        string-text-store)

(def (count-newlines (text : :string) (end : :fixnum)) => :fixnum
  (let lp ((i 0) (count 0))
    (if (fx< i end)
      (lp (fx1+ i) (if (char=? (string-ref text i) #\newline) (fx1+ count) count))
      count)))

;; The position just after the Nth newline of TEXT.
(def (position-after-newline (text : :string) (n : :fixnum)) => :fixnum
  (let lp ((i 0) (n n))
    (cond
     ((not (char=? (string-ref text i) #\newline)) (lp (fx1+ i) n))
     ((fx= n 1) (fx+ i 2))
     (else (lp (fx1+ i) (fx1- n))))))

(def (string-size (text : :string)) => :fixnum
  (string-length text))

(def (string-line-count (text : :string)) => :fixnum
  (fx1+ (count-newlines text (string-length text))))

(def (string-slice (text : :string) (start : :fixnum) (end : :fixnum)) => :string
  (substring text (fx1- start) (fx1- end)))

(def (string-line-at (text : :string) (position : :fixnum)) => :fixnum
  (fx1+ (count-newlines text (fx1- position))))

(def (string-line-start (text : :string) (line : :fixnum)) => :fixnum
  (if (fx= line 1) 1 (position-after-newline text (fx1- line))))

(def (string-replace (text : :string) (start : :fixnum) (end : :fixnum) (new : :string)) => :string
  (string-append (substring text 0 (fx1- start)) new (substring text (fx1- end) (string-length text))))

(defstruct string-store ()
  final: #t)

(implement TextStore string-store
  (from-string (lambda (self text) (string-copy text)))
  (size (lambda (self version) (string-size version)))
  (line-count (lambda (self version) (string-line-count version)))
  (slice (lambda (self version start end) (string-slice version start end)))
  (line-at (lambda (self version position) (string-line-at version position)))
  (line-start (lambda (self version line) (string-line-start version line)))
  (for-each-chunk (lambda (self version start end proc)
                    (when (fx< start end) (proc (string-slice version start end)))))
  (replace (lambda (self version start end text) (string-replace version start end text))))

(def string-text-store (TextStore (make-string-store)))

(defplugin (string-text-store-plugin ctx)
  "Stores text as plain strings (a toy text store). Outranks the rope while active."
  provides: [text-store-service]
  (context-provide! ctx text-store-service string-text-store))

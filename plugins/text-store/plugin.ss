#lang :tuna/prelude
;;; The default text store: a persistent rope (ADR 6).
;;;
;;; A rope is a height-balanced (AVL) binary tree whose leaves hold short
;;; strings. Every subtree caches its character and newline counts, so
;;; lookups by position or line take O(log n) steps, and an edit returns a
;;; new rope sharing every untouched subtree with the old one. Leaf strings
;;; are never mutated. Internally positions are 0-based offsets; the
;;; TextStore methods convert from 1-based positions at the boundary.

(import :std/interface
        :tuna/kernel
        :tuna/plugins/text-store/contract)
(export rope-text-store
        rope-store-instance
        rope-balanced?)

;; Edits within one leaf copy at most this many characters.
(def max-leaf 1024)

(defstruct rope ((chars    : :fixnum)
                 (newlines : :fixnum)))

(defstruct (rope-leaf rope) ((text : :string))
  final: #t)

(defstruct (rope-node rope) ((left   : rope)
                             (right  : rope)
                             (height : :fixnum))
  final: #t)

(def (count-newlines (text : :string) (start : :fixnum) (end : :fixnum)) => :fixnum
  (let lp ((i start) (count 0))
    (if (fx< i end)
      (lp (fx1+ i) (if (char=? (string-ref text i) #\newline) (fx1+ count) count))
      count)))

(def (leaf (text : :string)) => rope
  (make-rope-leaf (string-length text) (count-newlines text 0 (string-length text)) text))

(def empty-rope (leaf ""))

(def (rope-height (r : rope)) => :fixnum
  (if (rope-node? r) (rope-node-height r) 0))

(def (node (left : rope) (right : rope)) => rope
  (make-rope-node (fx+ (rope-chars left) (rope-chars right))
                  (fx+ (rope-newlines left) (rope-newlines right))
                  left right
                  (fx1+ (fxmax (rope-height left) (rope-height right)))))

;; A node of A and B, whose heights differ by at most two, rotated back into
;; balance.
(def (balanced (a : rope) (b : rope)) => rope
  (let ((ha (rope-height a))
        (hb (rope-height b)))
    (cond
     ((fx> ha (fx1+ hb))
      (let ((al (rope-node-left a))
            (ar (rope-node-right a)))
        (if (fx>= (rope-height al) (rope-height ar))
          (node al (node ar b))
          (node (node al (rope-node-left ar)) (node (rope-node-right ar) b)))))
     ((fx> hb (fx1+ ha))
      (let ((bl (rope-node-left b))
            (br (rope-node-right b)))
        (if (fx>= (rope-height br) (rope-height bl))
          (node (node a bl) br)
          (node (node a (rope-node-left bl)) (node (rope-node-right bl) br)))))
     (else (node a b)))))

;; A followed by B, in O(log n). Adjacent small leaves merge.
(def (concat (a : rope) (b : rope)) => rope
  (cond
   ((fxzero? (rope-chars a)) b)
   ((fxzero? (rope-chars b)) a)
   (else
    (let ((ha (rope-height a))
          (hb (rope-height b)))
      (cond
       ((fx> ha (fx1+ hb))
        (balanced (rope-node-left a) (concat (rope-node-right a) b)))
       ((fx> hb (fx1+ ha))
        (balanced (concat a (rope-node-left b)) (rope-node-right b)))
       ((and (rope-leaf? a) (rope-leaf? b)
             (fx<= (fx+ (rope-chars a) (rope-chars b)) max-leaf))
        (leaf (string-append (rope-leaf-text a) (rope-leaf-text b))))
       (else (node a b)))))))

;; Two values: the first OFFSET characters of R, and the rest. (Return
;; types cannot describe multiple values.)
(def (split (r : rope) (offset : :fixnum))
  (cond
   ((fxzero? offset) (values empty-rope r))
   ((fx= offset (rope-chars r)) (values r empty-rope))
   ((rope-leaf? r)
    (let (text (rope-leaf-text r))
      (values (leaf (substring text 0 offset))
              (leaf (substring text offset (string-length text))))))
   (else
    (let* ((left (rope-node-left r))
           (right (rope-node-right r))
           (left-chars (rope-chars left)))
      (if (fx<= offset left-chars)
        (let-values (((a b) (split left offset)))
          (values a (concat b right)))
        (let-values (((a b) (split right (fx- offset left-chars))))
          (values (concat left a) b)))))))

(def (string->rope (text : :string)) => rope
  (let build ((start 0) (end (string-length text)))
    (if (fx<= (fx- end start) max-leaf)
      (leaf (substring text start end))
      (let (middle (fx+ start (fxquotient (fx- end start) 2)))
        (node (build start middle) (build middle end))))))

;; R with START..END replaced by TEXT, when the range lies within one leaf
;; that stays at most max-leaf long; otherwise #f. Heights do not change.
(def (replace-within-leaf (r : rope) (start : :fixnum) (end : :fixnum) (text : :string))
  => (Maybe rope)
  (if (rope-leaf? r)
    (let* ((old (rope-leaf-text r))
           (old-length (string-length old)))
      (and (fx<= (fx+ (fx- old-length (fx- end start)) (string-length text)) max-leaf)
           (leaf (string-append (substring old 0 start) text (substring old end old-length)))))
    (let* ((left (rope-node-left r))
           (right (rope-node-right r))
           (left-chars (rope-chars left)))
      (cond
       ((fx<= end left-chars)
        (let (new (replace-within-leaf left start end text))
          (and new (node new right))))
       ((fx>= start left-chars)
        (let (new (replace-within-leaf right (fx- start left-chars) (fx- end left-chars) text))
          (and new (node left new))))
       (else #f)))))

(def (rope-replace (r : rope) (start : :fixnum) (end : :fixnum) (text : :string)) => rope
  (or (replace-within-leaf r start end text)
      (let*-values (((before rest) (split r start))
                    ((_ after) (split rest (fx- end start))))
        (concat (concat before (string->rope text)) after))))

(def/closed (rope-for-each-chunk (r : rope) (start : :fixnum) (end : :fixnum) (proc : :procedure)) => :void
  (when (fx< start end)
    (if (rope-leaf? r)
      (let (text (rope-leaf-text r))
        (proc (if (and (fxzero? start) (fx= end (string-length text)))
                text
                (substring text start end))))
      (let* ((left (rope-node-left r))
             (left-chars (rope-chars left)))
        (when (fx< start left-chars)
          (rope-for-each-chunk left start (fxmin end left-chars) proc))
        (when (fx> end left-chars)
          (rope-for-each-chunk (rope-node-right r) (fxmax 0 (fx- start left-chars))
                               (fx- end left-chars) proc))))))

(def (rope-slice (r : rope) (start : :fixnum) (end : :fixnum)) => :string
  (call-with-output-string ""
    (lambda (port)
      (rope-for-each-chunk r start end (lambda (chunk) (write-string chunk port))))))

;; Newlines among the first OFFSET characters of R.
(def (newlines-before (r : rope) (offset : :fixnum)) => :fixnum
  (let lp ((r r) (offset offset) (count 0))
    (if (rope-leaf? r)
      (fx+ count (count-newlines (rope-leaf-text r) 0 offset))
      (let* ((left (rope-node-left r))
             (left-chars (rope-chars left)))
        (if (fx<= offset left-chars)
          (lp left offset count)
          (lp (rope-node-right r) (fx- offset left-chars) (fx+ count (rope-newlines left))))))))

;; The offset just after the Nth newline of R, counting from 1.
(def (offset-after-newline (r : rope) (n : :fixnum)) => :fixnum
  (let lp ((r r) (n n) (base 0))
    (if (rope-leaf? r)
      (let (text (rope-leaf-text r))
        (let scan ((i 0) (n n))
          (cond
           ((not (char=? (string-ref text i) #\newline)) (scan (fx1+ i) n))
           ((fx= n 1) (fx+ base i 1))
           (else (scan (fx1+ i) (fx1- n))))))
      (let* ((left (rope-node-left r))
             (left-newlines (rope-newlines left)))
        (if (fx<= n left-newlines)
          (lp left n base)
          (lp (rope-node-right r) (fx- n left-newlines) (fx+ base (rope-chars left))))))))

;; Whether every node of R is height-balanced and its cached counts are
;; right. For tests.
(def (rope-balanced? (r : rope)) => :boolean
  (if (rope-leaf? r)
    (fx= (rope-newlines r) (count-newlines (rope-leaf-text r) 0 (rope-chars r)))
    (let ((left (rope-node-left r))
          (right (rope-node-right r)))
      (and (fx<= (fxabs (fx- (rope-height left) (rope-height right))) 1)
           (fx= (rope-node-height r) (fx1+ (fxmax (rope-height left) (rope-height right))))
           (fx= (rope-chars r) (fx+ (rope-chars left) (rope-chars right)))
           (fx= (rope-newlines r) (fx+ (rope-newlines left) (rope-newlines right)))
           (rope-balanced? left)
           (rope-balanced? right)))))

;;; The TextStore implementation

(def (rope-size (r : rope)) => :fixnum
  (rope-chars r))

(def/closed (rope-line-count (r : rope)) => :fixnum
  (fx1+ (rope-newlines r)))

(defstruct rope-store ()
  final: #t)

(implement TextStore rope-store
  (from-string (lambda (self text) (string->rope text)))
  (size (lambda (self version) (rope-size version)))
  (line-count (lambda (self version) (rope-line-count version)))
  (slice (lambda (self version start end)
           (rope-slice version (fx1- start) (fx1- end))))
  (line-at (lambda (self version position)
             (fx1+ (newlines-before version (fx1- position)))))
  (line-start (lambda (self version line)
                (if (fx= line 1)
                  1
                  (fx1+ (offset-after-newline version (fx1- line))))))
  (for-each-chunk (lambda (self version start end proc)
                    (rope-for-each-chunk version (fx1- start) (fx1- end) proc)))
  (replace (lambda (self version start end text)
             (rope-replace version (fx1- start) (fx1- end) text))))

;; The store is stateless, so one instance serves every activation.
(def rope-store-instance (TextStore (make-rope-store)))

(defplugin (rope-text-store ctx)
  "Stores text in a persistent rope (the default text store)."
  provides: [text-store-service]
  (context-provide! ctx text-store-service rope-store-instance))

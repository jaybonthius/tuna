;;; The long-buffer demo plugin, for development only (`tuna --config
;;; demo/init.ss`): C-c g shows *long*, 50,000 generated lines of
;;; different lengths, some long enough to wrap, for trying scrolling
;;; and measuring what a key costs in a large buffer.
prelude: :gerbil/core

(import :tuna/kernel
        :tuna/plugins/commands/contract
        :tuna/plugins/keys/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/layout/contract)
(export long-buffer-demo)

(def long-buffer-name "*long*")
(def long-buffer-line-count 50000)

(def words
  (list->vector
   (string-split "tuna buffer node view layout scroll anchor height estimate measure browser server morph frame window emacs redisplay point mark region column tree text proportional monospace wrapped paragraph" #\space)))

;; The same lines every time: line N starts with N, then 2 to 17 words,
;; or 30 to 89 on every ninth line, picked by a fixed linear congruential
;; sequence.
(def (long-buffer-text) => :string
  (call-with-output-string ""
    (lambda (port)
      (let lp ((line 1) (seed 7))
        (when (fx<= line long-buffer-line-count)
          (let* ((next (lambda ((s : :fixnum)) (modulo (+ (* s 1103515245) 12345) 2147483648)))
                 (s1 (next seed))
                 (count (if (zero? (modulo line 9)) (+ 30 (modulo s1 60)) (+ 2 (modulo s1 16)))))
            (display line port)
            (let words-loop ((i 0) (s s1))
              (if (fx< i count)
                (begin
                  (write-char #\space port)
                  (display (vector-ref words (modulo (quotient s 65536) (vector-length words))) port)
                  (words-loop (fx1+ i) (next s)))
                (begin
                  (when (fx< line long-buffer-line-count) (newline port))
                  (lp (fx1+ line) s))))))))))

(defplugin (long-buffer-demo ctx)
  "C-c g: *long*, a buffer of 50,000 generated lines, for trying scrolling."
  requires: [commands-service input-service buffers-service layout-service]
  (define-command ctx (long-buffer) "Show *long*, 50,000 generated lines, making it the first time."
    (let (b (or (get-buffer long-buffer-name)
                (let (b (new-buffer long-buffer-name (new-text-node (new-text (long-buffer-text)))))
                  (context-add-buffer! ctx b)
                  b)))
      (set-view-buffer (selected-view) b)))
  (keymap-set ctx "C-c g" 'long-buffer))

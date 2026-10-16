;;; The text store service (ADR 6): persistent versions of text.
;;; Positions are 1-based character (code point) positions: position 1 is
;;; before the first character and SIZE + 1 after the last. Lines count from
;;; 1; only #\newline ends a line. Callers pass valid positions and lines;
;;; each implementation indexes internally however it likes.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel)
(export (service-interface-out TextStore)
        text-store-service
        current-text-store)

(service-interface TextStore
  ;; A version holding TEXT.
  (from-string (text : :string)) => :t
  ;; The number of characters in VERSION.
  (size (version : :t)) => :fixnum
  ;; The number of lines in VERSION: its newlines plus one.
  (line-count (version : :t)) => :fixnum
  ;; The characters from START up to END.
  (slice (version : :t) (start : :fixnum) (end : :fixnum)) => :string
  ;; The line containing POSITION.
  (line-at (version : :t) (position : :fixnum)) => :fixnum
  ;; The position where LINE starts.
  (line-start (version : :t) (line : :fixnum)) => :fixnum
  ;; Call PROC with each chunk of the characters from START up to END, in
  ;; order. Chunks may be shared with VERSION; PROC must not mutate them.
  (for-each-chunk (version : :t) (start : :fixnum) (end : :fixnum) (proc : :procedure)) => :void
  ;; A new version with START up to END replaced by TEXT. VERSION and
  ;; every earlier version stay valid.
  (replace (version : :t) (start : :fixnum) (end : :fixnum) (text : :string)) => :t)

(def text-store-service
  (new-service 'text-store is-TextStore? tier: 'live
               doc: "Stores persistent versions of text."))

;; The current text store.
(def (current-text-store) => TextStore
  (let (store (service-provider text-store-service))
    (unless store
      (error "No plugin provides the text store"))
    (TextStore store)))

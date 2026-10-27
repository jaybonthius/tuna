;;; The sampler (the plan's stage 3), copied from Gerbil's gxprof
;;; (src/tools/gxprof.ss): it takes over Gambit's heartbeat interrupt
;;; (vector 2), and on each beat captures the running thread's
;;; continuation, notes the procedure that created each of its frames, and
;;; then runs the scheduler's own heartbeat (##thread-heartbeat!), which
;;; preempts threads. Stopping gives the interrupt and the interval back.
;;; Each sample also notes a label, the input item being worked on, and the
;;; running thread's name, so samples and span trees line up.
;;;
;;; These are Gambit internals (`##`); sampler-test.ss fails loudly when
;;; they change.
prelude: :gerbil/core

(import (only-in :gerbil/runtime/hash HashTable))
(export sampler-start!
        sampler-stop!
        sampler-running?
        folded-lines)

;; Samples, newest first: each [label thread frames], FRAMES the creators of
;; the captured continuation's frames, innermost first. Only the heartbeat
;; handler adds to it, and only while running.
(def samples [])
(def running? #f)
(def label-procedure (lambda () #f))
(def previous-interval .01)

(def (sampler-running?) => :boolean
  running?)

;; Start sampling every INTERVAL seconds; (LABEL) names the input item
;; being worked on, or #f. Raises if already running.
(def (sampler-start! (interval : :real) (label : :procedure)) => :void
  (when running?
    (error "The sampler is already running"))
  (let (v (make-f64vector 1 .01))
    (##get-heartbeat-interval! v 0)
    (set! previous-interval (f64vector-ref v 0)))
  (set! samples [])
  (set! label-procedure label)
  (set! running? #t)
  (##set-heartbeat-interval! (exact->inexact interval))
  (##interrupt-vector-set! 2 sample-heartbeat!))

;; Stop sampling and return the samples taken, oldest first, each [label
;; thread frames] with FRAMES the creators of the sample's frames,
;; innermost first; folded-lines names them. Quick, so it may run on the
;; editor thread.
(def (sampler-stop!) => :list
  (if running?
    (begin
      (##set-heartbeat-interval! previous-interval)
      (##interrupt-vector-set! 2 ##thread-heartbeat!)
      (set! running? #f)
      (let (taken samples)
        (set! samples [])
        (reverse taken)))
    []))

;; The heartbeat handler: take a sample, then preempt as usual.
(def (sample-heartbeat!)
  (##continuation-capture
   (lambda (cont)
     (set! samples (cons [(with-catch (lambda (e) #f) label-procedure)
                          (thread-name (current-thread))
                          (continuation-frames cont)]
                         samples))
     (##thread-heartbeat!))))

;; The creators of CONT's frames, innermost first, from the frame below
;; the handler's own.
(def (continuation-frames cont) => :list
  (:- (let lp ((cont (##continuation-next-frame cont #t)) (frames []))
        (if cont
          (lp (##continuation-next-frame cont #t) (cons (##continuation-creator cont) frames))
          (reverse frames)))
      :list))

(def (frame-name (creator : :t)) => :string
  (let (name (and (procedure? creator) (##procedure-name creator)))
    (cond
     ((symbol? name) (symbol->string name))
     ((string? name) name)
     (else "?"))))

;; One frame of a folded line: no ; and no spaces, which separate frames
;; and the count.
(def (folded-frame (text : :string)) => :string
  (list->string (map (lambda ((c : :char)) (if (or (char=? c #\;) (char-whitespace? c)) #\_ c))
                     (string->list text))))

;; SAMPLES, as sampler-stop! returns them, as folded stacks: one line per
;; distinct stack, "label;thread;outermost;...;innermost count", the most
;; frequent first. ##procedure-name searches for a procedure's name, so
;; each creator is named once, as gxprof does. It takes a while for a long
;; run, so the profiler calls it off the editor thread.
(def (folded-lines (samples : :list)) => :list
  (let ((counts (make-hash-table))
        (names (make-hash-table-eq)))
    (def (name (creator : :t)) => :string
      (or (hash-get names creator)
          (let (text (frame-name creator))
            (hash-put! names creator text)
            text)))
    (for-each (lambda ((sample : :list))
                (let (stack (string-join
                             (map folded-frame
                                  (cons* (or (car sample) "no-input-item")
                                         (let (thread (cadr sample))
                                           (cond ((symbol? thread) (symbol->string thread))
                                                 ((string? thread) thread)
                                                 (else "thread")))
                                         (reverse (map name (caddr sample)))))
                             ";"))
                  (hash-update! counts stack (lambda (n) (fx1+ n)) 0)))
              samples)
    (map (lambda ((pair : :pair)) (string-append (car pair) " " (number->string (cdr pair))))
         (list-sort (lambda ((a : :pair) (b : :pair)) (fx> (cdr a) (cdr b)))
                    (hash->list counts)))))

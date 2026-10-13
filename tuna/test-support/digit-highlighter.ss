;;; A deliberately slow highlighter that colors digits from a job after
;;; each change, for tests of jobs, rebased results, and cancellation
;;; through a running editor. The minibuffer's answers are left alone.
prelude: :gerbil/core

(import :tuna/kernel
        :tuna/lib/jobs
        :tuna/services/buffers
        :tuna/services/settings)
(export digit-highlighter-plugin
        digit-spans
        digit-highlight-delay)

(defsetting digit-highlight-delay 0.3
  "Seconds the slow digit highlighter takes to color digits.")

;; Spans of S's digit runs, with the face `digit`. A job runs this off the
;; baton: it reads only the snapshot.
(def (digit-spans (s : snapshot)) => :list
  (let ((spans [])
        (position 1)
        (run-start #f))
    (snapshot-for-each-chunk
     s (lambda ((chunk : :string))
         (string-for-each
          (lambda (c)
            (cond
             ((char-numeric? c)
              (unless run-start (set! run-start position)))
             (run-start
              (set! spans (cons (make-span run-start position 'digit) spans))
              (set! run-start #f)))
            (set! position (fx1+ position)))
          chunk)))
    (reverse (if run-start (cons (make-span run-start position 'digit) spans) spans))))

;; Whether T belongs to an internal buffer, such as a prompt's.
(def (internal-text? (t : text)) => :boolean
  (let (b (find (lambda ((b : buffer)) (memq t (buffer-texts b))) (buffer-list)))
    (and b (internal-buffer? b))))

;; Sleep for DELAY seconds in short slices, stopping early once CANCELLED?
;; returns true. Returns whether the full delay passed.
(def (sleep-unless-cancelled (delay : :real) (cancelled? : :procedure)) => :boolean
  (let lp ((left delay))
    (cond
     ((cancelled?) #f)
     ((<= left 0) #t)
     (else
      (thread-sleep! (min left 0.02))
      (lp (- left 0.02))))))

;; After each change, recolor the text's digits from a job. Typing goes on
;; meanwhile; the rebase policy moves the colors past what was typed.
(def (highlight-digits-later! (jobs : job-group) (t : text)) => :void
  (when (and (editor-loop-running?) (not (internal-text? t)))
    (job-group-start! jobs ['highlight-digits (text-id t)]
                      input: [(text-snapshot t) (setting-value digit-highlight-delay)]
                      run: (lambda (input cancelled?)
                             (match input
                               ([snapshot delay]
                                (and (sleep-unless-cancelled delay cancelled?)
                                     (digit-spans snapshot)))))
                      apply: (lambda (spans) (set-highlights! t 'digits spans))
                      target: t
                      validity: 'rebase)
    (void)))

(defplugin (digit-highlighter-plugin ctx)
  "Colors digits from a slow job after each change."
  requires: [buffers-service]
  (let (jobs (new-job-group ctx))
    (context-add-hook! ctx after-change-hook 'slow-digit-highlighter
                       (lambda (t c) (highlight-digits-later! jobs t)))))

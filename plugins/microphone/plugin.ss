#lang :tuna/prelude
;;; The microphone plugin: its page script (frontend/microphone.ts, built
;;; into web/) captures a tab's microphone when this plugin sends that tab
;;; the one-time instruction microphoneStart, and stops at
;;; microphoneStop. The page asks the browser for the microphone (mono,
;;; echo cancellation and noise suppression), runs an AudioContext at
;;; 16 kHz where the browser allows it and resamples otherwise, collects
;;; samples in an AudioWorklet (web/microphone-worklet.js), and posts
;;; chunks of about 100 ms, one post at a time, to this plugin's page
;;; address `chunk`. What keeps it from capturing (no secure context, no
;;; API, permission refused, no microphone) it posts to `problem`.

(import (only-in :gerbil/runtime/hash HashTable)
        (only-in :std/encoding/json string->json current-json-read-options JSONReadOptions)
        :std/interface
        :tuna/kernel
        :tuna/plugins/clients/contract
        :tuna/plugins/web/contract
        :tuna/plugins/microphone/contract)
(export microphone)

;; A capture in progress: its callbacks, and the poster that runs a
;; failure on the editor loop.
(defclass capture ((on-chunk   : :procedure)
                   (on-failure : :procedure)
                   (post       : :procedure))
  final: #t)

(defclass microphone-state ((mutex    : :mutex)
                            (captures : HashTable)) ; client -> capture
  final: #t)

;; How long a chunk is, in samples.
(def chunk-samples (quotient microphone-sample-rate 10))

(def (start-capture! (self : microphone-state) (c : client) (on-chunk : :procedure) (on-failure : :procedure))
  => :void
  (do-with-lock self.mutex
    (hash-put! self.captures c (capture on-chunk: on-chunk on-failure: on-failure post: (result-poster))))
  (page-instruct! c "microphoneStart"
                  (hash ("rate" microphone-sample-rate) ("chunk" chunk-samples))))

;; The capture of C, now removed, or #f.
(def (take-capture! (self : microphone-state) (c : client)) => (Maybe capture)
  (do-with-lock self.mutex
    (let (found (hash-get self.captures c))
      (hash-remove! self.captures c)
      found)))

(def (stop-capture! (self : microphone-state) (c : client)) => :void
  (take-capture! self c)
  (page-instruct! c "microphoneStop" #t))

;; On a request thread: a chunk from C's page.
(def (accept-chunk (self : microphone-state) (c : client) (bytes : :u8vector)) => :void
  (let (found (do-with-lock self.mutex (hash-get self.captures c)))
    (when found
      ((capture-on-chunk found) bytes))))

;; What the page's problem report PROBLEM, with the error NAME, means.
(def (problem-sentence (problem : :t) (name : :t)) => :string
  (cond
   ((equal? problem "insecure")
    "The browser gives the microphone only to HTTPS and localhost pages")
   ((equal? problem "unavailable")
    "This browser cannot capture audio here (no getUserMedia or AudioWorklet)")
   ((equal? problem "denied")
    "The browser was not allowed to use the microphone")
   ((equal? problem "no-microphone")
    "No microphone was found")
   ((and (string? name) (fx<= 1 (string-length name) 64)
         (andmap char-alphabetic? (string->list name)))
    (string-append "The microphone failed (" name ")"))
   (else "The microphone failed")))

;; On a request thread: C's page could not capture; end its capture and
;; tell its failure callback why, on the editor loop.
(def (accept-problem (self : microphone-state) (c : client) (bytes : :u8vector)) => :void
  (let* ((report (with-catch (lambda (e) #f) (lambda ()
                                    (parameterize ((current-json-read-options
                                                    (JSONReadOptions object-as-hash: #t)))
                                      (string->json (utf8->string bytes))))))
         (sentence (if (hash-table? report)
                     (problem-sentence (hash-get report "problem") (hash-get report "name"))
                     (problem-sentence #f #f)))
         (found (take-capture! self c)))
    (when found
      (using (found : capture)
        ((capture-post found) 'microphone-failure (lambda () ((capture-on-failure found) sentence)))))))

(defplugin (microphone ctx)
  "Captures a browser tab's microphone as 16 kHz audio for other plugins."
  provides: [microphone-service]
  requires: [page-service]
  (using (self (microphone-state mutex: (make-mutex 'microphone) captures: (make-hash-table-eq))
               : microphone-state)
    (add-script "web/microphone.js")
    (context-add-page-address! ctx "chunk" (lambda (c bytes) (accept-chunk self c bytes)))
    (context-add-page-address! ctx "problem" (lambda (c bytes) (accept-problem self c bytes)))
    (context-add-hook! ctx client-gone-hook 'microphone
                       (lambda ((c : client))
                         (let (found (take-capture! self c))
                           (when found
                             ((capture-on-failure found) "The tab capturing the microphone went away")))))
    (context-defer! ctx (lambda ()
                          (for-each (lambda ((c : client)) (stop-capture! self c))
                                    (do-with-lock self.mutex (hash-keys self.captures)))))
    (context-provide! ctx microphone-service (Microphone self))))

(implement Microphone microphone-state
  (start! (lambda (self c on-chunk on-failure) (start-capture! self c on-chunk on-failure)))
  (stop! (lambda (self c) (stop-capture! self c))))

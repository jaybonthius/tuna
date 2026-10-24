;;; The speech worker: a separate program, because parakeet's calls block
;;; the whole Gerbil runtime. Built by `make voice-worker`, never by `make`.
;;;
;;; Usage: tuna-voice-worker MODEL [LANGUAGE] [--grammar FILE] [--beam N]
;;; Reads raw float32 little-endian mono 16 kHz audio on stdin, in any
;;; chunk sizes, and writes one JSON line per result on stdout:
;;;   {"ready":true}                 the model is loaded; send audio
;;;   {"text":"…","eou":false}       newly finalized text; append it as is
;;;   {"done":true}                  stdin ended and the tail is flushed
;;;   {"error":"…"}                  then the worker exits nonzero
;;; Each text keeps the model's leading space, so the texts concatenate into
;;; correctly spaced prose. "eou" is true when the model detected the end
;;; of an utterance (a pause), and the text may then be empty. Language tags
;;; such as <en-US> are removed.
;;;
;;; With --grammar, recognition is limited to the grammar in FILE
;;; (parakeet's grammar syntax), searched with a beam of N (default 8), and
;;; instead of text lines the worker writes, for each read it fed, the
;;; grammar stream's own JSON document on one line, and at the end of its
;;; input the finalized document, before {"done":true}:
;;;   {"partial":"…","units":[{"text","score","free_score","frames",
;;;    "alternatives":[{"text","score"}],…}],"events":[…]}
;;;   {"no_match":true}              the stream ended without a match: after
;;;                                  a feed, the rest of the input is read
;;;                                  and dropped; after finalizing, the
;;;                                  tail was incomplete
(import :std/ffi
        :std/encoding/json
        (only-in :std/misc/ports read-all-as-string)
        :std/text/pregexp
        :std/vector/u8vector
        :parakeet/api)
(export main)

;; libgomp reads OMP_WAIT_POLICY once, in its shared-library constructor,
;; before any Scheme code runs. Its default active waiting spun this
;; machine's build at full CPU for minutes without finishing 7 s of audio,
;; so the executable's preinit entry re-executes the worker with exactly
;; OMP_WAIT_POLICY=PASSIVE and no GOMP_SPINCOUNT whenever the environment
;; says anything else, including nothing.
;;
;; The Gambit runtime then pins its thread to one CPU, and the inference
;; threads it starts inherit that, so recognition would run on one core.
;; The preinit entry also records the CPUs the worker was started with, and
;; main gives them back to its thread before loading the model.
(C-declare #<<END-C
#include <limits.h>
#include <sched.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int worker_openmp_wait_entry(const char *entry)
{
  return strncmp(entry, "OMP_WAIT_POLICY=", 16) == 0 ||
         strncmp(entry, "GOMP_SPINCOUNT=", 15) == 0;
}

/* Gambit's header includes the system headers before this code, without
   _GNU_SOURCE, so glibc's affinity calls must be declared here. */
extern int sched_getaffinity(pid_t, size_t, cpu_set_t *);
extern int sched_setaffinity(pid_t, size_t, const cpu_set_t *);

static cpu_set_t worker_startup_cpus;
static int worker_startup_cpus_known;

static void worker_restore_startup_cpus(void)
{
  if (worker_startup_cpus_known)
    sched_setaffinity(0, sizeof(worker_startup_cpus), &worker_startup_cpus);
}

static void worker_startup(int argc, char **argv, char **envp)
{
  static const char failure[] = "{\"error\":\"cannot set OMP_WAIT_POLICY=PASSIVE\"}\n";
  size_t count = 0, kept = 0;
  int passive = 0, other = 0;
  (void)argc;
  worker_startup_cpus_known =
    sched_getaffinity(0, sizeof(worker_startup_cpus), &worker_startup_cpus) == 0;
  for (; envp[count] != NULL; ++count) {
    if (strcmp(envp[count], "OMP_WAIT_POLICY=PASSIVE") == 0)
      passive = 1;
    else if (worker_openmp_wait_entry(envp[count]))
      other = 1;
  }
  if (passive && !other)
    return;
  char **environment = malloc((count + 2) * sizeof(char *));
  if (environment != NULL) {
    for (size_t i = 0; i < count; ++i)
      if (!worker_openmp_wait_entry(envp[i]))
        environment[kept++] = envp[i];
    environment[kept++] = "OMP_WAIT_POLICY=PASSIVE";
    environment[kept] = NULL;
    /* Executing the resolved path rather than /proc/self/exe keeps the
       process name, which would otherwise become "exe". */
    char path[PATH_MAX];
    ssize_t length = readlink("/proc/self/exe", path, sizeof(path) - 1);
    if (length > 0) {
      path[length] = '\0';
      execve(path, argv, environment);
    }
    execve("/proc/self/exe", argv, environment);
  }
  ssize_t written = write(STDOUT_FILENO, failure, sizeof(failure) - 1);
  (void)written;
  _exit(127);
}

__attribute__((used, section(".preinit_array")))
static void (*const worker_startup_entry)(int, char **, char **) = worker_startup;
END-C
)

(def-C-lambda (restore-startup-cpus!) => void "worker_restore_startup_cpus")

(def (main . arguments)
  (with-catch
   (lambda (exception)
     (write-line! (string-append "{\"error\":" (json->string (exception-text exception)) "}"))
     (exit 1))
   (lambda ()
     (match arguments
       ([model-path] (transcribe-stdin model-path ""))
       ([model-path language] (transcribe-stdin model-path language))
       ([model-path "--grammar" grammar-path . options]
        (grammar-stdin model-path "" grammar-path options))
       ([model-path language "--grammar" grammar-path . options]
        (grammar-stdin model-path language grammar-path options))
       (else (error usage))))))

(def usage "Usage: tuna-voice-worker MODEL [LANGUAGE] [--grammar FILE [--beam N]]")

(def (transcribe-stdin (model-path : :string) (language : :string)) => :void
  (restore-startup-cpus!)
  (let (model (load-model model-path))
    (unwind-protect
      (let (stream (begin-asr-stream model language: language))
        (unwind-protect
          (begin
            (write-line! "{\"ready\":true}")
            (feed-stdin! stream)
            (report! (asr-stream-finalize stream) #f))
          (close-asr-stream! stream)))
      (close-model! model)))
  (write-line! "{\"done\":true}"))

(def (grammar-stdin (model-path : :string) (language : :string) (grammar-path : :string)
                    (options : :list)) => :void
  (let (beam (match options
               ([] 8)
               (["--beam" n] (or (string->number n) (error usage)))
               (else (error usage))))
    (restore-startup-cpus!)
    (let (model (load-model model-path))
      (unwind-protect
        (let* ((compiled (create-grammar model (call-with-input-file grammar-path read-all-as-string)))
               (stream (unwind-protect
                         (begin-grammar-stream model compiled beam-size: beam language: language)
                         ;; The stream keeps its own reference to the grammar.
                         (close-grammar! compiled))))
          (unwind-protect
            (begin
              (write-line! "{\"ready\":true}")
              (let (matching?
                    (read-stdin-samples!
                     (lambda ((samples : :f32vector) (count : :fixnum))
                       (report-grammar! (grammar-stream-feed-json stream samples count: count)))))
                (if matching?
                  (report-grammar! (grammar-stream-finalize-json stream))
                  ;; NO_MATCH ended the stream; read the rest of the input,
                  ;; so the writer's last chunks do not fail, and drop it.
                  (read-stdin-samples! (lambda (samples count) #t)))))
            (close-grammar-stream! stream)))
        (close-model! model))))
  (write-line! "{\"done\":true}"))

;; Write a grammar stream's document as one line, and {"no_match":true}
;; after it when the stream ended without a match. Whether it matched.
(def (report-grammar! (result :~ grammar-result?)) => :boolean
  (let (payload (grammar-result-payload result))
    (when payload
      (write-line! payload))
    (or (= (grammar-result-status result) grammar-ok)
        (begin (write-line! "{\"no_match\":true}") #f))))

(def (feed-stdin! (stream :~ asr-stream?)) => :void
  (read-stdin-samples!
   (lambda ((samples : :f32vector) (count : :fixnum))
     (let (update (asr-stream-feed stream samples count: count))
       (report! (stream-update-text update)
                (not (fxzero? (fxand (stream-update-event-mask update) event-eou)))))
     #t)))

(def pcm-buffer-bytes 65536)

;; Call (FEED SAMPLES COUNT) with the samples of each read as it arrives
;; rather than waiting for more, until the input ends or FEED returns #f.
;; Returns #f when FEED did. A read can end inside a sample; its bytes are
;; kept for the next read. A fragment left at end of input is not audio
;; and is dropped.
(def (read-stdin-samples! (feed : :procedure)) => :boolean
  (let ((bytes (make-u8vector pcm-buffer-bytes))
        (samples (make-f32vector (fxquotient pcm-buffer-bytes 4)))
        (port (current-input-port)))
    (let loop ((held 0))
      (let (count (read-subu8vector bytes held pcm-buffer-bytes port 1))
        (if (fxzero? count)
          #t
          (let* ((total (fx+ held count))
                 (sample-count (fxquotient total 4))
                 (used (fx* sample-count 4)))
            (let decode ((index 0))
              (when (fx< index sample-count)
                (f32vector-set! samples index (u8vector-float-ref bytes (fx* index 4) 'little))
                (decode (fx+ index 1))))
            (subu8vector-move! bytes used total bytes 0)
            (if (or (fxzero? sample-count) (feed samples sample-count))
              (loop (fx- total used))
              #f)))))))

;; Nemotron marks the language after a sentence, as in "eyes. <en-US> It".
;; Removing a tag with the whitespace before it keeps the space that the
;; next word carries, even when the tag ends one result and the word starts
;; the next.
(def language-tag (pregexp "\\s*<[a-z]{2,3}(?:-[A-Z]{2})?>"))

(def (report! (text : :string) (eou? : :boolean)) => :void
  (let (clean (:- (pregexp-replace* language-tag text "") :string))
    (unless (and (fxzero? (string-length clean)) (not eou?))
      (write-line! (string-append "{\"text\":" (json->string clean)
                                  ",\"eou\":" (if eou? "true" "false") "}")))))

(def (write-line! (line : :string)) => :void
  (write-string line)
  (newline)
  (force-output))

(def (exception-text exception) => :string
  (if (Error? exception)
    (:- (error-message exception) :string)
    (:- (pregexp-replace* "^\\s+|\\s+$"
                          (call-with-output-string
                           (lambda (port) (display-exception exception port)))
                          "")
        :string)))

;;; The speech worker: a separate program, because parakeet's calls block
;;; the whole Gerbil runtime. Built by `make voice-worker`, never by `make`.
;;;
;;; Usage: tuna-voice-worker MODEL [LANGUAGE]
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
(import :std/ffi
        :std/encoding/json
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
       (else (error "Usage: tuna-voice-worker MODEL [LANGUAGE]"))))))

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

(def pcm-buffer-bytes 65536)

;; Feeds each read as it arrives rather than waiting for more. A read can
;; end inside a sample; its bytes are kept for the next read. A fragment
;; left at end of input is not audio and is dropped.
(def (feed-stdin! (stream :~ asr-stream?)) => :void
  (let ((bytes (make-u8vector pcm-buffer-bytes))
        (samples (make-f32vector (fxquotient pcm-buffer-bytes 4)))
        (port (current-input-port)))
    (let loop ((held 0))
      (let (count (read-subu8vector bytes held pcm-buffer-bytes port 1))
        (unless (fxzero? count)
          (let* ((total (fx+ held count))
                 (sample-count (fxquotient total 4))
                 (used (fx* sample-count 4)))
            (let decode ((index 0))
              (when (fx< index sample-count)
                (f32vector-set! samples index (u8vector-float-ref bytes (fx* index 4) 'little))
                (decode (fx+ index 1))))
            (unless (fxzero? sample-count)
              (let (update (asr-stream-feed stream samples count: sample-count))
                (report! (stream-update-text update)
                         (not (fxzero? (fxand (stream-update-event-mask update) event-eou))))))
            (subu8vector-move! bytes used total bytes 0)
            (loop (fx- total used))))))))

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

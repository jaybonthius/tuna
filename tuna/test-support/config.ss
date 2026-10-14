;;; Plugins for the configuration tests (tuna/boot-test.ss). The init.ss
;;; files those tests write import this module by its absolute path. Each
;;; plugin turns a named probe on through its context, so the probe is off
;;; again once its receipt has run.
(import :tuna/kernel
        :tuna/lib/plugin-options
        :tuna/services/session)
(export optioned-plugin
        last-greeting
        optioned-dependent-plugin
        dependent-greeting
        fixed-optioned-plugin
        fixed-n
        plugin-named-session-owner
        probe-on!
        probe-on?
        probe-service
        note-activation!
        activation-count
        good-plugin
        provider-plugin
        better-provider-plugin
        stubborn-provider-plugin
        failing-provider-plugin
        dependent-plugin
        hanging-plugin
        plugin-named-init
        counted-plugin
        fixed-service
        fixed-provider-plugin
        better-fixed-provider-plugin
        fixed-needs-probe-plugin
        record-restore!
        restored-data
        notes-text
        set-notes-text!
        notes-plugin
        set-callback!
        call-callback)

;; Probe name -> live registrations.
(def probes (make-hash-table))

;; Turn the probe NAME on until the current plugin is deactivated.
(def (probe-on! (name : :symbol)) => :void
  (hash-update! probes name fx1+ 0)
  (context-defer! (current-context)
                  (lambda () (hash-update! probes name fx1- 0))))

(def (probe-on? (name : :symbol)) => :boolean
  (positive? (hash-ref probes name 0)))

;; Name -> how many times it was activated; never undone.
(def activations (make-hash-table))

(def (note-activation! (name : :symbol)) => :void
  (hash-update! activations name fx1+ 0))

(def (activation-count (name : :symbol)) => :fixnum
  (hash-ref activations name 0))

(def probe-service
  (new-service 'probe (lambda (x) (eq? x 'probe)) tier: 'live
               doc: "A service for configuration tests."))

(defplugin good-plugin "Turns the probe good on."
  (probe-on! 'good))

(defplugin provider-plugin "Provides the probe service."
  provides: [probe-service]
  (context-provide! (current-context) probe-service 'probe)
  (probe-on! 'provider))

;; Outranks provider-plugin, so its dependents restart when it comes on.
(defplugin better-provider-plugin "Provides the probe service as an alternative."
  provides: [probe-service]
  (context-provide! (current-context) probe-service 'probe))

;; Provides the probe service, then ignores being asked to stop for about
;; a second, then fails.
(defplugin stubborn-provider-plugin "Provides the probe service, ignores being stopped, then fails."
  provides: [probe-service]
  (context-provide! (current-context) probe-service 'probe)
  (probe-on! 'stubborn)
  (let (deadline (+ (time->seconds (current-time)) 1.))
    (let spin ()
      (when (< (time->seconds (current-time)) deadline)
        (with-catch void (lambda () (thread-sleep! 0.01)))
        (spin))))
  (error "stubborn-provider-plugin gave up"))

(defplugin failing-provider-plugin "Provides the probe service, then fails."
  provides: [probe-service]
  (context-provide! (current-context) probe-service 'probe)
  (probe-on! 'failing-provider)
  (error "failing-provider-plugin fails on purpose"))

(defplugin dependent-plugin "Needs the probe service."
  requires: [probe-service]
  (probe-on! 'dependent))

;; A plugin whose name the configuration reserves for the user's code.
(def plugin-named-init
  (let ()
    (defplugin init "Takes a reserved name.")
    init))

;; Spins until stopped. The loop has a body: gxc -O never finishes
;; compiling an empty self-loop (agents/guides/gerbil.md).
(defplugin hanging-plugin "Never finishes activating."
  (probe-on! 'hanging)
  (let spin ((n 0))
    (spin (if (fx< n 1000) (fx1+ n) 0))))

;; Counts its activations under its own name.
(defplugin counted-plugin "Counts its activations."
  (note-activation! 'counted-plugin)
  (probe-on! 'counted))

;; A startup-tier service: while the editor loop runs, reload refuses
;; to take it from its provider.
(def fixed-service
  (new-service 'fixed (lambda (x) (eq? x 'fixed)) tier: 'startup
               doc: "A startup-tier service for configuration tests."))

(defplugin fixed-provider-plugin "Provides the startup-tier service fixed."
  provides: [fixed-service]
  (context-provide! (current-context) fixed-service 'fixed)
  (probe-on! 'fixed))

(defplugin better-fixed-provider-plugin "Provides fixed as an alternative."
  provides: [fixed-service]
  (context-provide! (current-context) fixed-service 'fixed)
  (probe-on! 'better-fixed))

;; Slot name -> the data its last restore received; never undone.
(def restores (make-hash-table))

(def (record-restore! (name : :symbol) (data : :t)) => :void
  (hash-put! restores name data))

(def (restored-data (name : :symbol)) => :t
  (hash-ref restores name #f))

(def current-notes "fresh")
(def (notes-text) => :string current-notes)
(def (set-notes-text! (text : :string)) => :void (set! current-notes text))

;; Keeps the session slot notes: saves the notes text, records restores.
(defplugin notes-plugin "Keeps a session slot."
  requires: [session-service]
  (context-add-session-slot! (current-context) 'notes version: 1
                             save: notes-text
                             restore: (lambda (data)
                                        (record-restore! 'notes data)
                                        (set-notes-text! data))))

;; Provides the startup-tier service fixed and needs probe, so while the
;; editor loop runs the kernel refuses to turn probe's provider off.
(defplugin fixed-needs-probe-plugin "Provides fixed; needs probe."
  provides: [fixed-service]
  requires: [probe-service]
  (context-provide! (current-context) fixed-service 'fixed)
  (probe-on! 'fixed-needs-probe))

;; Name -> a procedure a plugin left for the test to call; never undone.
(def callbacks (make-hash-table))

(def (set-callback! (name : :symbol) (proc : :procedure)) => :void
  (hash-put! callbacks name proc))

(def (call-callback (name : :symbol)) => :t
  ((hash-ref callbacks name)))

;; Accepts options; records the greeting it was given at its last
;; activation, and fails when its option fail is #t.
(def current-greeting #f)
(def (last-greeting) => :t current-greeting)

(defplugin optioned-plugin "Takes options."
  (note-activation! 'optioned-plugin)
  (when (plugin-option optioned-plugin 'fail)
    (error "optioned-plugin was told to fail"))
  (set! current-greeting (plugin-option optioned-plugin 'greeting))
  (probe-on! 'optioned))

(defplugin-options optioned-plugin
  (greeting "hello" "What to say." string-type)
  (times 1 "How often to say it." (integer-type 1 10))
  (fail #f "Fail on activation." boolean-type))

;; Needs the probe service, so the kernel restarts it when the provider
;; changes; records the greeting it read at its last activation.
(def current-dependent-greeting #f)
(def (dependent-greeting) => :t current-dependent-greeting)

(defplugin optioned-dependent-plugin "Needs the probe service and takes an option."
  requires: [probe-service]
  (note-activation! 'optioned-dependent-plugin)
  (set! current-dependent-greeting (plugin-option optioned-dependent-plugin 'greeting)))

(defplugin-options optioned-dependent-plugin
  (greeting "hello" "What to say." string-type))

;; Provides the startup-tier service fixed and takes an option, so an
;; option change waits for the next start while the editor loop runs.
(def current-fixed-n #f)
(def (fixed-n) => :t current-fixed-n)

(defplugin fixed-optioned-plugin "Provides fixed; takes the option n."
  provides: [fixed-service]
  (context-provide! (current-context) fixed-service 'fixed)
  (set! current-fixed-n (plugin-option fixed-optioned-plugin 'n)))

(defplugin-options fixed-optioned-plugin
  (n 1 "A number." (integer-type 0 9)))

;; A plugin whose name the configuration reserves for its service plugin.
(def plugin-named-session-owner
  (let ()
    (defplugin session-owner "Takes a reserved name.")
    session-owner))

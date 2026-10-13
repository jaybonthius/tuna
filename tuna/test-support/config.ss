;;; Plugins for the configuration tests (tuna/boot-test.ss). The init.ss
;;; files those tests write import this module by its absolute path. Each
;;; plugin turns a named probe on through its context, so the probe is off
;;; again once its receipt has run.
(import :tuna/kernel)
(export probe-on!
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
        plugin-named-init)

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
  (context-provide! (current-context) probe-service 'probe)
  (probe-on! 'provider))

;; Outranks provider-plugin, so its dependents restart when it comes on.
(defplugin better-provider-plugin "Provides the probe service with a higher priority."
  (context-provide! (current-context) probe-service 'probe priority: 10))

;; Provides the probe service, then ignores being asked to stop for about
;; a second, then fails.
(defplugin stubborn-provider-plugin "Provides the probe service, ignores being stopped, then fails."
  (context-provide! (current-context) probe-service 'probe)
  (probe-on! 'stubborn)
  (let (deadline (+ (time->seconds (current-time)) 1.))
    (let spin ()
      (when (< (time->seconds (current-time)) deadline)
        (with-catch void (lambda () (thread-sleep! 0.01)))
        (spin))))
  (error "stubborn-provider-plugin gave up"))

(defplugin failing-provider-plugin "Provides the probe service, then fails."
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

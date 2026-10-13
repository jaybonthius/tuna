;;; The help service: where help commands show their output. The default
;;; shows it in the *Help* buffer, an ordinary buffer in a view (ADR 13).
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel)
(export (interface-out Help)
        help-service
        (struct-out help-output)
        show-help
        current-help)

(defstruct help-output ((title : :string)
                        (lines : :list))      ; strings
  final: #t)

(interface Help
  (show-help! (output : help-output)) => :void
  ;; The help output shown last, or #f.
  (current-help) => :t)

(def help-service
  (new-service 'help is-Help? tier: 'live
               doc: "Shows help output."))

(def (show-help (title : :string) (lines : :list)) => :void
  (let (provider (service-provider help-service))
    (unless provider
      (error "No plugin shows help"))
    (Help-show-help! (Help provider) (make-help-output title lines))))

(def (current-help) => (Maybe help-output)
  (let (provider (service-provider help-service))
    (and provider (Help-current-help (Help provider)))))

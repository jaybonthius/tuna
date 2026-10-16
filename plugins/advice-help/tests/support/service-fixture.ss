prelude: :gerbil/core
(import :std/interface :tuna/kernel)
(export (service-interface-out InspectionProbe) probe-service inspection-probe)

(service-interface InspectionProbe
  (probe) => :fixnum)

(def probe-service
  (new-service 'inspection-probe is-InspectionProbe? tier: 'live doc: "Inspection fixture."))

(defclass probe-provider () final: #t)
(implement InspectionProbe probe-provider
  (probe (lambda (self) 7)))

(defplugin (inspection-probe ctx)
  "A service fixture independent of Completion and Help."
  provides: [probe-service]
  (context-provide! ctx probe-service (InspectionProbe (probe-provider))
                    view: InspectionProbe-service-view))

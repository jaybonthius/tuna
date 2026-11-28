#!tuna
(import (sampler) (metrics) (jobs) (options) (sensors data))

(define (%restart-sources root)
  (for-each sampler:restart! (list hwmon batteries)))

(options:define-option sys-root "/sys" string? "Where the kernel's device files are." %restart-sources)

(define (%record! m labels value time)
  (when value (metrics:record! m labels value time)))

;; The kernel defines no critical limits for a fan, so those pairs have no
;; metric.
(define (%metric-of kind attribute)
  (if (eq? attribute 'alarm)
      sensor-alarm
      (case kind
        [(temperature)
         (case attribute
           [(input) temperature] [(max) temperature-max] [(min) temperature-min] [(crit) temperature-crit]
           [(lcrit) temperature-lcrit] [else #f])]
        [(fan) (case attribute [(input) fan-speed] [(max) fan-max] [(min) fan-min] [else #f])]
        [(voltage)
         (case attribute
           [(input) voltage] [(max) voltage-max] [(min) voltage-min] [(crit) voltage-crit] [(lcrit) voltage-lcrit]
           [else #f])]
        [(power)
         (case attribute
           [(input) power] [(max) power-max] [(min) power-min] [(crit) power-crit] [(lcrit) power-lcrit] [else #f])]
        [(current)
         (case attribute
           [(input) current] [(max) current-max] [(min) current-min] [(crit) current-crit] [(lcrit) current-lcrit]
           [else #f])]
        [else #f])))

(define (%record-hwmon time data)
  (for-each
    (lambda (v)
      (let ([m (%metric-of (sensor-value-kind v) (sensor-value-attribute v))])
        (when m
          (%record! m (list (sensor-value-chip v) (sensor-value-device v) (sensor-value-sensor v)) (sensor-value-value v)
                    time))))
    data))

(define (%record-batteries time data)
  (for-each
    (lambda (b)
      (let ([labels (list (battery-reading-name b))])
        (%record! battery-charge labels (battery-reading-charge b) time)
        (%record! battery-energy labels (battery-reading-energy b) time)
        (%record! battery-power labels (battery-reading-power b) time)
        (%record! battery-plugged labels (battery-reading-plugged b) time)
        (%record! battery-charging labels (battery-reading-charging b) time)
        (%record! battery-seconds-left labels (battery-reading-seconds-left b) time)))
    data))

(jobs:define-worker (%hwmon-reader root emit receive)
  (import (sampler reading) (sensors readings))
  (reading-loop hwmon-reading root emit receive))

(jobs:define-worker (%batteries-reader root emit receive)
  (import (sampler reading) (sensors readings))
  (reading-loop batteries-reading root emit receive))

(sampler:define-source hwmon %hwmon-reader sys-root %record-hwmon)
(sampler:define-source batteries %batteries-reader sys-root %record-batteries)

(metrics:define-metric temperature (unit celsius) (labels chip device sensor) (source hwmon)
  (documentation "A temperature sensor's reading."))
(metrics:define-metric temperature-min (unit celsius) (labels chip device sensor) (source hwmon)
  (documentation "A temperature sensor's lower limit."))
(metrics:define-metric temperature-max (unit celsius) (labels chip device sensor) (source hwmon)
  (documentation "A temperature sensor's upper limit."))
(metrics:define-metric temperature-crit (unit celsius) (labels chip device sensor) (source hwmon)
  (documentation "A temperature sensor's critical upper limit."))
(metrics:define-metric temperature-lcrit (unit celsius) (labels chip device sensor) (source hwmon)
  (documentation "A temperature sensor's critical lower limit."))
(metrics:define-metric fan-speed (unit rpm) (labels chip device sensor) (source hwmon) (documentation "A fan's speed."))
(metrics:define-metric fan-min (unit rpm) (labels chip device sensor) (source hwmon) (documentation "A fan's lower limit."))
(metrics:define-metric fan-max (unit rpm) (labels chip device sensor) (source hwmon) (documentation "A fan's upper limit."))
(metrics:define-metric voltage (unit volts) (labels chip device sensor) (source hwmon)
  (documentation "A voltage sensor's reading."))
(metrics:define-metric voltage-min (unit volts) (labels chip device sensor) (source hwmon)
  (documentation "A voltage sensor's lower limit."))
(metrics:define-metric voltage-max (unit volts) (labels chip device sensor) (source hwmon)
  (documentation "A voltage sensor's upper limit."))
(metrics:define-metric voltage-crit (unit volts) (labels chip device sensor) (source hwmon)
  (documentation "A voltage sensor's critical upper limit."))
(metrics:define-metric voltage-lcrit (unit volts) (labels chip device sensor) (source hwmon)
  (documentation "A voltage sensor's critical lower limit."))
(metrics:define-metric power (unit watts) (labels chip device sensor) (source hwmon)
  (documentation "A power sensor's reading, or its average where it reports only that."))
(metrics:define-metric power-min (unit watts) (labels chip device sensor) (source hwmon)
  (documentation "A power sensor's lower limit."))
(metrics:define-metric power-lcrit (unit watts) (labels chip device sensor) (source hwmon)
  (documentation "A power sensor's critical lower limit."))
(metrics:define-metric power-max (unit watts) (labels chip device sensor) (source hwmon)
  (documentation "A power sensor's upper limit."))
(metrics:define-metric power-crit (unit watts) (labels chip device sensor) (source hwmon)
  (documentation "A power sensor's critical limit."))
(metrics:define-metric current (unit amperes) (labels chip device sensor) (source hwmon)
  (documentation "A current sensor's reading."))
(metrics:define-metric current-min (unit amperes) (labels chip device sensor) (source hwmon)
  (documentation "A current sensor's lower limit."))
(metrics:define-metric current-max (unit amperes) (labels chip device sensor) (source hwmon)
  (documentation "A current sensor's upper limit."))
(metrics:define-metric current-crit (unit amperes) (labels chip device sensor) (source hwmon)
  (documentation "A current sensor's critical upper limit."))
(metrics:define-metric current-lcrit (unit amperes) (labels chip device sensor) (source hwmon)
  (documentation "A current sensor's critical lower limit."))
(metrics:define-metric sensor-alarm (unit count) (labels chip device sensor) (source hwmon)
  (documentation "1 while a sensor's chip raises its alarm, else 0."))
(metrics:define-metric battery-charge (unit ratio) (labels battery) (source batteries)
  (documentation "A battery's charge: its energy over its full energy, else the capacity it reports."))
(metrics:define-metric battery-energy (unit joules) (labels battery) (source batteries)
  (documentation "A battery's energy."))
(metrics:define-metric battery-power (unit watts) (labels battery) (source batteries)
  (documentation "Power drawn from or into a battery."))
(metrics:define-metric battery-plugged (unit count) (labels battery) (source batteries)
  (documentation "1 when a mains supply is online, or the battery is charging or full; 0 when it discharges."))
(metrics:define-metric battery-charging (unit count) (labels battery) (source batteries)
  (documentation "1 while a battery charges, else 0."))
(metrics:define-metric battery-seconds-left (unit seconds) (labels battery) (source batteries)
  (documentation "A battery's time left while unplugged: energy over power, else charge over current."))

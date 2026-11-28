(import (tuna) (test) (test-runner) (options) (sampler) (metrics) (sensors) (sampler-test) (metrics-test latest))

(define (fixture name)
  (string-append (path-parent (car (command-line))) "/plugins/sensors/tests/lib/sensors-test/fixtures/" name))

(test "on this machine the processor's temperature is recorded in degrees, labelled by chip, device and sensor"
  (sampler-test:wanting sensors:hwmon 5
    (lambda ()
      (let ([tctl (metrics-test/latest:latest-value sensors:temperature '("k10temp" "0000:00:18.3" "Tctl"))])
        (check (flonum? tctl))
        (check (< 10 tctl 120))))))

(test "on this machine there is no battery, so no battery series, and the source does not fail"
  (sampler-test:wanting sensors:batteries 5
    (lambda ()
      (check-equal? #f (sampler:failure sensors:batteries))
      (check-equal? '() (metrics:label-sets sensors:battery-charge)))))

(options:set! sensors:sys-root (fixture "sys"))

(test "limits and alarms are recorded with the reading, each limit a metric of its own"
  (sampler-test:wanting sensors:hwmon 3600
    (lambda ()
      (let ([composite '("nvme" "nvme0" "Composite")])
        (check-equal? 84.85 (metrics-test/latest:latest-value sensors:temperature-crit composite))
        (check-equal? 0.0 (metrics-test/latest:latest-value sensors:sensor-alarm composite))
        (check (metrics-test/latest:latest-value sensors:temperature-max composite))
        (check-equal? #f (metrics:latest sensors:temperature-crit '("k10temp" "0000:00:18.3" "Tctl"))))
      (check-equal? 29.12 (metrics-test/latest:latest-value sensors:power '("amdgpu" "0000:c5:00.0" "PPT")))
      (check-equal? 1.297 (metrics-test/latest:latest-value sensors:voltage '("amdgpu" "0000:c5:00.0" "vddgfx")))
      (check (metrics-test/latest:latest-value sensors:temperature '("acpitz" "thermal_zone0" "temp1"))))))

;; nvme0's second temperature's file becomes a link to nothing, as a file
;; a chip has stopped giving reads; amdgpu's power sensor gains lower
;; limits, which this machine's chip has not.
(define altered
  (let ([to (sampler-test:scratch "sys-altered")])
    (sampler-test:copy-tree! (fixture "sys") to)
    (sampler-test:point! (string-append to "/class/hwmon/hwmon1/temp2_input") "missing")
    (sampler-test:write-text! (string-append to "/class/hwmon/hwmon5/power1_min") "5000000\n")
    (sampler-test:write-text! (string-append to "/class/hwmon/hwmon5/power1_lcrit") "1000000\n")
    to))

(define (recorded-at? m labels time)
  (let ([p (metrics:latest m labels)]) (and p (= (car p) time))))

(test "a sensor whose value cannot be read records nothing that reading, and the others are recorded"
  (options:set! sensors:sys-root altered)
  (sampler-test:wanting sensors:hwmon 3600
    (lambda ()
      (let ([time (sampler:last-time sensors:hwmon)])
        (check (recorded-at? sensors:temperature '("nvme" "nvme0" "Composite") time))
        (check (not (recorded-at? sensors:temperature '("nvme" "nvme0" "Sensor 1") time)))
        (check (recorded-at? sensors:temperature-max '("nvme" "nvme0" "Sensor 1") time))))))

(test "a power sensor's lower limits are recorded as metrics of their own"
  (sampler-test:wanting sensors:hwmon 3600
    (lambda ()
      (check-equal? 5.0 (metrics-test/latest:latest-value sensors:power-min '("amdgpu" "0000:c5:00.0" "PPT")))
      (check-equal? 1.0 (metrics-test/latest:latest-value sensors:power-lcrit '("amdgpu" "0000:c5:00.0" "PPT"))))))

(test "a battery that discharges: unplugged, with its charge and the seconds left"
  (options:set! sensors:sys-root (fixture "battery"))
  (sampler-test:wanting sensors:batteries 3600
    (lambda ()
      (check-equal? 0.0 (metrics-test/latest:latest-value sensors:battery-plugged '("BAT0")))
      (check-equal? 14400.0 (metrics-test/latest:latest-value sensors:battery-seconds-left '("BAT0")))
      (check-equal? 0.8 (metrics-test/latest:latest-value sensors:battery-charge '("BAT0")))
      (check-equal? 0.0 (metrics-test/latest:latest-value sensors:battery-charging '("BAT0")))
      (check-equal? 144000.0 (metrics-test/latest:latest-value sensors:battery-energy '("BAT0")))
      (check-equal? 10.0 (metrics-test/latest:latest-value sensors:battery-power '("BAT0"))))))

(test "a mains supply online makes the battery plugged, and no seconds left are recorded"
  (options:set! sensors:sys-root (fixture "mains"))
  (sampler-test:wanting sensors:batteries 3600
    (lambda ()
      (let ([plugged (metrics:latest sensors:battery-plugged '("BAT0"))])
        (check-equal? 1.0 (cdr plugged))
        (check (> (car plugged) (car (metrics:latest sensors:battery-seconds-left '("BAT0")))))))))

(options:unset! sensors:sys-root)

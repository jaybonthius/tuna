prelude: :gerbil/core
package: tuna/tests/support/open-functions
(import "target")
(export outside outside-private)

(def (outside (n : :fixnum)) => :fixnum (typed n))
(def (outside-private (n : :fixnum)) => :fixnum (fx1+ (public-call n)))

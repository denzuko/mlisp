(:lists
 ((:id "mlisp-discuss"
   :subgroup :discuss
   :drop-address "mlisp-discuss@panix.com"
   :request-address "mlisp-request@panix.com"
   :description "mlisp general discussion (subscriber-writable)"
   :postal-address "Da Planet Security, c/o Office of the Principal, 1207 Delaware Ave, Suite 103, Wilmington DE 19806, USA"
   :privacy-url "https://dwightspencer.com/privacy"
   :auto-subscribe nil
   :max-bounces 5
   :subscribers ((:address "dwight@example.com"
                  :subscribed-at "2026-01-01T00:00:00"
                  :consent-method "email-subscribe-command"
                  :bounce-count 0)))
  (:id "mlisp-announce"
   :subgroup :announce
   :drop-address "mlisp-announce@panix.com"
   :request-address "mlisp-request@panix.com"
   :description "mlisp announcements (owner-post-only)"
   :postal-address "Da Planet Security, c/o Office of the Principal, 1207 Delaware Ave, Suite 103, Wilmington DE 19806, USA"
   :privacy-url "https://dwightspencer.com/privacy"
   :auto-subscribe nil
   :max-bounces 5
   :subscribers ((:address "admin@network.org"
                  :subscribed-at "2026-01-01T00:00:00"
                  :consent-method "email-subscribe-command"
                  :bounce-count 0)))
  (:id "mlisp-devel"
   :subgroup :devel
   :drop-address "mlisp-devel@panix.com"
   :request-address "mlisp-request@panix.com"
   :description "mlisp patches and VCS traffic (subscriber-writable)"
   :postal-address "Da Planet Security, c/o Office of the Principal, 1207 Delaware Ave, Suite 103, Wilmington DE 19806, USA"
   :privacy-url "https://dwightspencer.com/privacy"
   :auto-subscribe nil
   :max-bounces 5
   :subscribers ())
  (:id "mlisp-distrib"
   :subgroup :distrib
   :drop-address "mlisp-distrib@panix.com"
   :request-address "mlisp-request@panix.com"
   :description "mlisp binary release channel"
   :postal-address "Da Planet Security, c/o Office of the Principal, 1207 Delaware Ave, Suite 103, Wilmington DE 19806, USA"
   :privacy-url "https://dwightspencer.com/privacy"
   :auto-subscribe nil
   :max-bounces 5
   :distrib-path ""
   :subscribers ())
  (:id "mlisp-request"
   :subgroup :request
   :drop-address "mlisp-request@panix.com"
   :request-address "mlisp-request@panix.com"
   :description "mlisp command address (subscribe/unsubscribe/help)"
   :postal-address "Da Planet Security, c/o Office of the Principal, 1207 Delaware Ave, Suite 103, Wilmington DE 19806, USA"
   :privacy-url "https://dwightspencer.com/privacy"
   :auto-subscribe nil
   :max-bounces 5
   :subscribers ())))

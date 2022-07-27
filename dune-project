(lang dune 2.9)

(name dkml-component-staging-unixutils)
(version 0.1.0)

(generate_opam_files true)

(source
 (github diskuv/dkml-component-enduser-unixutils))
(license Apache-2.0)
(authors "Diskuv, Inc. <opensource+diskuv-ocaml@support.diskuv.com>")
(maintainers "opensource+diskuv-ocaml@support.diskuv.com")

(package
 (name dkml-component-staging-unixutils)
 (synopsis "Collection of end-user installers of common Unix utilities for all DKML installable platforms")
 (description
  "`unixutils` provides common Unix utilities for all DKML installable platforms, including Windows")
 (depends
  (dkml-install (>= 0.1.0))
  (digestif (>= 1.0.1))
  (diskuvbox (>= 0.1.0))))

(package
 (name dkml-component-network-unixutils)
 (synopsis "Network install of common Unix utilities for all DKML installable platforms")
 (description
  "`unixutils` provides common Unix utilities for all DKML installable platforms, including Windows")
 (depends
  (dkml-component-staging-unixutils (= :version))
  (dkml-component-staging-ocamlrun (and (>= 4.12.1~) (< 4.12.2~)))
  (dkml-component-staging-curl (>= 0.1.0))
  (dkml-install (>= 0.1.0))
  (diskuvbox (>= 0.1.0))
  ; We used to use `curly` but it buffers the file content in memory. MSYS2,
  ; which is only 95MB, fails on [Buffer.add] on 32-bit OCaml. We should have
  ; 2^30-1 as the unsigned int max (the 31th bit is the sign bit, and 32th
  ; bit is the OCaml tag bit), which is 1GB, but we also have to account for
  ; the garbage collector and inefficient code that may store multiple copies
  ; of the buffer in memory. Regardless, should never buffer the file content
  ; in memory.
  ; (curly (> 0.2.1))
  (digestif (>= 1.0.1))))

(package
 (name dkml-component-offline-unixutils)
 (synopsis "Offline install of common Unix utilities for all DKML installable platforms")
 (description
  "`unixutils` provides common Unix utilities for all DKML installable platforms, including Windows")
 (depends
  (dkml-component-staging-unixutils (= :version))
  (dkml-component-staging-ocamlrun (and (>= 4.12.1~) (< 4.12.2~)))
  (dkml-install (>= 0.1.0))
  (diskuvbox (>= 0.1.0))))

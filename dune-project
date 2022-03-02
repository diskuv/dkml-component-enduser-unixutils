(lang dune 2.9)
(using dune_site 0.1)

(name dkml-component-enduser-unixutils)
(version 0.1.0)

(generate_opam_files true)

(source
 (github diskuv/dkml-component-enduser-unixutils))
(license Apache-2.0)
(authors "Diskuv, Inc. <opensource+diskuv-ocaml@support.diskuv.com>")
(maintainers "opensource+diskuv-ocaml@support.diskuv.com")

(package
 (name dkml-component-enduser-unixutils)
 (synopsis "Common Unix utilities for all DKML installable platforms")
 (description
  "`unixutils` provides common Unix utilities for all DKML installable platforms, including Windows")
 (depends
  (dkml-component-staging-ocamlrun (>= 4.12.1-1))
  (dkml-component-staging-curl (>= 0.1.0))
  (dkml-install (>= 0.1.0))
  (dkml-install-runner (>= 0.1.0))
  (dune (>= 2.9))
  (dune-site (>= 2.9))
  ; Windows needs the 0.2.1-windows-dev patch which is only available in diskuv-opam-repository
  ; Try also:
  ; with-dkml opam pin add curly.0.2.1-windows-dev 'https://github.com/jonahbeckford/curly.git#windows-dev'
  (curly (= 0.2.1-windows-env))))

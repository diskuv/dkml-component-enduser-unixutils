# Development

## Prereqs

This is the Windows prerequisite for any development listed on this page:

```powershell
dkml init
opam install . --deps-only --with-test --yes
```

On Unix:

```sh
opam switch create . --repos 'default,diskuv-2.0.2=git+https://github.com/diskuv/diskuv-opam-repository.git#2.0.2'
```

# unixutils 0.1.0

The unixutils components provides common Unix utilities to all DKML
installable platforms, including Windows.

MSYS2 provides the Windows environment.

These components can be used with [dkml-install-api](https://diskuv.github.io/dkml-install-api/index.html)
to generate installers.

## Components

### network-unixutils

Network installation of Unix utilities. Pick this or `offline-unixutils`.

### offline-unixutils

Offline installation of Unix utilities. Pick this or `network-unixutils`.

### staging-unixutils

Internal shared bytecode between `network-unixutils` and `offline-unixutils`.
You should never need to directly rely on this component.

## Utilities

On Windows an MSYS2 installation will be available
at `%{prefix}%/tools/MSYS2`. However you should rely on the utility
paths documented below so your installation can work
on non-Windows/non-MSYS2 systems.

### sh

> `%{prefix}%/tools/unixutils/bin/sh`

On Windows the `sh.exe` is MSYS2's dash.exe. You will not
need to modify the PATH to run `sh.exe` since all shared
library dependencies like `msys-2.0.dll` will be present
alongside `sh.exe`.

On Unix and macOS the `sh` is a symlink to `/bin/dash` if Dash
is available, or `/bin/sh` if not.

## Contributing

See [the Contributors section of dkml-install-api](https://github.com/diskuv/dkml-install-api/blob/main/contributors/README.md).

## Status

[![Syntax check](https://github.com/diskuv/dkml-component-enduser-unixutils/actions/workflows/syntax.yml/badge.svg)](https://github.com/diskuv/dkml-component-enduser-unixutils/actions/workflows/syntax.yml)

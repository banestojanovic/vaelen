# Vaelen PHP Distribution

This directory contains versioned inputs for Vaelen-controlled PHP builds. It
does not contain PHP binaries.

The build uses a pinned `static-php-cli` source commit on a GitHub-hosted
Apple Silicon runner. The workflow builds CLI and FPM binaries, validates them,
archives them, computes SHA-256 hashes, and publishes a release manifest with
the artifacts.

The manifest's SHA-256 values verify artifact integrity against the trusted
Vaelen release manifest. SHA-256 alone is not an authenticity mechanism. The
initial trust root is the Vaelen GitHub repository, its reviewed workflow, and
its published release. A future signature or provenance layer can be added to
the manifest without changing the package model.

The package build intentionally uses the static-php-cli build mechanism rather
than republishing its hosted unsigned PHP archives.

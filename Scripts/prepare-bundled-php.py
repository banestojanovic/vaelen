#!/usr/bin/env python3
"""Prepare ignored PHP resources from the committed, digest-pinned descriptor."""

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import sys
import tarfile
import tempfile
import urllib.parse
import urllib.request


ROOT = Path(__file__).resolve().parent.parent
RESOURCE_PATH = Path("Sources/VaelenCore/Resources/PHPBundledRuntime")
KINDS = ("cli", "fpm")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
INSTALLED_APP_RESOURCES = Path(
    "/Applications/Vaelen.app/Contents/Resources/Vaelen_VaelenCore.bundle/Contents/Resources"
)


class PreparationError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise PreparationError(message)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def matches(path, digest):
    return path.is_file() and not path.is_symlink() and sha256(path) == digest


def safe_filename(value):
    require(isinstance(value, str) and value not in ("", ".", ".."), "Invalid artifact filename")
    require("/" not in value and "\\" not in value, "Artifact filenames must be plain basenames")
    return value


def load_descriptor(resources):
    descriptor = json.loads((resources / "bundled-runtime.json").read_text())
    require(descriptor.get("schemaVersion") == 1, "Unsupported bundled runtime schema")
    require(descriptor.get("module") == "php-bundled-runtime", "Unexpected bundled runtime module")
    require(descriptor["verification"]["algorithm"].lower() == "sha256", "Bundled runtime requires SHA-256")
    manifest = descriptor["manifest"]
    require(manifest["phpVersion"] == descriptor["phpVersion"], "Bundled PHP versions do not match")
    require(manifest["platform"] == "macos" and manifest["architecture"] == "arm64",
            "Bundled PHP descriptor must identify macOS arm64")
    require(manifest["verification"]["algorithm"].lower() == "sha256", "Archives require SHA-256")
    for kind, expected in (("cli", "php"), ("fpm", "php-fpm")):
        binary = descriptor["binaries"][kind]
        require(safe_filename(binary["file"]) == expected, "Unexpected bundled binary filename")
        require(SHA256.fullmatch(binary["sha256"]) is not None, "Missing pinned binary digest")
        artifact = manifest["artifacts"][kind]
        safe_filename(artifact["file"])
        require(SHA256.fullmatch(artifact["sha256"]) is not None, "Missing pinned archive digest")
        url = urllib.parse.urlsplit(artifact["url"])
        require(url.scheme == "https" and url.hostname and not url.username and not url.password,
                "Pinned archive URL must use HTTPS without credentials")
        require(not url.fragment, "Pinned archive URL must not contain a fragment")
    return descriptor


class HTTPSRedirectsOnly(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        require(urllib.parse.urlsplit(newurl).scheme == "https", "Archive redirect must remain HTTPS")
        return super().redirect_request(request, fp, code, msg, headers, newurl)


def verified_archive(cache, artifact, expected_size, offline):
    # Digest names isolate identical provider filenames published in different generations.
    destination = cache / "archives" / artifact["sha256"] / artifact["file"]
    require(not destination.parent.is_symlink(), "Archive cache directory must not be a symlink")
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() or destination.is_symlink():
        require(matches(destination, artifact["sha256"]), "Cached archive checksum mismatch: " + str(destination))
        if expected_size is not None:
            require(destination.stat().st_size == expected_size, "Cached archive size mismatch")
        return destination

    # Reuse the provider refresh cache without changing or trusting its directory name.
    for candidate in sorted(cache.glob("*/*/*/" + artifact["file"])):
        if matches(candidate, artifact["sha256"]):
            if expected_size is not None:
                require(candidate.stat().st_size == expected_size, "Provider archive size mismatch")
            return candidate

    require(not offline, "Pinned archive is not cached; rerun without --offline: " + artifact["file"])
    print("Preparing bundled PHP: downloading pinned " + artifact["file"], flush=True)
    opener = urllib.request.build_opener(HTTPSRedirectsOnly())
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=destination.parent, prefix=".download-", delete=False) as target:
            temporary = Path(target.name)
            with opener.open(artifact["url"], timeout=120) as source:
                require(urllib.parse.urlsplit(source.url).scheme == "https", "Archive download must use HTTPS")
                shutil.copyfileobj(source, target, length=1024 * 1024)
        require(matches(temporary, artifact["sha256"]), "Downloaded archive checksum mismatch")
        if expected_size is not None:
            require(temporary.stat().st_size == expected_size, "Downloaded archive size mismatch")
        os.replace(temporary, destination)
        return destination
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def extract_binary(archive, expected_name, destination, expected_digest):
    with tarfile.open(archive, "r:gz") as bundle:
        members = bundle.getmembers()
        selected = []
        for member in members:
            path = PurePosixPath(member.name)
            require(not path.is_absolute() and ".." not in path.parts and "\\" not in member.name,
                    "Unsafe archive entry: " + member.name)
            require(member.isfile() or member.isdir(), "Archive links and special files are not permitted")
            if member.isfile():
                require(path == PurePosixPath(expected_name), "Unexpected archive file: " + member.name)
                require(0 < member.size <= 512 * 1024 * 1024, "Bundled binary size exceeds preparation limit")
                selected.append(member)
        require(len(selected) == 1, "Archive must contain exactly one " + expected_name)
        # Only stream the validated member; never ask tarfile to create paths or links.
        with contextlib.closing(bundle.extractfile(selected[0])) as source, destination.open("xb") as target:
            shutil.copyfileobj(source, target, length=1024 * 1024)
    require(matches(destination, expected_digest), "Extracted binary checksum mismatch: " + expected_name)
    destination.chmod(0o755)


def matches_local_source(source, descriptor):
    present = source.exists() or source.is_symlink()
    if not present:
        return False
    if source.is_symlink() or not source.is_dir():
        print("Ignoring invalid local PHP source: " + str(source), file=sys.stderr)
        return False
    for kind in KINDS:
        binary = descriptor["binaries"][kind]
        path = source / binary["file"]
        if not matches(path, binary["sha256"]) or stat.S_IMODE(path.stat().st_mode) & 0o111 == 0:
            print("Ignoring local PHP source that does not match both pinned binaries: " + str(source), file=sys.stderr)
            return False
    return True


def copy_local_binaries(source, stage, descriptor):
    for kind in KINDS:
        binary = descriptor["binaries"][kind]
        original = source / binary["file"]
        destination = stage / binary["file"]
        shutil.copy2(original, destination)
        require(stat.S_IMODE(destination.stat().st_mode) == stat.S_IMODE(original.stat().st_mode),
                "Could not preserve local binary permissions: " + binary["file"])
        require(matches(destination, binary["sha256"]), "Local binary checksum mismatch after copy: " + binary["file"])


def prepare(resources, cache, offline, local_sources=None):
    require(resources.is_dir() and not resources.is_symlink(), "Bundled resource directory is missing or a symlink")
    descriptor = load_descriptor(resources)
    cache.mkdir(parents=True, exist_ok=True)
    lock_path = cache / ".prepare-bundled-php.lock"
    require(not lock_path.is_symlink(), "Preparation lock must not be a symlink")
    with lock_path.open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if all(matches(resources / descriptor["binaries"][kind]["file"], descriptor["binaries"][kind]["sha256"])
               and os.access(resources / descriptor["binaries"][kind]["file"], os.X_OK) for kind in KINDS):
            print("Bundled PHP " + descriptor["phpVersion"] + " already verified")
            return
        sources = [INSTALLED_APP_RESOURCES] if local_sources is None else list(local_sources)
        source = next((candidate for candidate in sources if matches_local_source(candidate, descriptor)), None)
        with tempfile.TemporaryDirectory(dir=resources, prefix=".prepare-") as temporary:
            stage = Path(temporary)
            if source is not None:
                copy_local_binaries(source, stage, descriptor)
            else:
                for kind in KINDS:
                    binary = descriptor["binaries"][kind]
                    artifact = descriptor["manifest"]["artifacts"][kind]
                    size = descriptor["manifest"].get("verifiedArtifactSizes", {}).get(kind)
                    archive = verified_archive(cache, artifact, size, offline)
                    extract_binary(archive, binary["file"], stage / binary["file"], binary["sha256"])
            # Validate the complete pair before publishing either resource. Each
            # rename is atomic, and interrupted preparation is rechecked next run.
            for kind in KINDS:
                name = descriptor["binaries"][kind]["file"]
                require(matches(stage / name, descriptor["binaries"][kind]["sha256"]),
                        "Staged binary checksum mismatch: " + name)
                require(not (resources / name).is_symlink(), "Generated binary must not be a symlink")
                require(not (resources / name).exists() or (resources / name).is_file(),
                        "Generated binary destination is not a regular file: " + str(resources / name))
            for kind in KINDS:
                name = descriptor["binaries"][kind]["file"]
                os.replace(stage / name, resources / name)
        source_description = "matching local binaries from " + str(source) if source is not None else "pinned archives"
        print("Prepared bundled PHP " + descriptor["phpVersion"] + " from " + source_description)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--offline", action="store_true", help="use only verified resources or cached pinned archives")
    parser.add_argument("--resources", type=Path, default=ROOT / RESOURCE_PATH, help="resource directory (isolated fixture override)")
    parser.add_argument("--cache", type=Path, default=ROOT / ".build/php-provider", help="archive cache directory")
    parser.add_argument("--local-source", type=Path, action="append",
                        help="read-only directory containing both pinned php and php-fpm binaries; may be repeated")
    args = parser.parse_args()
    try:
        prepare(args.resources, args.cache, args.offline, args.local_source)
    except (PreparationError, OSError, ValueError, KeyError, tarfile.TarError) as error:
        print("prepare-bundled-php: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

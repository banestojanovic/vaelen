#!/usr/bin/python3
"""Build and verify Vaelen's closed PostgreSQL and Valkey runtime packages."""
from __future__ import annotations

import argparse
import ctypes
import dataclasses
import gzip
import hashlib
import io
import json
import os
import pathlib
import platform
import re
import shutil
import socket
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
from typing import Optional

ROOT = pathlib.Path(__file__).resolve().parents[1]
LOCK = ROOT / "Scripts/service-package-lock.json"
LOCK_DATA = json.loads(LOCK.read_text())


@dataclasses.dataclass(frozen=True)
class SourcePin:
    name: str
    version: str
    archive: str
    url: str
    sha256: str
    release_commit: Optional[str] = None


PINS = {name: SourcePin(name, row["version"], row["archive"], row["url"], row["sha256"], row.get("release_commit")) for name, row in LOCK_DATA["sources"].items()}
POSTGRES_BINARIES = frozenset({"postgres", "initdb", "psql", "pg_dump", "pg_dumpall", "pg_restore", "createdb", "createuser", "dropdb", "dropuser", "vacuumdb", "clusterdb", "reindexdb", "pg_isready", "pg_basebackup", "pg_receivewal", "pg_recvlogical", "pg_resetwal", "pg_verifybackup", "pg_waldump"})


def digest(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def canonical(value) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()


def safe_name(name: str) -> pathlib.PurePosixPath:
    if "\0" in name:
        raise ValueError("NUL in archive path")
    path = pathlib.PurePosixPath(name)
    if path.is_absolute() or not path.parts or any(part in ("", ".", "..") for part in path.parts):
        raise ValueError(f"unsafe archive path: {name!r}")
    return path


def extract_archive(archive: pathlib.Path, destination: pathlib.Path) -> None:
    destination.mkdir(parents=True, exist_ok=False)
    with tarfile.open(archive, "r:*") as tar:
        members = tar.getmembers()
        seen = set()
        validated = []
        for member in members:
            rel = safe_name(member.name)
            key = rel.as_posix().rstrip("/")
            if key in seen:
                raise ValueError(f"duplicate archive path: {key}")
            seen.add(key)
            if not (member.isfile() or member.isdir() or member.issym()):
                raise ValueError(f"unsupported archive entry: {key}")
            if member.issym():
                link = pathlib.PurePosixPath(member.linkname)
                if link.is_absolute() or "\0" in member.linkname:
                    raise ValueError(f"unsafe symlink: {key}")
                resolved = pathlib.PurePosixPath(os.path.normpath(str(rel.parent / link)))
                if resolved.is_absolute() or ".." in resolved.parts:
                    raise ValueError(f"escaping symlink: {key}")
            validated.append((member, rel))
        symlinks = {rel.as_posix() for member, rel in validated if member.issym()}
        for _, rel in validated:
            if any(parent.as_posix() in symlinks for parent in rel.parents):
                raise ValueError(f"archive path traverses symlink: {rel}")
        for member, rel in validated:
            target = destination.joinpath(*rel.parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            if member.isdir():
                target.mkdir(exist_ok=True)
                os.chmod(target, member.mode & 0o777)
            elif member.issym():
                target.symlink_to(member.linkname)
            else:
                source = tar.extractfile(member)
                if source is None:
                    raise ValueError(f"missing data: {rel}")
                with target.open("xb") as output:
                    shutil.copyfileobj(source, output)
                os.chmod(target, member.mode & 0o777)


def acquire_source(pin: SourcePin, cache: pathlib.Path, offline: bool = False) -> pathlib.Path:
    cache.mkdir(parents=True, exist_ok=True)
    destination = cache / pin.sha256
    if destination.exists():
        if digest(destination) != pin.sha256:
            raise ValueError(f"source cache digest mismatch for {pin.name}")
        return destination
    if offline:
        raise ValueError(f"offline source cache miss for {pin.name}")
    fd, temp_name = tempfile.mkstemp(prefix="source-", dir=cache)
    os.close(fd)
    temporary = pathlib.Path(temp_name)
    try:
        request = urllib.request.Request(pin.url, headers={"User-Agent": "Vaelen-service-package-builder/1"})
        with urllib.request.urlopen(request, timeout=60) as response, temporary.open("wb") as output:
            if not response.geturl().startswith("https://"):
                raise ValueError(f"source redirect left HTTPS for {pin.name}")
            shutil.copyfileobj(response, output)
        if digest(temporary) != pin.sha256:
            raise ValueError(f"download digest mismatch for {pin.name}")
        try:
            os.link(temporary, destination)
        except FileExistsError:
            if digest(destination) != pin.sha256:
                raise ValueError(f"racing cache entry is corrupt for {pin.name}")
        return destination
    finally:
        temporary.unlink(missing_ok=True)


def inventory_tree(root: pathlib.Path) -> list[dict]:
    rows = []
    for path in sorted(root.rglob("*"), key=lambda p: p.relative_to(root).as_posix().encode()):
        rel = path.relative_to(root).as_posix()
        safe_name(rel)
        mode = path.lstat().st_mode
        if path.is_symlink():
            target = os.readlink(path)
            if pathlib.PurePosixPath(target).is_absolute() or ".." in pathlib.PurePosixPath(os.path.normpath(str(pathlib.PurePosixPath(rel).parent / target))).parts:
                raise ValueError(f"escaping package symlink: {rel}")
            rows.append({"path": rel, "type": "symlink", "mode": mode & 0o777, "target": target})
        elif path.is_dir():
            rows.append({"path": rel, "type": "directory", "mode": mode & 0o777})
        elif path.is_file():
            rows.append({"path": rel, "type": "file", "mode": mode & 0o777, "sha256": digest(path)})
        else:
            raise ValueError(f"unsupported payload file: {rel}")
    return rows


def write_archive(root: pathlib.Path, output: pathlib.Path, archive_root: str, epoch: int) -> None:
    temp = output.with_suffix(output.suffix + ".tmp")
    with temp.open("wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0, compresslevel=9) as zipped:
        with tarfile.open(fileobj=zipped, mode="w|", format=tarfile.PAX_FORMAT) as tar:
            tar.dereference = False
            for path in [root] + sorted(root.rglob("*"), key=lambda p: p.relative_to(root).as_posix().encode()):
                rel = pathlib.PurePosixPath(archive_root) if path == root else pathlib.PurePosixPath(archive_root) / path.relative_to(root).as_posix()
                info = tarfile.TarInfo(rel.as_posix())
                st = path.lstat()
                info.uid = info.gid = 0
                info.uname = info.gname = ""
                info.mtime = epoch
                info.mode = st.st_mode & 0o777
                info.pax_headers = {}
                if path.is_symlink():
                    info.type, info.linkname = tarfile.SYMTYPE, os.readlink(path)
                    tar.addfile(info)
                elif path.is_dir():
                    info.type = tarfile.DIRTYPE
                    tar.addfile(info)
                else:
                    info.size = st.st_size
                    with path.open("rb") as source:
                        tar.addfile(info, source)
    os.replace(temp, output)


def package_record(package_id: str, archive: pathlib.Path, payload: pathlib.Path, metadata: dict) -> dict:
    files = inventory_tree(payload)
    return {"id": package_id, "archive": archive.name, "archive_sha256": digest(archive), "archive_size": archive.stat().st_size,
            "payload_sha256": hashlib.sha256(canonical(files)).hexdigest(), "files": files, **metadata}


def make_manifest(packages: list[dict]) -> dict:
    return {"schema_version": 1, "platform": "macos", "architecture": "arm64", "minimum_macos": "14.0", "packages": packages,
            "same_host_repeatability": {"postgresql": "open", "valkey": "verified"},
            "release_gates": {"license_review": "open", "upstream_authenticity_review": "open", "signing_notarization": "open", "macos_14_execution": "open"}}


def verify_directory(directory: pathlib.Path) -> None:
    manifest_path = directory / "manifest.json"
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise ValueError("manifest must be a regular file")
    manifest = json.loads(manifest_path.read_text(), object_pairs_hook=_unique_object)
    package_rows = manifest.get("packages", [])
    package_ids = [p.get("id") for p in package_rows]
    if manifest.get("schema_version") != 1 or len(package_rows) != 2 or set(package_ids) != {"postgresql-18.6", "valkey-9.1.2"} or len(set(package_ids)) != len(package_ids):
        raise ValueError("unsupported or incomplete package manifest")
    with tempfile.TemporaryDirectory(prefix="vaelen-package-verify-") as temp:
        for package in manifest["packages"]:
            archive = directory / package["archive"]
            if archive.parent != directory or archive.is_symlink() or not archive.is_file() or digest(archive) != package["archive_sha256"] or archive.stat().st_size != package["archive_size"]:
                raise ValueError(f"archive digest or size mismatch: {package['archive']}")
            extracted_root = pathlib.Path(temp) / package["id"]
            extract_archive(archive, extracted_root)
            roots = list(extracted_root.iterdir())
            if len(roots) != 1 or roots[0].name != package["id"] or roots[0].is_symlink() or not roots[0].is_dir():
                raise ValueError(f"archive contains member outside expected package root: {package['id']}")
            extracted = extracted_root / package["id"]
            files = inventory_tree(extracted)
            if files != package["files"] or hashlib.sha256(canonical(files)).hexdigest() != package["payload_sha256"]:
                raise ValueError(f"payload inventory mismatch: {package['id']}")
            audit_macho(extracted, [])
            runtime_env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": temp, "LC_ALL": "C", "TZ": "UTC"}
            smoke_package(extracted, package["id"], pathlib.Path(temp) / (package["id"] + " smoke with spaces"), runtime_env, pathlib.Path(temp) / "verify.log")


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def run(args, cwd, env, log):
    with log.open("ab") as output:
        result = subprocess.run(args, cwd=cwd, env=env, stdout=output, stderr=subprocess.STDOUT, timeout=3600)
    if result.returncode:
        fd, retained_name = tempfile.mkstemp(prefix="vaelen-service-package-build-failure-", suffix=".log", dir="/private/tmp")
        os.close(fd)
        retained = pathlib.Path(retained_name)
        shutil.copyfile(log, retained)
        tail = "\n".join(log.read_text(errors="replace").splitlines()[-40:])
        raise RuntimeError(f"command failed ({result.returncode}) {args[0]}; full log {retained}\n{tail}")


def run_output(args, cwd, env, log) -> str:
    with log.open("ab") as output:
        result = subprocess.run(args, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30, text=True)
        output.write(result.stdout.encode())
    if result.returncode:
        raise RuntimeError(f"command failed ({result.returncode}) {args[0]}: {result.stdout.strip()}")
    return result.stdout.strip()


def reserve_loopback_port() -> str:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return str(listener.getsockname()[1])


def wait_for_owned_listener(process: subprocess.Popen, port: str, timeout: float = 15, log: Optional[pathlib.Path] = None) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            detail = log.read_text(errors="replace")[-1200:] if log and log.exists() else ""
            raise RuntimeError(f"owned service process exited with {process.returncode}: {detail}")
        result = subprocess.run(["/usr/sbin/lsof", "-nP", "-a", "-p", str(process.pid), "-iTCP:" + port, "-sTCP:LISTEN", "-Fn"], capture_output=True, text=True)
        if result.returncode == 0 and any(line.startswith("p" + str(process.pid)) for line in result.stdout.splitlines()):
            return
        time.sleep(0.1)
    raise TimeoutError(f"service process {process.pid} did not own loopback port {port}")


def stop_owned_process(process: subprocess.Popen) -> None:
    if process.poll() is None:
        process.terminate()
    try:
        process.wait(timeout=12)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def smoke_package(package: pathlib.Path, package_id: str, scratch: pathlib.Path, env: dict, log: pathlib.Path) -> None:
    scratch.mkdir(parents=True, exist_ok=True)
    if package_id.startswith("postgres"):
        data = scratch / "data with spaces"
        unix_socket = pathlib.Path(tempfile.mkdtemp(prefix="vaelen socket ", dir="/private/tmp"))
        try:
            run([str(package / "bin/initdb"), "-D", str(data), "--encoding=UTF8", "--locale-provider=icu", "--icu-locale=en"], scratch, env, log)
            port = reserve_loopback_port()
            server_log = scratch / "postgres.log"
            server = subprocess.Popen([str(package / "bin/postgres"), "-D", str(data), "-k", str(unix_socket), "-p", port, "-h", "127.0.0.1"], cwd=scratch, env=env, stdout=server_log.open("wb"), stderr=subprocess.STDOUT)
            try:
                wait_for_owned_listener(server, port, log=server_log)
                # Confirm the listener serves this fresh cluster before running any mutating smoke SQL.
                data_dir = run_output([str(package / "bin/psql"), "-h", "127.0.0.1", "-p", port, "-d", "postgres", "-At", "-c", "SHOW data_directory"], scratch, env, log)
                if pathlib.Path(data_dir).resolve() != data.resolve():
                    raise RuntimeError(f"PostgreSQL listener reported foreign data directory {data_dir}")
                result = run_output([str(package / "bin/psql"), "-h", str(unix_socket), "-p", port, "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-At", "-c", "CREATE COLLATION smoke_en (provider = icu, locale = 'en'); SELECT string_agg(x, ',' ORDER BY x COLLATE smoke_en) FROM (VALUES ('z'), ('ä'), ('a')) t(x); CREATE EXTENSION IF NOT EXISTS plpgsql; DO $$ BEGIN NULL; END $$; SELECT current_setting('server_version_num');"], scratch, env, log)
                if "a,ä,z" not in result or "180006" not in result:
                    raise ValueError("PostgreSQL ICU ordering, PL/pgSQL, or version smoke returned unexpected values")
                tcp_result = run_output([str(package / "bin/psql"), "-h", "127.0.0.1", "-p", port, "-d", "postgres", "-At", "-c", "SELECT 1"], scratch, env, log)
                if tcp_result != "1":
                    raise ValueError("PostgreSQL loopback TCP smoke did not return 1")
            finally:
                stop_owned_process(server)
        finally:
            shutil.rmtree(unix_socket)
    else:
        port = reserve_loopback_port()
        server_log = scratch / "valkey.log"
        server = subprocess.Popen([str(package / "bin/valkey-server"), "--port", port, "--bind", "127.0.0.1", "--save", "", "--appendonly", "no", "--daemonize", "no"], cwd=scratch, env=env, stdout=server_log.open("wb"), stderr=subprocess.STDOUT)
        try:
            wait_for_owned_listener(server, port, log=server_log)
            client = package / "bin/valkey-cli"
            info = run_output([str(client), "-h", "127.0.0.1", "-p", port, "--raw", "INFO", "server"], scratch, env, log)
            match = re.search(r"(?m)^process_id:(\d+)$", info)
            if match is None or int(match.group(1)) != server.pid:
                raise RuntimeError("Valkey listener process_id does not match the launched server")
            if run_output([str(client), "-h", "127.0.0.1", "-p", port, "PING"], scratch, env, log) != "PONG": raise ValueError("Valkey PING failed")
            if run_output([str(client), "-h", "127.0.0.1", "-p", port, "SET", "vaelen", "persisted"], scratch, env, log) != "OK": raise ValueError("Valkey SET failed")
            if run_output([str(client), "-h", "127.0.0.1", "-p", port, "GET", "vaelen"], scratch, env, log) != "persisted": raise ValueError("Valkey GET failed")
        finally:
            stop_owned_process(server)


def clean_environment(sdk: str, build_root: pathlib.Path) -> dict:
    resolved_root = build_root.resolve()
    file_prefix_map = f"-ffile-prefix-map={build_root}=/vaelen-build -ffile-prefix-map={resolved_root}=/vaelen-build"
    oso_prefix = resolved_root
    env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": os.environ.get("HOME", "/tmp"), "SDKROOT": sdk,
           "MACOSX_DEPLOYMENT_TARGET": "14.0", "SOURCE_DATE_EPOCH": str(LOCK_DATA["source_date_epoch"]), "ZERO_AR_DATE": "1", "LC_ALL": "C", "TZ": "UTC", "COPYFILE_DISABLE": "1"}
    env["CC"] = "/usr/bin/clang"
    env["CXX"] = "/usr/bin/clang++"
    env["CFLAGS"] = "-arch arm64 -mmacosx-version-min=14.0 " + file_prefix_map
    env["CXXFLAGS"] = env["CFLAGS"]
    env["LDFLAGS"] = f"-arch arm64 -mmacosx-version-min=14.0 -Wl,-headerpad_max_install_names -Wl,-oso_prefix,{oso_prefix}"
    return env


def normalize_build_paths(value: str, build_root: pathlib.Path) -> str:
    resolved_root = str(build_root.resolve())
    lexical_root = str(build_root)
    if resolved_root != lexical_root:
        value = value.replace(resolved_root, "$BUILD_ROOT_REAL")
    return value.replace(lexical_root, "$BUILD_ROOT")


def find_macho_paths(root: pathlib.Path) -> list[pathlib.Path]:
    found = []
    for path in root.rglob("*"):
        if path.is_file() and not path.is_symlink():
            result = subprocess.run(["/usr/bin/file", "-b", str(path)], capture_output=True, text=True)
            if "Mach-O" in result.stdout:
                found.append(path)
    return found


def audit_macho(root: pathlib.Path, forbidden: list[str]) -> None:
    for image in find_macho_paths(root):
        info = subprocess.check_output(["/usr/bin/lipo", "-archs", str(image)], text=True).strip()
        if info != "arm64":
            raise ValueError(f"wrong architecture {info}: {image}")
        deps = subprocess.check_output(["/usr/bin/otool", "-L", str(image)], text=True)
        rpaths = subprocess.check_output(["/usr/bin/otool", "-l", str(image)], text=True)
        load_lines = rpaths.splitlines()
        for index, line in enumerate(load_lines):
            version = None
            if "minos " in line:
                version = line.split("minos ", 1)[1].split()[0]
            elif line.strip() == "cmd LC_VERSION_MIN_MACOSX":
                version = load_lines[index + 2].strip().split()[1]
            if version:
                parts = tuple(int(part) for part in version.split(".")[:2])
                if parts > (14, 0):
                    raise ValueError(f"minimum macOS {version} exceeds 14.0: {image}")
        rpath_values = []
        for index, load_line in enumerate(load_lines):
            if load_line.strip() == "cmd LC_RPATH":
                rpath_values.append(load_lines[index + 2].strip().removeprefix("path ").split(" (offset", 1)[0])
        combined = "\n".join(deps.splitlines()[1:] + rpath_values)
        for bad in forbidden + ["/opt/homebrew", "/usr/local/Cellar", "/opt/local"]:
            if bad in combined:
                evidence = next((line.strip() for line in combined.splitlines() if bad in line), "load-command text")
                raise ValueError(f"forbidden dependency or rpath {bad}: {image}: {evidence}")
        for line in deps.splitlines()[1:]:
            dep = line.strip().split(" (compatibility", 1)[0]
            if dep.startswith("@rpath/") and not (root / "lib" / dep.removeprefix("@rpath/")).exists():
                raise ValueError(f"unresolved @rpath dependency {dep}: {image}")
            if dep.startswith("/") and not (dep.startswith("/usr/lib/") or dep.startswith("/System/Library/")):
                raise ValueError(f"unapproved absolute dependency {dep}: {image}")
        lines = rpaths.splitlines()
        for index, line in enumerate(lines):
            if line.strip() == "cmd LC_RPATH":
                value = lines[index + 2].strip().removeprefix("path ").split(" (offset", 1)[0]
                if not value.startswith("@loader_path"):
                    raise ValueError(f"non-relocatable LC_RPATH {value}: {image}")
        if image.suffix == ".dylib":
            identity = subprocess.check_output(["/usr/bin/otool", "-D", str(image)], text=True).splitlines()[1:]
            if identity and not identity[0].strip().startswith("@rpath/"):
                raise ValueError(f"non-relocatable install ID {identity[0].strip()}: {image}")


def relocate_macho(root: pathlib.Path) -> None:
    images = find_macho_paths(root)
    library_map = {}
    for image in images:
        if "/lib/" in str(image) and image.suffix == ".dylib":
            library_map[image.name] = "@rpath/" + image.relative_to(root / "lib").as_posix()
    for link in (root / "lib").rglob("*.dylib"):
        if link.is_symlink():
            library_map[link.name] = "@rpath/" + link.relative_to(root / "lib").as_posix()
    for image in images:
        deps = subprocess.check_output(["/usr/bin/otool", "-L", str(image)], text=True)
        for line in deps.splitlines()[1:]:
            dep = line.strip().split(" (compatibility", 1)[0]
            basename = pathlib.Path(dep).name
            if basename in library_map and dep != library_map[basename]:
                subprocess.run(["/usr/bin/install_name_tool", "-change", dep, library_map[basename], str(image)], check=True)
        if image in [p for p in images if p.suffix == ".dylib"]:
            own = library_map.get(image.name)
            if own:
                subprocess.run(["/usr/bin/install_name_tool", "-id", own, str(image)], check=True)
        rel = image.parent.relative_to(root)
        librel = os.path.relpath(root / "lib", image.parent)
        rpath = "@loader_path" if librel == "." else "@loader_path/" + librel
        cmds = subprocess.check_output(["/usr/bin/otool", "-l", str(image)], text=True)
        lines = cmds.splitlines()
        existing = []
        for index, line in enumerate(lines):
            if line.strip() == "cmd LC_RPATH":
                value = lines[index + 2].strip().removeprefix("path ").split(" (offset", 1)[0]
                existing.append(value)
        for old in existing:
            subprocess.run(["/usr/bin/install_name_tool", "-delete_rpath", old, str(image)], check=True)
        subprocess.run(["/usr/bin/install_name_tool", "-add_rpath", rpath, str(image)], check=True)
    for image in images:
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(image)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def copy_selected(source: pathlib.Path, target: pathlib.Path, include: list[str], exclude: set[str] = frozenset()) -> None:
    target.mkdir(parents=True, exist_ok=True)
    for name in include:
        src = source / name
        if not src.exists():
            raise ValueError(f"required package input missing: {src}")
        if src.is_dir() and not src.is_symlink():
            shutil.copytree(src, target / name, symlinks=True, ignore=shutil.ignore_patterns(*exclude), dirs_exist_ok=True)
        else:
            (target / name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, target / name, follow_symlinks=False)
    for path in target.rglob("*.a"):
        path.unlink()


def notice(source: pathlib.Path, root: pathlib.Path, component: str, filename: str, dest_name: str | None = None) -> dict:
    path = source / filename
    if not path.is_file():
        raise ValueError(f"required notice missing: {path}")
    relative = pathlib.Path("notices") / component / (dest_name or path.name)
    out = root / relative
    out.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(path, out)
    return {"component": component, "source_path": filename, "package_path": relative.as_posix(), "sha256": digest(out)}


def build(args) -> None:
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise RuntimeError("package builds require native Apple Silicon macOS")
    output = args.output.resolve()
    cache = args.source_cache.resolve()
    if output.exists():
        raise ValueError(f"output must not exist: {output}")
    if output == cache or output in cache.parents or cache in output.parents:
        raise ValueError("source cache and output must not overlap")
    with tempfile.TemporaryDirectory(prefix="vaelen-service-build-") as temporary:
        work = pathlib.Path(temporary)
        build_root = work
        env = clean_environment(subprocess.check_output(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip(), build_root)
        sdk_version = subprocess.check_output(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True).strip()
        source_roots = {}
        for name, pin in PINS.items():
            archive = acquire_source(pin, cache, args.offline)
            extracted = work / "sources" / name
            extract_archive(archive, extracted)
            roots = [p for p in extracted.iterdir()]
            if len(roots) != 1 or not roots[0].is_dir():
                raise ValueError(f"source archive has unexpected root: {name}")
            source_roots[name] = roots[0]
        pg_src, icu_src, vk_src = source_roots["postgresql"], source_roots["icu"], source_roots["valkey"]
        icu_build, icu_install = work / "icu-build", work / "icu-install"
        icu_build.mkdir()
        run([str(icu_src / "source/runConfigureICU"), "MacOSX", "--prefix=" + str(icu_install), "--disable-samples", "--disable-tests", "--enable-static", "--disable-shared", "--with-data-packaging=static"], icu_src, env, work / "build.log")
        run(["/usr/bin/make", "-j4"], icu_src, env, work / "build.log")
        run(["/usr/bin/make", "install"], icu_src, env, work / "build.log")
        pg_build, pg_dest = work / "pg-build", work / "pg-dest"
        pg_prefix = "/vaelen-build/pg-install"
        pg_build.mkdir()
        pg_env = dict(env)
        pg_env["CPPFLAGS"] = env["CFLAGS"] + " -I" + str(icu_install / "include")
        pg_env["LDFLAGS"] = env["LDFLAGS"] + " -L" + str(icu_install / "lib") + " -lc++"
        pg_env["ICU_CFLAGS"] = "-I" + str(icu_install / "include")
        pg_env["ICU_LIBS"] = "-L" + str(icu_install / "lib") + " -licui18n -licuuc -licudata -lc++"
        run([str(pg_src / "configure"), "--prefix=" + pg_prefix, "--with-icu", "--without-readline", "--without-ldap", "--without-pam", "--without-gssapi", "--without-krb5", "--without-libxml", "--without-libxslt", "--disable-rpath", "--disable-debug"], pg_build, pg_env, work / "build.log")
        run(["/usr/bin/make", "-j4"], pg_build, pg_env, work / "build.log")
        run(["/usr/bin/make", "install", "DESTDIR=" + str(pg_dest)], pg_build, pg_env, work / "build.log")
        pg_install = pg_dest / pg_prefix.lstrip("/")
        vk_build = vk_src
        run(["/usr/bin/make", "-j4", "MALLOC=libc", "BUILD_TLS=no", "DEBUG="], vk_build, env, work / "build.log")
        packages = []
        for package_id, source, install, paths, notices in [
            ("postgresql-18.6", pg_src, pg_install, ["bin", "lib", "share"], [("postgresql", pg_src, "COPYRIGHT"), ("icu", icu_src, "LICENSE")]),
            ("valkey-9.1.2", vk_src, vk_src, [], [("valkey", vk_src, "COPYING"), ("libvalkey", vk_src, "deps/libvalkey/COPYING"), ("linenoise", vk_src, "deps/linenoise/linenoise.c"), ("lua", vk_src, "deps/lua/COPYRIGHT"), ("fast_float", vk_src, "deps/fast_float/ffc.h"), ("fpconv", vk_src, "deps/fpconv/LICENSE.txt"), ("hdr_histogram", vk_src, "deps/hdr_histogram/COPYING.txt"), ("hdr_histogram", vk_src, "deps/hdr_histogram/LICENSE.txt")])]:
            payload = work / "payload" / package_id
            if package_id.startswith("postgres"):
                (payload / "bin").mkdir(parents=True)
                for path in (install / "bin").iterdir():
                    if path.name not in POSTGRES_BINARIES:
                        continue
                    shutil.copy2(path, payload / "bin" / path.name, follow_symlinks=False)
                copy_selected(install, payload, ["lib", "share"], {"pkgconfig", "pgxs"})
            else:
                for name in ("valkey-server", "valkey-cli", "valkey-check-aof", "valkey-check-rdb"):
                    (payload / "bin").mkdir(parents=True, exist_ok=True)
                    shutil.copy2(vk_build / "src" / name, payload / "bin" / name)
                # Valkey server's Lua sources are embedded; no external runtime data is needed.
            notice_records = [notice(notice_source, payload, component, path) for component, notice_source, path in notices]
            relocate_macho(payload)
            audit_macho(payload, [str(work)])
            archive_name = package_id + "-macos14-arm64.tar.gz"
            archive_path = work / archive_name
            write_archive(payload, archive_path, package_id, LOCK_DATA["source_date_epoch"])
            with tempfile.TemporaryDirectory(prefix="vaelen relocated package ") as relocate_tmp:
                extracted_root = pathlib.Path(relocate_tmp) / "extracted"
                extract_archive(archive_path, extracted_root)
                extracted = extracted_root / package_id
                audit_macho(extracted, [str(work)])
                smoke_package(extracted, package_id, pathlib.Path(relocate_tmp), env, work / "smoke.log")
            sources = [{"name": n, "version": PINS[n].version, "url": PINS[n].url, "sha256": PINS[n].sha256} for n in (("postgresql", "icu") if package_id.startswith("postgres") else ("valkey",))]
            metadata = {"version": "18.6" if package_id.startswith("postgres") else "9.1.2", "sources": sources,
                        "build": {"toolchain": {"sdk_version": sdk_version, "python": platform.python_version(), "clang": subprocess.check_output(["/usr/bin/clang", "--version"], text=True).splitlines()[0], "xcode": subprocess.check_output(["/usr/bin/xcodebuild", "-version"], text=True).replace("\n", "; ")}, "environment": {"MACOSX_DEPLOYMENT_TARGET": "14.0", "CFLAGS": normalize_build_paths(env["CFLAGS"], build_root), "LDFLAGS": normalize_build_paths(env["LDFLAGS"], build_root), "PATH": env["PATH"], "SOURCE_DATE_EPOCH": env["SOURCE_DATE_EPOCH"], "ZERO_AR_DATE": env["ZERO_AR_DATE"]}, "options": LOCK_DATA["recipes"]["postgresql" if package_id.startswith("postgres") else "valkey"], "recipe_sha256": digest(LOCK), "driver_sha256": digest(pathlib.Path(__file__))}, "notices": notice_records}
            packages.append(package_record(package_id, archive_path, payload, metadata))
        output.parent.mkdir(parents=True, exist_ok=True)
        stage = pathlib.Path(tempfile.mkdtemp(prefix="." + output.name + ".", dir=output.parent))
        try:
            for package in packages:
                shutil.copyfile(work / package["archive"], stage / package["archive"])
            manifest = make_manifest(packages)
            (stage / "manifest.json").write_bytes(canonical(manifest) + b"\n")
            verify_directory(stage)
            if sys.platform == "darwin":
                renamex = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True).renamex_np
                renamex.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
                renamex.restype = ctypes.c_int
                if renamex(os.fsencode(stage), os.fsencode(output), 0x00000004) != 0:
                    error = ctypes.get_errno()
                    raise OSError(error, os.strerror(error), str(output))
            else:
                os.rename(stage, output)
        except BaseException:
            shutil.rmtree(stage, ignore_errors=True)
            raise


def main(argv=None) -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    b = sub.add_parser("build")
    b.add_argument("--source-cache", type=pathlib.Path, default=pathlib.Path.home() / "Library/Caches/Vaelen/service-sources")
    b.add_argument("--output", type=pathlib.Path, required=True)
    b.add_argument("--offline", action="store_true")
    v = sub.add_parser("verify")
    v.add_argument("--packages", type=pathlib.Path, required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "build":
            build(args)
        else:
            verify_directory(args.packages.resolve())
        return 0
    except Exception as error:
        print(f"service package {args.command} failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

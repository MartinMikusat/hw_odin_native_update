#!/usr/bin/env python3
"""Build, sign, notarize and publish a macOS app as a GitHub release the app updates from.

A project's scripts/release_macos.py calls configure() and main(). The update feed is
update.json attached to each release and fetched from releases/latest/download, so
publishing a release is the single commit point. No third-party Python packages."""
import argparse
import hashlib
import json
import os
import plistlib
import platform
import re
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

MAX_ARCHIVE_BYTES = 256 * 1024 * 1024
MAX_ENTRIES = 4096
FEED = "update.json"
SETTINGS = {}


# Release output goes in a .noindex folder so Spotlight and LaunchServices never register the
# built copies under the installed app's bundle ID (which makes the Dock lose its icon).
DIST = "dist.noindex"


def configure(root, app_name, bundle_id, team_id, repo, built_app, artifact_prefix, identity=None, executable=False):
    """app_name is the .app basename without the suffix; built_app is the path of the
    release bundle the project's build.sh release produces, relative to root.
    executable=True ships a bare command-line binary named app_name instead: build.sh
    release must embed an Info.plist carrying HW_UPDATE_VERSION (linker -sectcreate
    __TEXT __info_plist), because the binary has no bundle to stamp. Bare binaries
    are notarized but cannot be stapled."""
    # The updater accepts only what Apple allows in a bundle ID (letters, digits, '.', '-');
    # anything else would publish releases no installed copy can ever verify.
    if not re.fullmatch(r"[A-Za-z0-9.-]{1,160}", bundle_id) or ".." in bundle_id:
        raise ValueError(f"Invalid bundle ID {bundle_id!r}: use letters, digits, '.' and '-'")
    SETTINGS.update(root=Path(root), app=app_name if executable else f"{app_name}.app", executable=executable,
                    bundle_id=bundle_id, team=team_id, repo=repo,
                    built=Path(root) / built_app, prefix=artifact_prefix,
                    identity=identity or f"Developer ID Application: Martin Mikusat ({team_id})")


def run(*args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, timeout=1800, **kwargs)


def output(*args):
    return run(*args, capture_output=True, text=True).stdout.strip()


def version(value):
    if not re.fullmatch(r"(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})", value):
        raise ValueError("Version must be major.minor.patch (at most nine digits each)")
    return tuple(map(int, value.split(".")))


def feed_url():
    return f"https://github.com/{SETTINGS['repo']}/releases/latest/download/{FEED}"


def descriptor(path, name=""):
    return dict(name=name, bytes=path.stat().st_size, sha256=hashlib.sha256(path.read_bytes()).hexdigest())


def make_manifest(bundle_id, release_version, archive):
    version(release_version)
    return dict(schema=1, bundle_id=bundle_id, version=release_version, archive=archive)


def requirement(release_version):
    return (f'=anchor apple generic and certificate leaf[subject.OU] = "{SETTINGS["team"]}" '
            'and certificate leaf[field.1.2.840.113635.100.6.1.13] exists '
            f'and identifier "{SETTINGS["bundle_id"]}" and info[CFBundleShortVersionString] = "{release_version}"')


def verify_bundle(app, release_version):
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", "-R", requirement(release_version), app)


LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


def unregister(*apps):
    """Drop built copies from LaunchServices; the installed app must stay the only registration."""
    for app in apps:
        if Path(app).exists():
            subprocess.run([LSREGISTER, "-u", str(app)], capture_output=True)


def clean_worktree():
    if output("git", "-C", SETTINGS["root"], "status", "--porcelain"):
        raise ValueError("Release builds require a clean worktree")


def archive_app(app, destination):
    paths = list(app.rglob("*")) if app.is_dir() else [app]
    if len(paths) > MAX_ENTRIES or sum(p.stat().st_size for p in paths if p.is_file()) > MAX_ARCHIVE_BYTES:
        raise ValueError("Release bundle exceeds the entry or size limit")
    # --keepParent keeps an .app's own folder but a bare file's containing folder,
    # so an executable is archived on its own and unpacks to its file name.
    run("/usr/bin/ditto", "-c", "-k", *([] if app.is_file() else ["--keepParent"]), app, destination)
    if destination.stat().st_size > MAX_ARCHIVE_BYTES:
        raise ValueError("Release exceeds the download limit")


def build(args):
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise ValueError("Releases currently target macOS ARM64 only")
    version(args.version)
    clean_worktree()
    root = SETTINGS["root"]
    out = root / DIST / args.version
    if out.exists():
        raise ValueError("Release directory already exists; refusing to overwrite it")
    env = dict(os.environ, HW_UPDATE_VERSION=args.version, HW_UPDATE_FEED_URL=feed_url(), HW_UPDATE_TEAM_ID=SETTINGS["team"])
    run(root / "build.sh", "release", env=env)
    out.mkdir(parents=True)
    app = out / SETTINGS["app"]
    run("/usr/bin/ditto", SETTINGS["built"], app)
    if not SETTINGS["executable"]:
        plist = app / "Contents/Info.plist"
        info = plistlib.loads(plist.read_bytes())
        info["CFBundleShortVersionString"] = info["CFBundleVersion"] = args.version
        info["CFBundleIdentifier"] = SETTINGS["bundle_id"]
        plist.write_bytes(plistlib.dumps(info))
    run("/usr/bin/codesign", "--force", "--deep", "--options", "runtime", "--timestamp",
        "--identifier", SETTINGS["bundle_id"], "--sign", SETTINGS["identity"], app)
    verify_bundle(app, args.version)
    with tempfile.TemporaryDirectory() as temp:
        submission = Path(temp) / "notarize.zip"
        run("/usr/bin/ditto", "-c", "-k", "--keepParent", app, submission)
        run("/usr/bin/xcrun", "notarytool", "submit", submission, "--keychain-profile", args.notary_profile, "--wait")
    if not SETTINGS["executable"]:
        run("/usr/bin/xcrun", "stapler", "staple", app)
        run("/usr/bin/xcrun", "stapler", "validate", app)
    verify_bundle(app, args.version)
    archive = out / f"{SETTINGS['prefix']}-{args.version}.zip"
    archive_app(app, archive)
    manifest = make_manifest(SETTINGS["bundle_id"], args.version, descriptor(archive, archive.name))
    (out / FEED).write_text(json.dumps(manifest, separators=(",", ":")))
    (out / "release.json").write_text(json.dumps(dict(commit=output("git", "-C", root, "rev-parse", "HEAD")), indent=2))
    if not SETTINGS["executable"]:
        unregister(app, SETTINGS["built"])
    print(f"Prepared {out}: {archive.name} ({manifest['archive']['bytes']} bytes). Nothing published.")


def anonymous(url, expected=None, attempts=12):
    """Fetch without credentials. GitHub's latest/download redirect can lag a new release by
    seconds, so a mismatch is retried before it counts as a failure."""
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(urllib.request.Request(url), timeout=120) as response:
                data = response.read()
            if expected is None or expected(data):
                return data
        except urllib.error.URLError:
            pass
        time.sleep(5)
    raise ValueError(f"Public verification failed: {url}")


def notes(release_version):
    previous = subprocess.run(["git", "-C", SETTINGS["root"], "describe", "--tags", "--abbrev=0", "--match", "v*"],
                              capture_output=True, text=True).stdout.strip()
    span = f"{previous}..HEAD" if previous else "HEAD"
    log = output("git", "-C", SETTINGS["root"], "log", "--format=- %s", span)
    return f"{SETTINGS['app'].removesuffix('.app')} {release_version}\n\n{log}\n"


def publish(args):
    out = args.directory.resolve()
    metadata = json.loads((out / "release.json").read_text())
    manifest = json.loads((out / FEED).read_text())
    release_version = manifest["version"]
    version(release_version)
    if manifest["bundle_id"] != SETTINGS["bundle_id"]:
        raise ValueError("Manifest belongs to another application")
    clean_worktree()
    root, repo = SETTINGS["root"], SETTINGS["repo"]
    commit = output("git", "-C", root, "rev-parse", "HEAD")
    if commit != metadata["commit"]:
        raise ValueError("Release was built from another commit")
    if not output("git", "-C", root, "branch", "-r", "--contains", commit):
        raise ValueError("Push the release commit before publishing")
    archive = out / manifest["archive"]["name"]
    if descriptor(archive, archive.name) != manifest["archive"]:
        raise ValueError("Release artifact hash mismatch")
    existing = subprocess.run(["gh", "release", "view", "--repo", repo, "--json", "tagName", "--jq", ".tagName"],
                              capture_output=True, text=True)
    if existing.returncode == 0 and existing.stdout.strip() and version(release_version) <= version(existing.stdout.strip().lstrip("v")):
        raise ValueError("Published versions must advance; refusing a downgrade or same-version replacement")
    tag = f"v{release_version}"
    run("gh", "release", "create", tag, "--repo", repo, "--target", commit, "--title", f"{SETTINGS['app'].removesuffix('.app')} {release_version}",
        "--notes", notes(release_version), "--draft", archive, out / FEED)
    # Publishing is the commit point: latest/download only points at a release once it is public.
    run("gh", "release", "edit", tag, "--repo", repo, "--draft=false", "--latest")
    published = (out / FEED).read_bytes()
    anonymous(feed_url(), lambda data: data == published)
    base = f"https://github.com/{repo}/releases/download/{tag}/{archive.name}"
    anonymous(base, lambda data: hashlib.sha256(data).hexdigest() == manifest["archive"]["sha256"])
    print(f"Published {tag}: {feed_url()}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    build_parser = commands.add_parser("build", help="build, sign, notarize and package; publishes nothing")
    build_parser.add_argument("version")
    build_parser.add_argument("--notary-profile", required=True)
    publish_parser = commands.add_parser("publish", help="publish a prepared dist.noindex/<version> as a GitHub release")
    publish_parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    build(args) if args.command == "build" else publish(args)

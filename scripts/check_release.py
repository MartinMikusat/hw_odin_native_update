#!/usr/bin/env python3
"""Checks the release tool's pure contracts against the shape the Odin updater decodes."""
import importlib.util
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("release_macos", Path(__file__).with_name("release_macos.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
release.configure("/tmp/x", "App", "com.example.app", "ABCDE12345", "owner/app", "build/app.app", "app")

assert release.version("1.20.3") == (1, 20, 3)
for bad in ("1.2", "01.2.3", "1.2.3-beta", "1.2.3.4", "a.b.c", "1234567890.0.0"):
    try:
        release.version(bad)
    except ValueError:
        continue
    sys.exit(f"version accepted {bad!r}")
manifest = release.make_manifest("com.example.app", "1.2.3", dict(name="app-1.2.3.zip", bytes=1, sha256="0" * 64))
assert sorted(manifest) == ["archive", "bundle_id", "schema", "version"] and manifest["schema"] == 1
assert sorted(manifest["archive"]) == ["bytes", "name", "sha256"]
assert 'identifier "com.example.app"' in release.requirement("1.2.3")
assert release.feed_url() == "https://github.com/owner/app/releases/latest/download/update.json"
release.configure("/tmp/x", "tool", "com.example.tool", "ABCDE12345", "owner/tool", "build/tool", "tool", executable=True)
assert release.SETTINGS["app"] == "tool" and release.SETTINGS["executable"]
import tempfile, zipfile
with tempfile.TemporaryDirectory() as temp:
    tool = Path(temp) / "1.0.0" / "tool"
    tool.parent.mkdir()
    tool.write_bytes(b"x")
    release.archive_app(tool, Path(temp) / "tool.zip")
    assert zipfile.ZipFile(Path(temp) / "tool.zip").namelist() == ["tool"], "an executable must unpack to its file name"
print("release tool checks passed")

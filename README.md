# hw_odin_native_update

Self-updating macOS apps from GitHub releases. Odin updater (`update.odin`, `update_macos.odin`)
plus the release tool (`scripts/release_macos.py`). Import with
`-collection:native_update=<this folder>`.

## Contract

- A release carries `update.json` and one full app archive. The app fetches
  `https://github.com/<owner>/<repo>/releases/latest/download/update.json`; the archive is
  taken from the same directory.
- `update.json`: `{"schema":1,"bundle_id":..,"version":"x.y.z","archive":{"name":..,"bytes":..,"sha256":..}}`.
  The updater accepts only HTTPS, the app's own bundle ID, a strictly newer version, a plain
  `.zip` file name, and at most 256 MiB.
- Trust comes from the code signature, not the feed: the unpacked bundle must satisfy a code
  requirement pinning the Developer ID team, the bundle ID and the announced version, and is
  verified again before replacement. A hijacked feed cannot install anything the team did not sign.
- `prepare` (run on a worker thread) downloads and verifies into a staging directory; `apply`
  swaps the verified bundle in beside the installed app with `renamex_np`. The app decides when
  to apply (hw_fileManager applies on quit). The previous bundle is deleted after the swap.
- Full archives only; there are no binary patches.

## Release tool

```sh
python3 scripts/release_macos.py build 1.2.3 --notary-profile <keychain-profile>   # signs, notarizes, packages into dist.noindex/<version>; publishes nothing
python3 scripts/release_macos.py publish dist.noindex/1.2.3                                # GitHub release via gh
```

The project's `build.sh release` must honour `HW_UPDATE_VERSION`, `HW_UPDATE_FEED_URL` and
`HW_UPDATE_TEAM_ID` from the environment (compiled in as `-define`s) and write the bundle named by
`configure(built_app=...)`. Publishing requires a clean, pushed commit and a version above the latest release.

```sh
./test.sh
```

The output folder is `dist.noindex` so Spotlight never registers the built copies under the installed app's bundle ID; extra registrations make the Dock show a generic icon. The tool also unregisters the built copies from LaunchServices.

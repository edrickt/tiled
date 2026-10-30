# Cutting a release

This is the hand procedure that replaced `.github/workflows/release.yml`. The
gates themselves are not restated here: `AGENTS.md` § Validation runs is the
only gate policy, and the live suites are described in `README.md` § Testing.

The workflow this replaces is still readable in history:

```bash
git show c2909d1:.github/workflows/release.yml
```

## 1. Set the version and write what changed

`VERSION` is authoritative. The bundle's `CFBundleShortVersionString`, the
build number `CFBundleVersion` (derived from it in `scripts/make-app.sh`), the
git tag, and the download filename all come from it, so a release that
disagrees with the file ships an About box that lies. `0.x` minor bumps are
for breaking changes.

```bash
tr -d '[:space:]' < VERSION   # e.g. 0.3.0
```

- Move `CHANGELOG.md`'s `[Unreleased]` entries under a new `## [x.y.z] - YYYY-MM-DD`
  heading.
- Optionally add `docs/release-notes/v<version>.md` for the GitHub release
  body, titled for users rather than for maintainers: what changed, and the
  install steps. Without that file the release falls back to GitHub's
  generated notes.

## 2. Run the gates

```bash
swift build
make check                                  # suite once; README's count must match
make exhaustive                             # exhaustive undo replay (hand-off gate)
python3 tools/mutation/mutate.py            # the full table, not --since
scripts/doctor.sh                           # preflight: GUI session, AX trust, no stale hosts
./scripts/run-repro.sh                      # live end-to-end, after the preflight passes
```

The mutation table is the gate that notices a weakened assertion, which is
why a release runs the whole table rather than the `--since` slice. The live
suite cannot be replaced by the unit suite: see `README.md` § Testing for the
fixed-coordinate trap that makes a narrow display look like a regression.

## 3. Confirm the tag will match `VERSION`

The release workflow refused a tag that disagreed with `VERSION`. Nothing
enforces that now, so check it by hand before tagging:

```bash
version=$(tr -d '[:space:]' < VERSION)
tag="v$version"
echo "VERSION is $version, so the tag must be $tag"
git tag --list "$tag"                  # empty means the tag is free
git log --oneline -1 -- VERSION        # the commit that last set it
```

`scripts/make-app.sh` already rejects a `VERSION` that is not
`MAJOR.MINOR.PATCH`, so a malformed value fails at step 4 rather than at the
About box.

## 4. Build, sign, and verify the bundle

A release ships a fat binary for Apple Silicon and Intel; local builds stay
single-architecture because they are twice as fast and nobody distributes
them.

```bash
UNIVERSAL=1 ./scripts/make-app.sh
codesign --verify --deep --strict build/Tiled.app
plutil -lint build/Tiled.app/Contents/Info.plist
lipo -archs build/Tiled.app/Contents/MacOS/Tiled        # must list arm64 and x86_64
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  build/Tiled.app/Contents/Info.plist                   # must print $version
```

`make-app.sh` ad-hoc signs the bundle (`codesign -s -`). There is no
Developer ID and no notarization, which is why the install steps tell people
to right-click → **Open** once.

## 5. Package

```bash
version=$(tr -d '[:space:]' < VERSION)
cd build
ditto -c -k --keepParent Tiled.app "Tiled-$version.zip"
shasum -a 256 "Tiled-$version.zip" | tee "Tiled-$version.zip.sha256"
cd ..
```

`README.md` § Installing a release build tells users to check the download
with `shasum -a 256 -c Tiled-<version>.zip.sha256`, so the `.sha256` file is a
deliverable, not a convenience. It records the bare filename, so that check
only resolves from the directory the download landed in — verifying it from
anywhere else reports `FAILED open or read` on a perfectly good asset.

## 6. Tag and publish

```bash
version=$(tr -d '[:space:]' < VERSION)
tag="v$version"
git tag -a "$tag" -m "Tiled $tag"
git push origin master --follow-tags

notes="docs/release-notes/$tag.md"
if [[ -f "$notes" ]]; then
  gh release create "$tag" \
    "build/Tiled-$version.zip" "build/Tiled-$version.zip.sha256" \
    --title "Tiled $tag" --notes-file "$notes"
else
  gh release create "$tag" \
    "build/Tiled-$version.zip" "build/Tiled-$version.zip.sha256" \
    --title "Tiled $tag" --generate-notes
fi
```

Tag after the gates, not before: a tag pushed to a red gate has to be moved,
and a moved tag breaks anybody who already fetched it.

## If something is wrong after publishing

The published assets are immutable in practice — people download them. Fix
forward: bump to the next patch version, cut a new release, and say in its
notes what the previous one got wrong. Deleting a release that has downloads
does not un-download it.

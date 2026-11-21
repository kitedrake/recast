# Recast

- Build with `./build.sh` and test with `./test.sh`. Both need Xcode's toolchain (macOS 26 SDK); the Command Line
  Tools alone are not enough.
- omso Builder builds this repository from `omso-build.json` (build, tests, `--self-test`, copy into
  `/Applications/omso`). Keep that file working when build or test commands change.
- The remote is the GitHub repository `omsomso/recast` (`origin`); `main` is the working branch.
  Commit validated work; push or install only when the user asks. VSTS's install and push permissions don't
  apply here.
- Conversions never write over an original: encode to a hidden temporary file, then move it into place. Keep
  `OutputPlanner` treating every input of a batch as taken.
- Report anything a conversion changes beyond the requested format (forced resampling, mixdown, clipping, level
  changes, dropped cover art) as an outcome note so the row shows it.
- When adding or changing format support, update the README format table and add a fixture-based test: lossless
  formats must round-trip bit-exactly; compressed formats must line up with the source and keep tags and cover art.
- Vendored codecs (`Packages/Lame/Sources/CLame`, `Sources/COggVorbis`) stay unmodified; record any update in
  their `OMSO_PROVENANCE.md`.
- LAME (GNU LGPL) stays its own dynamic library, `libmp3lame.dylib` in `Contents/Frameworks`, shipped with
  `LAME-COPYING.txt` and `LAME-NOTICE.txt`. Never link it statically into Recast or another target.
- Tests and experiments use generated fixtures or copies in temporary folders. Never point conversions at the
  user's own files in place.
- In-app updates use Sparkle, pinned in `Package.swift`. Only release builds (`UPDATE_FEED_URL` and
  `UPDATE_PUBLIC_KEY` set) contain an updater; keep plain and omso Builder builds without one. `CFBundleVersion`
  is `VERSION`, which Sparkle compares, so bump `VERSION` for every release. Releases go through `release.py` in
  the `software-site` repository; after changing Sparkle or `build.sh`, run `sh scripts/test-update.sh recast`
  there. Never commit signing keys.

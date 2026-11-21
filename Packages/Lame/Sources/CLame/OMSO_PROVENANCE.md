# LAME 3.100 (vendored encoder source)

- Copied unmodified on 6 November 2026 from omso-daw's `third_party/lame`, which holds the official
  `lame-3.100.tar.gz` (SHA-256 `ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e`); see that
  project's provenance note for what was kept. `config/config.h` is omso-daw's `cmake/lame/config.h`.
- Licence: GNU Library General Public License, version 2 (`COPYING`); LAME's notes in `LICENSE`.
- Moved from `Sources/CLame` to `Packages/Lame/Sources/CLame` on 21 November 2026, files unchanged. Recast now
  builds it as a separate, replaceable dynamic library, `libmp3lame.dylib` (`Packages/Lame/Package.swift`), and
  copies it into `Recast.app/Contents/Frameworks`. The app also carries `COPYING` (as `LAME-COPYING.txt`) and
  `Packages/Lame/NOTICE.txt` (as `LAME-NOTICE.txt`), which says where this source is.

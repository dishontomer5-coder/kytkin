# Third-party notices

Kytkin itself is MIT-licensed (see [LICENSE](LICENSE)). It has no third-party code dependencies.
It bundles the data files below.

## Public Suffix List

- **What:** `Resources/PublicSuffixList/public_suffix_list.dat`, the list of public domain suffixes
  (`co.il`, `co.uk`, `github.io`, …). Kytkin uses it to reduce a website's address to its registrable
  domain (`www.ynet.co.il` → `ynet.co.il`) for per-website language rules. It is copied into the app
  bundle's `Contents/Resources` folder.
- **Source:** https://publicsuffix.org/list/public_suffix_list.dat (project: https://publicsuffix.org/,
  repository: https://github.com/publicsuffix/list)
- **Version bundled:** `VERSION: 2026-11-06_09-01-47_UTC`, `COMMIT: 94ec5df7273926560d91e77c002000ba1a53fec4`
  (downloaded 2026-11-07)
- **License:** Mozilla Public License 2.0 (MPL-2.0). The file is shipped **unmodified**, with its MPL
  notice header intact; it is its own Source Code Form, so the bundled copy is also where to get the
  source. The full license text is in
  [`Resources/PublicSuffixList/LICENSE-MPL-2.0.txt`](Resources/PublicSuffixList/LICENSE-MPL-2.0.txt)
  (also copied into the app bundle) and at https://mozilla.org/MPL/2.0/. MPL-2.0 is file-level copyleft,
  so it doesn't extend to Kytkin's own MIT code.
- **Updating:** `./scripts/update-psl` (developer machine only; the app never downloads the list).
  Then update the version line above and run the tests.

## Public Suffix List test vectors (tests only)

- **What:** `Tests/KytkinTests/Fixtures/psl/test_psl.txt`, the official PSL test cases, from the same
  repository and commit as the list. Used only by the unit tests; not shipped in the app.
- **License:** dedicated to the public domain (CC0 1.0), per the file's header.

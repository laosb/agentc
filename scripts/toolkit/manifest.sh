# agentc Toolkit — what goes into the bundle.
#
# The toolkit is a small set of tools mounted read-only into every agentc
# container at /agent-isolation/toolkit, with bin/ appended to the *end* of
# PATH. It guarantees that curl and friends exist even on an image that ships
# nothing, while leaving the image's own copies in charge when it has them.
#
# This manifest and build-toolkit.sh are the bundle inputs: CI rebuilds and
# republishes the toolkit when either changes, and at no other time — an agentc
# release does not reissue an unchanged toolkit.
#
# CI increments TOOLKIT_VERSION after an input changes and merges the matching
# `ToolkitManager.version` through a version-bump PR before publishing
# `toolkit-v$TOOLKIT_VERSION`. ToolkitManifestTests keeps them synchronized.

TOOLKIT_VERSION=3

# dest | arch | url | sha256 | member
#
#   dest    where the file lands inside the bundle. Anything under bin/ is
#           made executable; everything else is mounted read-only as data.
#   arch    x64, arm64, or any (included in both bundles).
#   sha256  digest of the file at `url`, verified before it is unpacked.
#   member  path to extract from the archive, or `-` when the URL already
#           points at the file itself. Archives may be .tar.gz or .tar.xz;
#           nothing is unpacked beyond the single named member.
#
# Every URL must be https, and every digest must be one a human checked against
# what upstream published — not one taken from the download it is meant to
# verify.
TOOLKIT_CONTENTS=$(cat <<'CONTENTS'
bin/curl|x64|https://github.com/stunnel/static-curl/releases/download/8.22.0/curl-linux-x86_64-musl-8.22.0.tar.xz|dfb02460ba2abe513087538f12a3cf79b74b64a5ea3787ce8ac0cdb11251f884|curl
bin/curl|arm64|https://github.com/stunnel/static-curl/releases/download/8.22.0/curl-linux-aarch64-musl-8.22.0.tar.xz|cf94cbeaae1b3c1944a4a761ef04478f8f0b23e93a324b5ed009b2082eda11f3|curl
bin/jq|x64|https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-linux-amd64|b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f|-
bin/jq|arm64|https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-linux-arm64|8b85c817833814ddca00a144c33705546355afccf0cf39b188f3cdb48b852309|-
bin/rg|x64|https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-x86_64-unknown-linux-musl.tar.gz|33e15bcf1624b25cdd2a55813a47a2f95dbe126268203e76aa6a585d1e7b149c|ripgrep-15.2.0-x86_64-unknown-linux-musl/rg
bin/rg|arm64|https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-aarch64-unknown-linux-musl.tar.gz|800b1e7206afe799dfb5a6901f23147cfaabe0e52210538100f61e86e1740915|ripgrep-15.2.0-aarch64-unknown-linux-musl/rg
share/ca-certificates.crt|any|https://curl.se/ca/cacert-2026-09-25.pem|a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505|-
CONTENTS
)

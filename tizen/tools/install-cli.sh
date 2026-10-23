#!/usr/bin/env bash
# Immuch360 for Samsung TVs: installs the Tizen SDK command line tools, to sign the package folder into a .wgt in CI.
#
#   tizen/tools/install-cli.sh [<install folder>]      $HOME/tizen-studio by default; its data goes to <folder>-data
#
# The installer is Samsung's public download web-cli_Tizen_SDK_10.0_ubuntu-64.bin of 3 November 2025 (401,290,863
# bytes, SHA256 below). download.tizen.org gives about 20 KB/s per connection, so aria2c fetches it in 16 ranges. It is
# kept in $TIZEN_CLI_CACHE ($HOME/.cache/tizen-cli; the workflow caches that folder under the SHA256) and checked after
# every download and every restore: a file that does not match is fetched again, never run. The installer carries
# everything the CLI needs and installs without the network (about 3 minutes). Nothing of the SDK goes into an
# artifact: Samsung's TV SDK licence forbids passing it on, and the CLI needs neither the TV extension nor an account.
set -euo pipefail

INSTALLER=web-cli_Tizen_SDK_10.0_ubuntu-64.bin
URL="https://download.tizen.org/sdk/Installer/tizen-sdk_10.0/$INSTALLER"
SIZE=401290863
SHA256=65d2a569cbf0351dca4b94254f2c642d49195ac4964e08a76b4eaabc9ce4bed0

DEST=${1:-$HOME/tizen-studio}
CACHE=${TIZEN_CLI_CACHE:-$HOME/.cache/tizen-cli}
FILE="$CACHE/$INSTALLER"

say() { echo "[install-cli] $*"; }
checked() {
	[ -f "$FILE" ] && [ "$(stat -c %s "$FILE")" = "$SIZE" ] && echo "$SHA256  $FILE" | sha256sum --check --status
}

if [ -x "$DEST/tools/ide/bin/tizen" ]; then
	say "already installed in $DEST"
	exit 0
fi

mkdir -p "$CACHE"
if checked; then
	say "$INSTALLER from the cache, size and SHA256 checked"
else
	rm -f "$FILE" "$FILE.aria2"
	if ! command -v aria2c > /dev/null; then
		say 'aria2c is missing: installing the aria2 package'
		sudo apt-get install -y --no-install-recommends aria2 > /dev/null
	fi
	say "downloading $URL in 16 ranges"
	aria2c --max-connection-per-server=16 --split=16 --min-split-size=4M --max-tries=10 --retry-wait=5 \
		--connect-timeout=30 --timeout=60 --summary-interval=60 --console-log-level=warn --file-allocation=none \
		--checksum="sha-256=$SHA256" --dir "$CACHE" --out "$INSTALLER" "$URL"
	if ! checked; then
		say "FAILED: $INSTALLER does not have the expected size and SHA256"
		rm -f "$FILE"
		exit 1
	fi
	say 'downloaded, size and SHA256 checked'
fi

chmod +x "$FILE"
LOG="$CACHE/install.log"
say "installing into $DEST"
if ! "$FILE" --accept-license "$DEST" > "$LOG" 2>&1 || [ ! -x "$DEST/tools/ide/bin/tizen" ]; then
	tail -n 30 "$LOG"
	say 'FAILED: the installer did not install the tizen command'
	exit 1
fi
say "installed: $("$DEST/tools/ide/bin/tizen" version 2> /dev/null | tr '\n' ' ')"

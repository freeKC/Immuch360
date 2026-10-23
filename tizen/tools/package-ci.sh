#!/usr/bin/env bash
# Immuch360 for Samsung TVs: signs the package folder into a .wgt with the official Tizen tools, in CI.
#
#   tizen/tools/package-ci.sh <package folder> <output folder> [<tizen-studio folder>]
#
# Every install on a Samsung TV, and on Samsung's TV emulator, needs a Samsung certificate made with the tester's
# Samsung account for the DUID of his TV. A CI build cannot make that: the tester re-signs the .wgt (Apps2Samsung does
# it by itself; with Tizen Studio, tizen package -t wgt -s <his profile> -- <the .wgt>). What CI does is have the
# official packager accept and sign the folder. For this run only it makes a Tizen author certificate with a random
# password (made here, never kept, never printed) and a security profile with it and the SDK's public distributor
# certificate (tizen-distributor-signer-new.p12, valid to 2032; its password tizenpkcs12passfordsigner is published
# with the SDK; without it the CLI takes one that expired in 2012). Author certificates of the CLI are issued under
# "Tizen Developers CA", valid until 1 January 2027: after that date this step is to be checked again.
#
# The CLI keeps passwords in a keyring, which a runner has not: the passwords go into profiles.xml before the run, and
# the author password prompt of tizen package is answered through a pseudo terminal. The certificate and the profile
# are removed at the end.
set -euo pipefail

FOLDER=$(readlink -f "$1")
OUT=$(readlink -f "$2")
SDK=$(readlink -f "${3:-$HOME/tizen-studio}")
TIZEN="$SDK/tools/ide/bin/tizen"
DATA=$(sed -n 's/^TIZEN_SDK_DATA_PATH=//p' "$SDK/sdk.info")
DATA=${DATA:-$SDK-data}
PROFILE=immuch360-ci
AUTHOR="$DATA/keystore/author/$PROFILE.p12"
DISTRIBUTOR="$SDK/tools/certificate-generator/certificates/distributor"

say() { echo "[package-ci] $*"; }

[ -x "$TIZEN" ] || { say "FAILED: no tizen command in $SDK (tizen/tools/install-cli.sh)"; exit 1; }
[ -f "$FOLDER/config.xml" ] || { say "FAILED: $FOLDER has no config.xml (tizen/tools/build-wgt.mjs)"; exit 1; }
mkdir -p "$OUT"

TIZEN_AUTHOR_PASSWORD=$(openssl rand -hex 24)
TIZEN_DIST_PASSWORD=tizenpkcs12passfordsigner
export TIZEN_AUTHOR_PASSWORD TIZEN_DIST_PASSWORD PROFILE
if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::add-mask::$TIZEN_AUTHOR_PASSWORD"; fi

forget() {
	"$TIZEN" security-profiles remove -n "$PROFILE" > /dev/null 2>&1 || true
	rm -f "$AUTHOR"
}
trap forget EXIT
forget

say 'a throwaway author certificate and its profile'
"$TIZEN" certificate -a "$PROFILE" -p "$TIZEN_AUTHOR_PASSWORD" -c FR -n "Immuch360 CI" -f "$PROFILE" > /dev/null
[ -f "$AUTHOR" ] || { say "FAILED: no author certificate in $AUTHOR"; exit 1; }
"$TIZEN" security-profiles add -n "$PROFILE" -a "$AUTHOR" -p "$TIZEN_AUTHOR_PASSWORD" \
	-d "$DISTRIBUTOR/tizen-distributor-signer-new.p12" -dc "$DISTRIBUTOR/tizen-distributor-ca-new.cer" \
	-dp "$TIZEN_DIST_PASSWORD" -f > /dev/null

# The passwords of this profile into profiles.xml, read from the environment
PROFILES="$DATA/profile/profiles.xml" python3 - << 'PY'
import os, re
path = os.environ['PROFILES']
text = open(path, encoding='utf-8').read()
start = text.index('<profile name="%s">' % os.environ['PROFILE'])
end = text.index('</profile>', start)
block = text[start:end]
block = re.sub(r'(distributor="0" key="[^"]*" password=")[^"]*"', lambda m: m.group(1) + os.environ['TIZEN_AUTHOR_PASSWORD'] + '"', block)
block = re.sub(r'(distributor="1" key="[^"]*" password=")[^"]*"', lambda m: m.group(1) + os.environ['TIZEN_DIST_PASSWORD'] + '"', block)
open(path, 'w', encoding='utf-8').write(text[:start] + block + text[end:])
os.chmod(path, 0o600)
PY

rm -f "$FOLDER/author-signature.xml" "$FOLDER/signature1.xml" "$FOLDER"/*.wgt "$OUT"/*.wgt
say "tizen package -t wgt -s $PROFILE"
# tizen package asks the author password on its terminal (and may offer to keep it): answered here
python3 - "$TIZEN" package -t wgt -s "$PROFILE" -o "$OUT" -- "$FOLDER" << 'PY'
import os, pty, select, sys, time
password = os.environ['TIZEN_AUTHOR_PASSWORD']
pid, fd = pty.fork()
if pid == 0:
    os.execv(sys.argv[1], sys.argv[1:])
seen, pending, deadline = b'', b'', time.time() + 900
while time.time() < deadline:
    ready, _, _ = select.select([fd], [], [], 1)
    if not ready:
        continue
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    seen += chunk
    pending += chunk
    tail = pending.decode('utf-8', 'replace').lower().rstrip()
    if 'password' in tail and tail.endswith(':'):
        os.write(fd, (password + '\n').encode())
        pending = b''
    elif tail.endswith('?') or '(y/n)' in tail or '(y)' in tail:
        os.write(fd, b'N\n')
        pending = b''
_, status = os.waitpid(pid, 0)
text = seen.decode('utf-8', 'replace').replace('\r', '').replace(password, '<masked>')
for line in text.splitlines():
    if line.strip() and 'password' not in line.lower():
        print('  ' + line)
sys.exit(os.waitstatus_to_exitcode(status) if hasattr(os, 'waitstatus_to_exitcode') else 1)
PY

shopt -s nullglob
made=("$OUT"/*.wgt)
if [ "${#made[@]}" -ne 1 ]; then
	say "FAILED: ${#made[@]} .wgt files in $OUT"
	exit 1
fi
say "signed: ${made[0]}"

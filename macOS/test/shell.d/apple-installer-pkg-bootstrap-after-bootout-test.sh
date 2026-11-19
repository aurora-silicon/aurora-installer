#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

python3 - "$ROOT/Packaging/pkg/scripts/postinstall" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]).read_text()
start = source.index("  /bin/launchctl bootout")
end = source.index("  if ! /bin/launchctl print system/\"$LABEL\" >/dev/null 2>&1; then\n    echo \"postinstall: $LABEL did not register", start)
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    # launchd stand-in: the old service stays registered for $LINGER prints
    # after bootout; bootstrap succeeds unless $BOOTSTRAP_FAILS is set, and is
    # refused while the old service is still registered.
    stub = root / "launchctl"
    stub.write_text("""#!/bin/bash
echo "$1" >> "$CALLS"
case $1 in
  bootout) exit 0 ;;
  print)
    prints=$(grep -c '^print$' "$CALLS")
    (( prints > LINGER )) && exit 1
    exit 0 ;;
  bootstrap)
    prints=$(grep -c '^print$' "$CALLS")
    (( prints > LINGER )) || { echo 'Bootstrap failed: 5: Input/output error'; exit 5; }
    [[ -z $BOOTSTRAP_FAILS ]] || { echo 'Bootstrap failed: 37'; exit 37; }
    exit 0 ;;
esac
exit 2
""")
    stub.chmod(0o755)
    script = root / "probe.sh"
    body = source[start:end].replace("/bin/launchctl", str(stub))
    body = body.replace("/bin/sleep 0.1", "/bin/true")
    body = body.replace("/usr/bin/logger", "/bin/true")
    script.write_text("#!/bin/bash\nPLIST=fixture\nLABEL=fixture\n" + body)
    # (old service lingers for N prints, bootstrap fails, exit status, bootstraps run)
    for linger, fails, status, bootstraps in [
        (0, "", 0, 1),     # gone at once: one bootstrap
        (5, "", 0, 1),     # still tearing down: wait, then one bootstrap
        (99, "", 0, 1),    # gone on the last check: still one bootstrap
        (1000, "", 1, 0),  # never goes: fail without bootstrapping over it
        (0, "1", 1, 1),    # a real bootstrap failure is reported, not retried
    ]:
        calls = root / "calls"
        calls.write_text("")
        env = dict(os.environ, CALLS=str(calls), LINGER=str(linger), BOOTSTRAP_FAILS=fails)
        result = subprocess.run(["bash", str(script)], env=env, capture_output=True, text=True)
        assert result.returncode == status, (linger, fails, result.stderr)
        made = calls.read_text().split()
        assert made[0] == "bootout", made
        assert made.count("bootstrap") == bootstraps, (linger, made)
        if bootstraps:
            assert "Input/output error" not in result.stderr, result.stderr
print("PASS: bootstrap runs once, only after launchd has dropped the old service; a lingering service or a failed bootstrap fails the package")
PY

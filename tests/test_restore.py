# SPDX-License-Identifier: MIT
# Copyright (c) 2026 The Aurora Silicon Contributors
"""aurora-restore: catalog parsing, plans on disk images, and the generated
Recovery script run against stand-ins for diskutil, curl and installer."""
import contextlib
import io
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "tools", "restore"))
sys.path.insert(0, os.path.join(HERE, "..", "tools", "whole-disk"))
sys.path.insert(0, os.path.join(HERE, "..", "tools", "wifi-firmware"))
import apfs_ro  # noqa: E402
import aurora_restore as ar  # noqa: E402
import aurora_whole_disk as wd  # noqa: E402
import whole_disk_fixtures as fx  # noqa: E402

GIB, MIB = 1 << 30, 1 << 20


def dist(version, build, devices, title="macOS Test"):
    ids = ", ".join(f"'{d}'" for d in devices)
    return textwrap.dedent(f"""\
        <?xml version="1.0" encoding="utf-8"?>
        <installer-gui-script minSpecVersion="2">
            <title>{title}</title>
            <auxinfo><dict>
                <key>BUILD</key>
                <string>{build}</string>
                <key>VERSION</key>
                <string>{version}</string>
            </dict></auxinfo>
            <script>
            var supportedDeviceIDs = [{ids}];
            </script>
        </installer-gui-script>
        """)


def catalog(products):
    """products: [(id, version, build, devices, size)] -> (catalog bytes, get)."""
    files, cat = {}, {"Products": {}}
    for pid, version, build, devices, size in products:
        base = f"https://swcdn.example/{pid}"
        cat["Products"][pid] = {
            "Packages": [{"URL": f"{base}/InstallInfo.plist", "Size": 1},
                         {"URL": f"{base}/InstallAssistant.pkg", "Size": size}],
            "Distributions": {"English": f"{base}/{pid}.English.dist"},
        }
        files[f"{base}/{pid}.English.dist"] = dist(version, build, devices).encode()
    cat["Products"]["update-only"] = {"Packages": [{"URL": "https://x/Update.pkg", "Size": 3}]}
    return plistlib.dumps(cat), files.__getitem__


PRODUCTS = [("p1", "15.8.2", "24H232", ["J314sAP", "J413AP"], 15 * 10**9),
            ("p2", "15.8.3", "24H241", ["J314sAP", "J413AP"], 15 * 10**9),
            ("p3", "26.7.3", "25G342", ["J314sAP", "J700AP"], 18 * 10**9),
            ("p4", "27.2.1", "26B131", ["J314sAP", "J700AP"], 17 * 10**9),
            ("p5", "27.2.1", "26B8132", ["J616cAP"], 17 * 10**9)]


class Catalog(unittest.TestCase):
    def setUp(self):
        data, get = catalog(PRODUCTS)
        self.installers = ar.parse_catalog(data, get)

    def test_parse(self):
        self.assertEqual([i["build"] for i in self.installers],
                         ["24H232", "24H241", "25G342", "26B131", "26B8132"])
        i = self.installers[3]
        self.assertEqual((i["version"], i["size"], i["devices"]),
                         ("27.2.1", 17 * 10**9, ["J314sAP", "J700AP"]))
        self.assertTrue(i["url"].endswith("/InstallAssistant.pkg"))

    def test_offered_newest_per_major_for_board(self):
        got = [i["build"] for i in ar.offered(self.installers, "J314sAP")]
        self.assertEqual(got, ["24H241", "25G342", "26B131"])
        self.assertEqual([i["build"] for i in ar.offered(self.installers, "j700ap")],
                         ["25G342", "26B131"])
        self.assertEqual(len(ar.offered(self.installers, "J314sAP", everything=True)), 4)
        self.assertEqual(ar.offered(self.installers, "J999AP"), [])

    def test_pick(self):
        self.assertEqual(ar.pick(self.installers, "J314sAP", "27.2.1")["build"], "26B131")
        self.assertEqual(ar.pick(self.installers, "J314sAP", "15")["build"], "24H241")
        self.assertEqual(ar.pick(self.installers, "J616cAP", "26B8132")["build"], "26B8132")
        self.assertFalse(ar.pick(self.installers, "J314sAP", "15.8.2")["current"])
        self.assertTrue(ar.pick(self.installers, "J314sAP", "26")["current"])
        with self.assertRaises(ar.Refusal):
            ar.pick(self.installers, "J700AP", "15.8.3")

    def test_needed_bytes(self):
        self.assertEqual(ar.needed_bytes({"size": 17 * 10**9}) % GIB, 0)
        self.assertGreaterEqual(ar.needed_bytes({"size": 17 * 10**9}), 69 * 10**9)


class Board(unittest.TestCase):
    def test_board_from_compatible(self):
        with tempfile.TemporaryDirectory() as d:
            for compat, want in ((b"apple,j314s\0apple,t6000\0apple,arm-platform\0", "J314sAP"),
                                 (b"apple,j700\0apple,t8140\0", "J700AP")):
                with open(os.path.join(d, "compatible"), "wb") as f:
                    f.write(compat)
                self.assertEqual(ar.read_board(d), want)
            with open(os.path.join(d, "compatible"), "wb") as f:
                f.write(b"qemu,virt\0")
            with self.assertRaises(ar.Refusal):
                ar.read_board(d)
            os.unlink(os.path.join(d, "compatible"))
            with self.assertRaises(ar.Refusal):
                ar.read_board(d)


class Slice:
    def __init__(self, path, start):
        self.path, self.start = path, start

    def pread(self, n, off):
        with open(self.path, "rb") as f:
            f.seek(self.start + off)
            return f.read(n)


SMALL = {"version": "27.2.1", "build": "26B131", "title": "macOS Test", "product": "p4",
         "url": "https://swcdn.example/p4/InstallAssistant.pkg", "size": 512 * MIB}


def sfdisk_script(layout):
    """Like fx.sfdisk_script, but an entry with type None is left free."""
    per = MIB // 512
    lines, at = ["label: gpt"], per
    for name, ptype, mib in layout:
        if ptype:
            lines.append(f"start={at}, size={mib * per}, type={ptype}, name=\"{name}\"")
        at += mib * per
    return "\n".join(lines) + "\n"


class DiskImage(unittest.TestCase):
    """A real GPT in an image file, with synthetic Apple containers."""

    def make(self, layout=fx.LAYOUT, contents=fx.CONTENTS):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir)
        self.img = os.path.join(self.dir, "disk.img")
        total = sum(m for _, _, m in layout) + 2
        with open(self.img, "wb") as f:
            f.truncate(total * MIB)
        subprocess.run(["sfdisk", "--quiet", self.img], input=sfdisk_script(layout),
                       text=True, check=True)
        self.gpt = wd.read_gpt(self.img)
        self.byname = {p["name"]: p for p in self.gpt["parts"]}
        with open(self.img, "r+b") as f:
            for name, vols in contents.items():
                f.seek(self.byname[name]["start"])
                f.write(fx.container(vols))
        self.chosen = {"esp": self.byname["esp"]["uuid"], "group": fx.STUB_GROUP.upper(),
                       "system_fw": "26.6.2", "os_fw": "13.5", "iboot1": "mBoot"}
        self.layout = wd.classify(self.gpt, self.chosen, self.inspect)

    def inspect(self, node):
        p = next(p for p in self.gpt["parts"] if p["node"] == node)
        c = apfs_ro.Container(Slice(self.img, p["start"]))
        return [{"name": v.name, "role": v.role, "group": v.group.upper(),
                 "encrypted": v.encrypted} for v in c.volumes()]

    def setUp(self):
        self.saved = ar.MACOS_ROOM, ar.LINUX_MARGIN
        ar.MACOS_ROOM, ar.LINUX_MARGIN = 1 * GIB, 256 * MIB
        self.addCleanup(lambda: setattr(ar, "MACOS_ROOM", self.saved[0]))
        self.addCleanup(lambda: setattr(ar, "LINUX_MARGIN", self.saved[1]))

    def mounts(self, node):
        return {self.byname["boot"]["node"]: ["/boot"],
                self.byname["esp"]["node"]: ["/boot/efi"],
                self.byname["root"]["node"]: ["/", "/home"]}.get(node, [])

    def plan(self, mode, owner={"account": "aurora"}, **kw):
        kw.setdefault("min_size", 1 * GIB)
        kw.setdefault("root_devs", [self.byname["root"]["node"]])
        kw.setdefault("mounts", self.mounts)
        return ar.make_plan(SMALL, "J314sAP", self.chosen, self.gpt, self.layout, mode, owner,
                            **kw)


@unittest.skipUnless(shutil.which("sfdisk"), "needs sfdisk")
class Plans(DiskImage):

    def test_alongside_shrinks_root_before_system_recovery(self):
        self.make()
        p = self.plan("alongside")
        need = ar.needed_bytes(SMALL)
        root = self.byname["root"]
        self.assertEqual(p["shrink"]["node"], root["node"])
        self.assertEqual(p["shrink"]["to"], root["size"] - need)
        self.assertEqual(p["gap"], {"start": root["start"] + root["size"] - need, "size": need})
        self.assertEqual(p["predecessor"]["uuid"], root["uuid"])
        self.assertEqual(p["predecessor"]["size"], root["size"] - need)
        after = {q["uuid"]: q["size"] for q in p["partitions"]}
        self.assertEqual(after[root["uuid"]], root["size"] - need)
        self.assertEqual(p["containerBytes"], need)
        self.assertEqual(p["label"], "macOS 27.2.1")
        text = ar.plan_text(p)
        self.assertIn("Shrink the btrfs root", text)
        self.assertIn("Apple System Recovery", text)
        self.assertNotIn("DELETE", text)
        self.assertEqual(ar.phrase(p), "install macOS 27.2.1 alongside Aurora")

    def test_alongside_uses_existing_free_space_without_shrinking(self):
        self.make(fx.LAYOUT[:-1] + [("gap", None, 3072), fx.LAYOUT[-1]])
        p = self.plan("alongside")
        self.assertIsNone(p["shrink"])
        self.assertEqual(p["gap"]["start"], self.byname["root"]["start"] + self.byname["root"]["size"])
        self.assertEqual(p["gap"]["size"], 3072 * MIB)
        self.assertIn("already has the free space", ar.plan_text(p))

    def test_alongside_refusals(self):
        self.make()
        with self.assertRaisesRegex(ar.Refusal, "Linux needs at least"):
            self.plan("alongside", min_size=3 * GIB)
        with self.assertRaisesRegex(ar.Refusal, "spans 2 partitions"):
            self.plan("alongside", root_devs=["/dev/a", "/dev/b"])
        with self.assertRaisesRegex(ar.Refusal, "less than"):
            self.plan("alongside", size=GIB)
        with self.assertRaisesRegex(ar.Refusal, "isn't followed by Apple's System Recovery"):
            self.plan("alongside", root_devs=[self.byname["boot"]["node"]])

    def test_no_owner_and_no_macos_refuses(self):
        layout = [x for x in fx.LAYOUT if x[0] != "macos"]
        contents = {k: v for k, v in fx.CONTENTS.items() if k != "macos"}
        self.make(layout, contents)
        with self.assertRaisesRegex(ar.Refusal, "dfu-help"):
            self.plan("alongside", owner={"account": None})
        p = self.plan("alongside", owner={"account": "aurora"})
        self.assertIsNone(p["macos"])
        self.assertEqual(p["owner"], "aurora")

    def test_replace_deletes_linux_partitions_in_recovery(self):
        self.make()
        p = self.plan("replace")
        names = {q["uuid"]: n for n, q in self.byname.items()}
        self.assertEqual([names[d["uuid"]] for d in p["delete"]], ["esp", "boot", "root"])
        stub = self.byname["stub"]
        self.assertEqual(p["predecessor"]["uuid"], stub["uuid"])
        self.assertEqual(p["gap"]["start"], stub["start"] + stub["size"])
        self.assertEqual(p["gap"]["size"], (512 + 1024 + 4096) * MIB)
        self.assertIsNone(p["shrink"])
        text = ar.plan_text(p)
        self.assertIn("DELETE Aurora's Linux partitions", text)
        self.assertEqual(ar.phrase(p), "replace Aurora with macOS 27.2.1")
        ar.MACOS_ROOM = 6 * GIB
        with self.assertRaisesRegex(ar.Refusal, "needs more"):
            self.plan("replace")

    def test_native_reinstall_route_named_when_the_major_matches(self):
        self.make()
        routes = ar.native_routes(self.chosen)
        self.assertEqual([(r["name"], r["major"]) for r in routes],
                         [("Aurora's Recovery", 13), ("System Recovery", 26)])
        self.assertNotIn("WITHOUT THE SCRIPT", ar.plan_text(self.plan("alongside")))
        tahoe = dict(SMALL, version="26.7.3", build="25G342")
        p = ar.make_plan(tahoe, "J314sAP", self.chosen, self.gpt, self.layout, "replace",
                         {"account": "aurora"}, root_devs=[self.byname["root"]["node"]],
                         mounts=self.mounts)
        text = ar.plan_text(p)
        self.assertIn("WITHOUT THE SCRIPT", text)
        self.assertIn("System Recovery (26.6.2)", text)
        self.assertNotIn("Aurora's Recovery (13.5)", text)
        self.assertEqual(ar.native_routes({"os_fw": None, "system_fw": "garbage"}), [])
        self.assertNotIn("UNPROVEN", text)
        old = dict(self.chosen, os_fw="27.2")
        p = ar.make_plan(tahoe, "J314sAP", old, self.gpt, self.layout, "replace",
                         {"account": "aurora"}, root_devs=[self.byname["root"]["node"]],
                         mounts=self.mounts)
        self.assertIn("UNPROVEN: macOS 26.7.3 is older than Aurora's Recovery (27.2)",
                      ar.plan_text(p))

    def test_replace_never_takes_another_systems_partition(self):
        linux = fx.LAYOUT[4][1]
        # Another system's Linux partition between Aurora's /boot and root: refused.
        self.make(fx.LAYOUT[:5] + [("other", linux, 512)] + fx.LAYOUT[5:])
        with self.assertRaisesRegex(ar.Refusal, "isn't this installation's"):
            self.plan("replace")
        # The same partition after Aurora's root: kept, and not in the delete list.
        self.make(fx.LAYOUT[:6] + [("other", linux, 512)] + fx.LAYOUT[6:])
        p = self.plan("replace")
        other = self.byname["other"]["uuid"]
        self.assertNotIn(other, [d["uuid"] for d in p["delete"]])
        self.assertEqual(p["gap"]["start"] + p["gap"]["size"], self.byname["other"]["start"])

    def test_digest_tracks_the_disk(self):
        self.make()
        a, b = self.plan("alongside"), self.plan("alongside")
        self.assertEqual(a["digest"], b["digest"])
        self.gpt["parts"][3]["size"] -= MIB
        self.assertNotEqual(self.plan("alongside")["digest"], a["digest"])


FAKE_DISKUTIL = r'''#!/usr/bin/python3 -I
import json, os, plistlib, sys
S = os.environ["FAKE_STATE"]
st = json.load(open(S))
open(st["log"], "a").write(" ".join(sys.argv[1:]) + "\n")
parts = st["parts"]
def find(x):
    for p in parts:
        if x in (p["uuid"], p["id"]):
            return p
def save():
    json.dump(st, open(S, "w"))
a = sys.argv[1:]
if a[:2] == ["info", "-plist"]:
    p = find(a[2])
    if not p:
        sys.exit(1)
    sys.stdout.write(plistlib.dumps({"DeviceIdentifier": p["id"], "ParentWholeDisk": "disk0",
        "PartitionMapPartitionOffset": p["start"], "Size": p["size"], "TotalSize": 1}).decode())
elif a[:2] == ["list", "-plist"]:
    ids = ["disk0"] + [p["id"] for p in parts]
    sys.stdout.write(plistlib.dumps({"AllDisks": ids, "AllDisksAndPartitions": [
        {"DeviceIdentifier": "disk0", "Partitions": [{"DeviceIdentifier": p["id"]} for p in parts]}
    ]}).decode())
elif a[:3] == ["eraseVolume", "free", "none"]:
    parts.remove(find(a[3])); save()
elif a[0] == "addPartition":
    pred, fmt, label, size = a[1:5]
    p = find(pred)
    parts.append({"uuid": "NEW", "id": "disk0s99", "start": p["start"] + p["size"],
                  "size": int(size)})
    os.makedirs("/Volumes/" + label); save()
else:
    sys.exit(3)
'''

FAKE_CURL = r'''#!/bin/sh
echo "curl $*" >> "$FAKE_LOG"
case "$1" in -fsIL) exit 0 ;; esac
[ -e "$FAKE_LOG.fail" ] && exit 22
while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done
truncate -s "$FAKE_PKG_SIZE" "$out"
'''

FAKE_STAT = r'''#!/bin/sh
[ "$1" = -f ] && [ "$2" = %z ] && exec /usr/bin/stat -c %s "$3"
exit 9
'''

FAKE_INSTALLER = r'''#!/bin/sh
echo "installer $*" >> "$FAKE_LOG"
app="$4/Applications/Install macOS Test.app/Contents/MacOS"
mkdir -p "$app"
printf '#!/bin/sh\necho "app-started $*" >> "$FAKE_LOG"\n' > "$app/InstallAssistant"
chmod +x "$app/InstallAssistant"
'''


def private_volumes_ok():
    """Whether this host lets an unprivileged user mount a private /Volumes
    (user + mount namespaces). Package build sandboxes often don't."""
    if not (shutil.which("sfdisk") and shutil.which("unshare")):
        return False
    try:
        return subprocess.run(["unshare", "-rm", "sh", "-c", "mount -t tmpfs none /Volumes"],
                              capture_output=True, timeout=10).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


@unittest.skipUnless(private_volumes_ok(), "needs sfdisk and unprivileged user+mount namespaces")
class RecoveryScript(DiskImage):
    """Runs restore.sh in a user+mount namespace (a private /Volumes) against
    stand-ins that record every command."""

    def harness(self, plan, answer, args=(), mutate=None, twice=False):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d)
        bindir = os.path.join(d, "bin")
        os.mkdir(bindir)
        for name, body in (("diskutil", FAKE_DISKUTIL), ("curl", FAKE_CURL),
                           ("stat", FAKE_STAT), ("installer", FAKE_INSTALLER),
                           ("sleep", "#!/bin/sh\nexit 0\n")):
            path = os.path.join(bindir, name)
            with open(path, "w") as f:
                f.write(body)
            os.chmod(path, 0o755)
        log = os.path.join(d, "log")
        parts = [{"uuid": p["uuid"], "id": f"disk0s{i + 1}", "start": p["start"],
                  "size": p["size"]} for i, p in enumerate(plan["partitions"])]
        if mutate:
            mutate(parts)
        state = os.path.join(d, "state.json")
        with open(state, "w") as f:
            json.dump({"log": log, "parts": parts}, f)
        script = os.path.join(d, "restore.sh")
        with open(script, "w") as f:
            f.write(ar.recovery_script(plan))
        env = dict(os.environ, PATH=bindir + ":/usr/bin:/bin", FAKE_STATE=state, FAKE_LOG=log,
                   FAKE_PKG_SIZE=str(plan["installer"]["size"]))
        run = 'mount -t tmpfs none /Volumes && exec sh "$0" "$@"'
        if twice:  # first run's download fails; the second resumes in the same /Volumes
            run = ('mount -t tmpfs none /Volumes && touch "$FAKE_LOG.fail" && '
                   '{ sh "$0" "$@" < "$FAKE_LOG.answer"; echo "first-rc $?" >> "$FAKE_LOG"; } && '
                   'rm "$FAKE_LOG.fail" && exec sh "$0" "$@" < "$FAKE_LOG.answer"')
            with open(log + ".answer", "w") as f:
                f.write(answer + "\n")
        cmd = ["unshare", "-rm", "sh", "-c", run, script, *args]
        p = subprocess.run(cmd, input=answer + "\n", text=True, capture_output=True, env=env,
                           timeout=60)
        for name in os.listdir("/tmp"):
            if name == f"aurora-restore-{plan['digest']}.sh":
                os.unlink(os.path.join("/tmp", name))
        calls = []
        if os.path.exists(log):
            with open(log) as f:
                calls = f.read().splitlines()
        return p, calls

    def test_script_syntax(self):
        self.make()
        for mode in ("alongside", "replace"):
            with tempfile.NamedTemporaryFile("w", suffix=".sh") as f:
                f.write(ar.recovery_script(self.plan(mode)))
                f.flush()
                subprocess.run(["sh", "-n", f.name], check=True)

    def test_alongside_runs_exactly_the_planned_commands(self):
        self.make()
        plan = self.plan("alongside")
        p, calls = self.harness(plan, ar.phrase(plan))
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        changes = [c for c in calls if not c.startswith(("info ", "list "))]
        root = next(i for i, q in enumerate(plan["partitions"]) if q["uuid"] == plan["predecessor"]["uuid"])
        self.assertEqual(changes, [
            f"curl -fsIL --max-time 30 {plan['installer']['url']}",
            f"addPartition disk0s{root + 1} APFS macOS 27.2.1 {plan['containerBytes']}",
            f"curl -fL --retry 5 -C - -o /Volumes/macOS 27.2.1/.aurora-restore/InstallAssistant.pkg "
            f"{plan['installer']['url']}",
            "installer -pkg /Volumes/macOS 27.2.1/.aurora-restore/InstallAssistant.pkg "
            "-target /Volumes/macOS 27.2.1",
            "app-started ",
        ])

    def test_replace_deletes_exactly_the_listed_partitions(self):
        self.make()
        plan = self.plan("replace")
        p, calls = self.harness(plan, ar.phrase(plan))
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        ids = {q["uuid"]: f"disk0s{i + 1}" for i, q in enumerate(plan["partitions"])}
        erased = [c for c in calls if c.startswith("eraseVolume")]
        self.assertEqual(erased, [f"eraseVolume free none {ids[d['uuid']]}" for d in plan["delete"]])
        add = [c for c in calls if c.startswith("addPartition")]
        self.assertEqual(add, [f"addPartition {ids[plan['predecessor']['uuid']]} APFS macOS 27.2.1 "
                               f"{plan['containerBytes']}"])

    def test_check_mode_and_wrong_answer_change_nothing(self):
        self.make()
        plan = self.plan("replace")
        for args, answer, rc in (((("--check",)), "", 0), ((), "yes", 1)):
            p, calls = self.harness(plan, answer, args)
            self.assertEqual(p.returncode, rc, p.stdout + p.stderr)
            self.assertFalse([c for c in calls if c.startswith(("eraseVolume", "addPartition",
                                                                "installer", "curl -fL"))])

    def test_rerun_after_a_failed_download_resumes(self):
        self.make()
        for mode in ("alongside", "replace"):
            plan = self.plan(mode)
            p, calls = self.harness(plan, ar.phrase(plan), twice=True)
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            self.assertIn("first-rc 1", calls)
            self.assertEqual(len([c for c in calls if c.startswith("addPartition")]), 1)
            self.assertEqual(len([c for c in calls if c.startswith("eraseVolume")]),
                             len(plan["delete"]))
            self.assertIn("resuming", p.stdout)
            self.assertEqual(calls[-1], "app-started ")

    def test_unknown_argument_prints_usage(self):
        self.make()
        p, calls = self.harness(self.plan("alongside"), "", ("--bogus",))
        self.assertEqual(p.returncode, 2)
        self.assertEqual(p.stdout, "usage: restore.sh [--check | --unattended]\n")
        self.assertEqual(calls, [])

    def test_changed_disk_stops_before_any_change(self):
        self.make()
        plan = self.plan("replace")

        def moved(parts):
            parts[5]["size"] -= MIB

        def extra(parts):
            parts.append({"uuid": "X", "id": "disk0s42", "start": 1, "size": 1})

        for mutate, msg in ((moved, "changed size"), (extra, "partitions; the plan has")):
            p, calls = self.harness(plan, ar.phrase(plan), mutate=mutate)
            self.assertEqual(p.returncode, 1)
            self.assertIn(msg, p.stdout)
            self.assertFalse([c for c in calls if not c.startswith(("info ", "list "))])


class Cli(unittest.TestCase):
    def test_dfu_help_and_size(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(ar.main(["dfu-help"]), 0)
        self.assertIn("ERASES THE WHOLE DISK", out.getvalue())
        self.assertIn("REVIVE keeps your data", out.getvalue())
        self.assertEqual(ar.size_arg("80G"), 80 * GIB)
        self.assertEqual(ar.size_arg("1T"), 1 << 40)


if __name__ == "__main__":
    unittest.main()

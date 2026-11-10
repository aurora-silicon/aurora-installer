# Speaker tuning collection

Based on [aurora-audio-dsp](#attribution) by saku (MIT). The collection described here follows saku's `tools/macos-collector/collect-audio-tuning.sh`, and saku is the co-author of this specification and of the installer commits that implement it.

## Purpose

macOS protects and voices each Mac's internal speakers with tuning that belongs to that Mac: a per-model tuning folder and, on Macs with speaker calibration, a per-unit factory calibration record. The Linux speaker protection (speakerguardd v2) and the speaker graph read their parameters from these files, so that Linux uses the same limits macOS uses on the same machine.

The installer copies both, read-only, from the user's own running macOS into the per-machine vendor firmware on the ESP, next to the Wi-Fi, Bluetooth and camera firmware it already collects. Nothing is shipped: no installer package, release asset, repository or test fixture carries Apple tuning data. Tests use synthetic files.

## Inputs

| Input | Source | Present on |
|---|---|---|
| `acoustic-id` | device tree `/product/audio` (one audio node; a little-endian 32-bit word) | every Mac with built-in audio |
| tuning folder | `/System/Library/Audio/Tunings/AID<acoustic-id>/`, every regular file, recursively | every Mac with an `acoustic-id` |
| `speaker-thiele-small` | the same device-tree node, raw bytes | Macs with speaker calibration (MacBook Air and Pro); absent on Mac mini, iMac and Mac Studio |
| DSP database entry | `/System/Library/Audio/Tunings/AID<acoustic-id>/DSP/DSPDatabase.plist` (macOS 27, copied unchanged when it holds only the `AID<acoustic-id>` key) or, when that file is absent, the shared `/System/Library/Audio/Tunings/DeviceDSPDatabase.plist` (up to macOS 26, only the `AID<acoustic-id>` key, re-encoded as an XML property list with that one key) | required |
| shared files | files outside `AID<acoustic-id>/` that the entry's `Built-in Speaker` modes reference, under `/System/Library/Audio/Tunings/Common/` | only when referenced |
| loudness manager | `/System/Library/Audio/Tunings/DRC/loudness-manager.plist`, unchanged | only when its `Supported_Hardware` lists `AID<acoustic-id>` |
| volume configuration | `/System/Library/Audio/Tunings/Config/AID<acoustic-id>.plist`, unchanged | required |
| lsm2 masker lattice | `/System/Library/Components/AudioDSP.component/Contents/MacOS/AudioDSP`: the one table that passes the rule in [The lsm2 masker lattice](#the-lsm2-masker-lattice), 800 bytes | required |
| board | device tree root `target-type` (`J616s`, or `J616sAP`), lowercased without `AP`: `j616s`, the name the Linux device tree's first compatible carries | every Mac; optional |
| unit ID | device tree root `serial-number`, hashed (see [The unit](#the-unit)); the serial number itself is never stored | every Mac; optional |
| speaker ID (`spid`) | IORegistry service plane: `speakerID` of the one `AppleEmbeddedAudioDevice` whose `device UID` is `Speaker` | Macs whose speaker driver publishes it (the J616s does); optional |

The DSP database entry is the selection table. macOS 27 removed the shared `DeviceDSPDatabase.plist` and keeps each Mac's entry in its own folder as `AID<n>/DSP/DSPDatabase.plist`, with the same shape (one top-level key, `AID<n>`). The collector reads that file when it exists and the shared database otherwise, and writes the entry as `DeviceDSPDatabase.plist` in the bundle either way, so readers see one layout. A per-folder file that holds only the `AID<n>` key is copied byte for byte (macOS writes it as a binary property list); anything else is reduced to that key and re-encoded as XML, as for the shared database. Readers must accept both encodings. Apple's mode names are irregular (`48k - Movie- SSI` next to `48k - General - SSI`, and both `48k - Dictation` and `48k - Dictation ` with a trailing space), so readers must match keys exactly and never normalise them. The `GenericDSPDatabase.plist` (key `Generic`) is the fallback for devices without an entry and is not collected.

The `Path` values in the entry are relative to `Tunings/`. The speaker modes of every Apple silicon entry seen so far, on macOS 26 and 27, reference only their own `AID<n>/` folder. Headphone modes reference `Common/Graphs` and `Common/Strips`. The collector follows every `Path` under the `Built-in Speaker` device and collects the ones under `Common/` too, so a speaker graph that uses a shared strip still ships whole. Headphone and microphone references are not followed. A speaker reference outside `AID<n>/` and `Common/`, or one that is absolute, has `.` or `..` components, is a link or names a missing file, fails the collection.

The loudness manager (`DRC/loudness-manager.plist`) is not referenced by any graph. It lists, in `Supported_Hardware`, the AIDs whose output macOS runs through its dynamic range control, with the parameters under `Format`. It changes the speaker loudness on those Macs (the MacBook Neo, `AID44`, among them), so it is collected only when it lists this Mac's AID. A loudness manager that cannot be parsed fails the collection.

For each built-in speaker configuration (general, voice, movie and so on, per speaker vendor) it gives the graph, strip and property strip to use, and the underlying device properties that select among them. The volume configuration gives the speaker's output volume range and scalars. Both are needed to reproduce macOS's speaker graph and loudness.

The speaker ID selects among the speaker vendor variants in the DSP database entry. It is the HAL's `spid` property, which macOS reads from the IORegistry property `speakerID` of the built-in speaker device (`AppleEmbeddedAudioDevice`, `device UID` `Speaker`). The driver builds it from the speaker assembly's strap pins and publishes 65535 when the strap is not a valid ID. The native installer reads it through IOKit, read only, without opening any user client. The standalone Python collector reads the same property with `ioreg`. Exactly one `Speaker` service must carry it as an integer from 0 to 4294967295. Otherwise the ID is unknown, and an unknown ID never fails collection. The value is stored as reported, so 65535 is kept as 65535.

- The tuning folder is read from the sealed, read-only system volume, with the same protected-tree reader the installer uses for system Wi-Fi firmware.
- AppleDouble (`._*`) and `.DS_Store` sidecars are skipped. A link is kept only when it names a regular file inside the folder, and is stored as a copy of that file.
- A short read fails the whole collection: a directory that cannot be listed, a link to a directory, a link that does not resolve to a regular file inside the folder, a missing DSP database entry or volume configuration, or a speaker reference that cannot be collected. There is no partial bundle.
- A Mac without speaker calibration still gets its tuning folder. A Mac without an `acoustic-id`, or without a folder for it, gets nothing and installs normally.
- Collection never stops an installation. A failure, an ambiguous device tree (two audio nodes with an `acoustic-id`) or an implausible input leaves the tuning out entirely, never partly. Linux then uses its family fallback profiles. Cancellation still ends the step.
- Every Mac with a protection unit is covered the same way, because the whole folder is copied. On the MacBook Neo (`AID44`), the protection parameters (lsm2) live in the speaker strip's preset, not in a separate plist, so the strip is the parameter source. On the V/I MacBooks, spp3 also has a sidecar plist. No unit-specific selection happens at collection time.
- Bounds: at most 1024 files and 64 MiB for the folder, the shared files and the selection data together, 64 MiB for the DSP database read, 1 MiB each for the volume configuration and the loudness manager, and 4 KiB for the calibration record. The largest folder seen so far is 34 files and 2.4 MB.

## The unit

The `speaker-thiele-small` record is the factory calibration of one unit, not of the model. A bundle copied from another Mac of the same model passes every other check, and its resistances would seed the Linux closed loop of the wrong speakers: about 8 K of coil temperature error per 3 % of resistance error. So the manifest names the Mac the bundle was collected on, and Linux refuses the bundle on any other.

- `board` is the device tree root's `target-type` lowercased, with a trailing `AP` dropped: `J616s` gives `j616s`. It matches the first `compatible` of the Linux device tree (`apple,j616s`).
- `unit_id` is the SHA-256, as 64 lowercase hex digits, over the 23 bytes `aurora-speaker-unit-v1` and a NUL, followed by the device tree root's `serial-number` without its trailing NUL bytes. macOS has the property in the `IODeviceTree` root, padded to 32 bytes. aura copies the same ADT property into the Linux device tree root, with one NUL, where it reads as `/proc/device-tree/serial-number`. Both sides therefore hash the same bytes. A serial number that is empty, longer than 64 bytes, or holds anything but printable non-space ASCII gives no unit ID.
- Both are read only. An unreadable identity never fails the collection: the keys are then omitted (Swift) or `null` (Python), and Linux runs the speakers without the per-unit calibration until the tuning is collected again.
- On Linux, speakerguardd (`aurora-speaker-tuning compile`) refuses a bundle whose `board` is not this Mac's or whose `unit_id` is not that of this Mac's `serial-number`. No blob is compiled, and the speakers stay at the kernel's floor. A bundle without `unit_id` (collected before this field) compiles without its calibration, so every channel runs open loop at its base limit. The journal says to collect it again. `install-linux.sh` refuses another unit's bundle before touching the ESP, even with `--any-mac`.
- Domain separation keeps the hash from being a plain SHA-256 of a serial number. It is integrity binding, not a secret or a signature.

Test vector: the made-up serial `SYNTHETIC0A` gives `22fea1b624a25cb3e103ed668fc37e1ef5c0d445e195029caf273827923c793d`.

## The lsm2 masker lattice

The lsm2 protection unit (the MacBook Neo's) reduces a 640-point spectrum to 100 buckets and judges masking on them. The bucket edges are a table in macOS's AudioDSP component. No formula reproduces them, so the collector reads the table from the running macOS, like the rest of the tuning, and nothing ships it.

The table is found by its structure alone, with no offset, hash or symbol. For each Mach-O slice of the component (there are two on macOS 26 and three on macOS 27), the collector parses the load commands, takes the one `__TEXT,__const` section, and considers every naturally aligned address in it as the start of 100 little-endian unsigned 64-bit exclusive bucket ends. It accepts a candidate only when the ends:

- start with the 64 single-bin buckets, ends 1 to 64;
- increase strictly;
- all lie between 1 and 321 (the one-sided 640-point spectrum); and
- end at 321.

Each slice must hold exactly one accepted candidate, and all slices the same 800 bytes. No table, two tables, a malformed component, a missing component or slices that disagree fail the collection, which then leaves the whole tuning out (an error in the log). There is no fallback table. The collector is the same on every Mac, whatever its protection unit, so every bundle it writes has the lattice.

The table is stored unchanged as `lsm2-mask-lattice.bin`. The firmware rebuild and the Linux reader check it again with the same rule. Implementations: `asahi_firmware/lsm2_lattice.py` (Python; `python3 -m asahi_firmware.lsm2_lattice [component]` reports where it found the table and its SHA-256, never the values) and `NativeLSM2Lattice` (Swift).

## Outputs

The files go into the vendor firmware package (`vendorfw/firmware.tar`, `vendorfw/firmware.cpio` and its `manifest.txt` with SHA-256 per file), under `apple/audio-tuning/`. They also go into the raw fallback archive (`asahi/all_firmware.tar.gz`), under `audio-tuning/`:

```
apple/audio-tuning/
  manifest.json
  speaker-thiele-small.bin        (only when the Mac has one)
  AID<n>/ADM/config.plist
  AID<n>/DSP/Graphs/builtin_speaker_out.dspg
  AID<n>/DSP/Strips/builtin_speaker_out_general.austrip
  AID<n>/DSP/Strips/aid<n>-aufx-spp3-appl.plist
  AID<n>/...                       (every file of the folder, unchanged)
  DeviceDSPDatabase.plist          (this Mac's entry only)
  Config/AID<n>.plist
  Common/...                       (only files the speaker modes reference)
  DRC/loudness-manager.plist       (only when it lists AID<n>)
  lsm2-mask-lattice.bin            (the lsm2 masker lattice, 800 bytes)
```

On Linux the package is unpacked under `/lib/firmware/vendor/`, so the bundle is `/lib/firmware/vendor/apple/audio-tuning/`. The ESP copy in `vendorfw/firmware.tar` is the source of truth when that tree is absent. A firmware rebuild from the fallback archive (`asahi_firmware.update`) re-verifies every file against `manifest.json` before it repackages them; a changed file leaves the tuning out.

### `manifest.json`, schema 2

```json
{
  "schema": 2,
  "kind": "aurora-audio-tuning",
  "source_file_count": 34,
  "complete": true,
  "acoustic_id": 35,
  "aid": "AID35",
  "macos_build": "25G83",
  "speaker_thiele_small": {"path": "speaker-thiele-small.bin", "bytes": 138, "sha256": "…"},
  "device_dsp_database": "DeviceDSPDatabase.plist",
  "device_dsp_database_source": "AID35/DSP/DSPDatabase.plist",
  "config": "Config/AID35.plist",
  "shared_files": [{"path": "Common/Strips/example.austrip", "bytes": 512, "sha256": "…"}],
  "loudness_manager": null,
  "speaker_id": 3,
  "board": "j616s",
  "unit_id": "…",
  "lsm2_mask_lattice": {"path": "lsm2-mask-lattice.bin", "bytes": 800, "sha256": "…",
                        "version": 1, "format": "u64le-exclusive-ends", "entries": 100},
  "files": [{"path": "AID35/ADM/config.plist", "bytes": 1234, "sha256": "…"}],
  "based_on": "aurora-audio-dsp by saku (MIT)"
}
```

- `source_file_count` is the number of entries of the source `AID<n>` folder that were collected (regular files and links to them, sidecars excluded). It equals the number of `files` records whose path starts with `AID<n>/`.
- `complete` is `true`. Only a complete set is ever written: every entry of the folder and both selection files.
- `speaker_thiele_small` is `null` on Macs without calibration.
- `device_dsp_database` is `DeviceDSPDatabase.plist` and `config` is `Config/AID<n>.plist`. Both files are also listed in `files`.
- `device_dsp_database_source` says where the entry was read: `DeviceDSPDatabase.plist` (the shared database, up to macOS 26) or `AID<n>/DSP/DSPDatabase.plist` (macOS 27, which is then also listed in `files`). Missing or `null` means the shared database.
- `shared_files` lists, with size and SHA-256, the files under `Common/` that the speaker modes reference. It is empty on every Mac seen so far. `loudness_manager` is the record of `DRC/loudness-manager.plist` when that file lists this AID, else `null`. Both are kept out of `files` on purpose, so a schema 2 reader that does not know them still accepts the bundle (as it accepts `speaker_thiele_small`).
- These three keys are optional and do not change the schema version. A bundle written before them verifies as before. Readers that know them must refuse the bundle when `device_dsp_database_source` is any other value, when a `shared_files` path is not under `Common/`, repeats or collides with `files`, when `loudness_manager` names another path or does not list this AID, or when the speaker modes in `DeviceDSPDatabase.plist` reference a file that is not in the bundle or `shared_files` differs from their `Common/` references.
- `speaker_id` is the speaker ID (`spid`) as an integer from 0 to 4294967295, kept exactly as macOS reports it (65535 means an invalid strap). It is omitted or `null` when unknown. Readers accept it missing, `null`, or such an integer, and refuse the bundle for any other value (boolean, fraction, negative, string). It does not change the schema version.
- `lsm2_mask_lattice` is the record of the lsm2 masker lattice: path `lsm2-mask-lattice.bin`, 800 bytes, `version` 1, `format` `u64le-exclusive-ends` (100 little-endian unsigned 64-bit exclusive bucket ends), `entries` 100. It is kept out of `files`. Every bundle the collector writes has it; it is optional for readers, so bundles collected before it still verify (the firmware rebuild logs a warning, and lsm2 then gives no masking credit). Readers that know it must refuse the bundle when the record has any other path, size, version, format or entry count, and must refuse the table when it fails the rule above.
- `board` and `unit_id` name the Mac the bundle was collected on ([The unit](#the-unit)). Both are optional and do not change the schema version. They are omitted or `null` when unknown. Readers that know them must refuse the bundle when `board` is not 1 to 8 lowercase letters and digits, or `unit_id` is not 64 lowercase hex digits.
- `macos_build` is the running macOS build the folder was read from. A later macOS update can change the tuning, and re-running the firmware step collects the new set.
- Paths are relative to the manifest's directory. Readers must reject absolute paths, `.` or `..` components, and any file whose size or SHA-256 differs from the manifest.
- Readers must also refuse the bundle unless: `schema` is 2; `complete` is `true`; `aid` is `"AID"` followed by `acoustic_id`; `device_dsp_database` and `config` hold the names above and both are listed in `files`; every `files` path is under `AID<n>/` or is one of those two names, with no duplicates; `source_file_count` equals the number of `AID<n>/` records; each file is a regular file reached without links; and the file and byte bounds above hold. Schema 1 bundles cannot show completeness and are refused.

The bundle is a superset of the one saku's collector writes (`audio-tuning-AID<n>/` with `AID<n>/`, `speaker-thiele-small.bin` and `metadata.json`), and the Linux reader accepts both layouts.

## Implementations

- Native installer (Swift): `NativeAudioTuningInputs`, called from `NativeVendorFirmware` as the `vendor_audio_tuning` phase. It reads both layouts the same way as the Python collector: `AID<n>/DSP/DSPDatabase.plist` when the folder has it (kept byte for byte when it holds only `AID<n>`), the shared database otherwise, and it writes the same `device_dsp_database_source`, `shared_files`, `loudness_manager` and `lsm2_mask_lattice` records. It omits `loudness_manager` instead of writing null, as it does for `speaker_id`.
- Standalone Python collector and firmware rebuild: `asahi_firmware/audio_tuning.py` (`AudioTuningFWCollection`), used by `tools/speaker-tuning/` and `asahi_firmware/update.py`.
- Linux reader and validator: `aurora-speaker-tuning` in aurora-silicon/speakerguardd (v2 branch). It loads the bundle from `/lib/firmware/vendor/apple/audio-tuning/`, from the ESP's `vendorfw/firmware.tar`, or from saku's collector bundle. It verifies the manifest, parses binary and XML property lists, and exposes the protection parameter sets and the speaker graph and strip definitions.

## Existing installs

A system installed before the installer collected speaker tuning can get it without reinstalling. `tools/speaker-tuning/collect-macos.sh` runs on the Mac's own macOS with the system Python and writes the bundle to a tarball. `tools/speaker-tuning/install-linux.sh` runs on the installed Linux system, re-verifies the bundle, adds it to `asahi/all_firmware.tar.gz`, rebuilds `vendorfw/` with `asahi_firmware.update`, refuses unless the rebuild keeps every other file of the old package by path and hash, backs both up and swaps them in atomically. See [tools/speaker-tuning/README.md](../../tools/speaker-tuning/README.md).

## Privacy

The installer reads `acoustic-id` and `speaker-thiele-small` from the device tree's audio node, `target-type` and `serial-number` from its root, and only the selected tuning folder. The serial number is reduced to the unit ID at once: it is never written, logged or stored, in the bundle or anywhere else. The calibration record is factory measurement data (driver resistance and calibration temperature per speaker). It stays on the user's machine, like the other factory calibration the installer already stores.

## Attribution

The approach, the device-tree properties used, the folder layout and the bundle format come from aurora-audio-dsp by saku, released under the MIT license:

```
MIT License

Copyright (c) 2026 saku

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

# J614s Wi-Fi firmware investigation

Compared the M4RCH vendored installer, its Aurora base `704f585`, and Aurora
main `b0aaf0b04a620f67a2abdb322b9b4895a202c69f` on 2 November 2026.
[Aurora PR #84](https://github.com/aurora-silicon/aurora-installer/pull/84)
already enables J614s installations with a Stage 1 warning; the older
experimental-admission work does not need another J614s submission.

The [installer fork](https://github.com/mchalunderscore/aurora-installer)
has `codex/j614s-mriya-firmware` and `j614s/full` branches with an experimental
BCM4388 C2 Mriya extraction candidate. Aurora and Asahi exclude the whole C2
directory. The Python conversion tests pass on Linux; macOS Swift checks have
not completed. The first installation required firmware from the machine's
macOS volume.

On 2 November 2026 the actual Apple 26.6.2 `25G83` Recovery image selected by
Aurora for J614s and the 27.0 `26A428` Recovery image were decrypted and
inspected read-only. Both contain `mriya-PlatformConfig.plist` but no Mriya
radio firmware under `usr/share/firmware/wifi`; their C2 directory contains
only Aruba radio firmware. The current candidate therefore does **not** fix a
fresh install using either Recovery image. Recovery C2 files for Aruba show
underscore-separated dimensions and variant names, so the candidate was
adjusted to accept analogous Mriya names, but actual raw Mriya filenames
remain unverified. A source containing those files and a fresh-install test
are needed before treating this as a complete fix or submitting it as one.

The old local installer also checked that J614s is paired with T6040 and
required its specific Stage 2 at runtime. Upstream checks supported boards
and chips independently, and its release payload assembler requires a J614s
Stage 2. The local checks could provide additional validation but have not
been shown necessary with a correctly assembled Aurora release. They are not
included in the firmware candidate.

The manual repair obtained working Mriya firmware from the running Mac's
`/usr/share/firmware/wifi/C-4388__s-C2` directory. Its raw filenames were not
retained. Further investigation on macOS can inspect that directory and its
aliases without publishing the firmware or machine-specific calibration.
Aurora's Neo support already reads some Wi-Fi regulatory tables from the
running macOS system, but verifies them against pinned hashes; its normal
Broadcom radio extraction currently uses the Recovery image.

The initial installation used unencrypted Btrfs; conversion after interruption
was not qualified. A successful boot on the current system does not qualify a
new installer or its disk, firmware, or recovery workflows.

## Proposed upstream PR

**Title:** firmware: extract BCM4388 C2 Mriya Wi-Fi files

The firmware converters currently skip the entire BCM4388 C2 directory because
an older Recovery image carried broken data. This also omits Mriya files needed
by J614s when a source does include them. Admit Mriya files when the expected
firmware types are present and nonempty, while retaining the exclusion for
other C2 families. Firmware source selection is unchanged.

The J614s machine's Wi-Fi worked after its firmware was provisioned from its
macOS installation. The 26.6.2 and 27.0 Recovery images contain no Mriya radio
files, so this candidate cannot fix those installs. The source filenames and
antenna variants still need verification against a source that contains them;
the type check alone does not establish that firmware is usable. Python
conversion and portable installer checks were run on Linux; macOS Swift
formatting, Debug and Release tests and packaging checks remain outstanding.

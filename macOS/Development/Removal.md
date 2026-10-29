# Erasing an existing Linux installation

Use **Erase Linux…** on the already-installed screen, or **Installation → Erase Linux…**, while no installation or download is running. One compact review lists every erased and retained partition, startup-disk changes, returned capacity and notes. Continue opens a separate approval page with the confirmation phrase and administrator account; Back returns to the review and clears the entered approval. The exact phrase is `erase linux and its data`, followed by a macOS administrator account and password. There is no Return-key shortcut for the destructive button.

Removal uses the signed privileged helper directly. It does not download an OS, engine, IPSW or catalog. The helper owns a five-minute, single-use plan; the client sends an opaque ticket, never disk identifiers or commands. Cancellation performs no disk mutation. Credentials are not written to the removal journal.

## Supported layout

The booted internal macOS physical store must precede one complete installation: an APFS startup container (2.3–2.7 GB or 5.8–6.2 GB, exactly one System/Data volume group and Preboot/Recovery), EFI, then up to two Linux partitions. These installation members must be adjacent within the alignment allowance. Apple ISC must precede macOS and Apple Recovery must be last. Files on the primary startup container and EFI must independently prove the same volume group, ESP and exact installer-created partition set.

Independent standalone startup containers after that group are retained and shown in the review. macOS grows only to the first retained container, including any adjacent unallocated space. The same boundary applies to reclaiming free space after deletion. A second complete installation with its own ESP, foreign partitions, full additional macOS systems, partial installations, external boot, multiple APFS physical stores, mismatched identities and explicitly unsupported `apple,j614s` remain refused.

The helper validates disk/partition/container/volume identities before the first
write and after each operation. It deletes the startup container without a
replacement name (modern diskutil also deletes its physical-store partition),
then erases EFI/boot/root by GPT partition UUID. It grows the bound macOS store
with `diskutil apfs resizeContainer <macOS-store-UUID> 0`. Success requires the
expected size increase and unchanged Apple ISC, macOS identities and Recovery.

Apple's local `diskutil(8)` documentation was checked for deleteContainer,
resizeContainer and UUID device addressing. No force-delete fallback is used.

## Interrupted removal

The root-owned helper directory contains `removal-<ticket UUID>.json`. The plan
and next phase are written atomically, and the file and containing directory are
synchronized before each mutation. A journal not marked `complete` prevents new
installation/removal requests, including after a helper restart. Never delete or
mark that journal complete merely to bypass the block: reconcile its approved
UUIDs with the actual disk layout first. A failed resize can leave all Aurora
partitions removed with the space still unallocated. Do not replay deletion.

Connection loss locks the app's further disk actions; it does not claim that the
helper stopped or that no writes occurred. A successful removal refreshes the
installer's inspection so an old installation plan cannot be reused.

Install journals are named by the plan's binding digest, and removal restores the layout that plan was made from. A successful removal therefore moves `execution-journals` to `retired-execution-journals/<removal ticket>` in the helper directory; otherwise a reinstall at the same size would find its earlier journal complete and report success without writing anything. A failed removal keeps them in place.

## Verification and simulator

In a debug `--simulate` run, choose the same menu action and use **Removal test**
inside the popup. Cases: complete removal, no installation, unfamiliar/partial
layout, helper unavailable, incorrect password, changed disk, deletion
interrupted, macOS resize failed and connection lost. The exact phrase is still
required. Simulation uses no helper, disks, passwords or downloads. A simulation
blocked by an uncertain outcome has a separate **Reset simulation** action.

`AuroraRemovalTests` exercises the real planner/executor with in-memory disk
operations, native plist parsing, every failed command position, journal failure,
protected identity drift, no-op growth, administrator rejection, exact phrase,
foreign/replayed tickets, interrupted-helper restart and concurrent install/removal
rejection. The running UI was checked for disabled near-match confirmation,
enabled exact confirmation, success and light/dark appearance.

Physical removal has not been executed for this feature. The M1 Thunderbolt route
was unavailable during development. Before a physical test, deploy both the new
app and helper, check the current disk layout and obtain explicit authorization
for that removal run. Keep the app closed when preparing the M1 for manual use.

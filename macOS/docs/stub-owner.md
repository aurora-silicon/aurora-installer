# Stub owner: Aurora's first admin owns the Mac (design)

Status: design, nothing implemented. The path we can build first uses an existing owner of the Mac (flow A). Making the first Aurora admin the owner with no macOS present is a **hypothesis**: the steps it needs are listed under "Not proven yet" and none of them has been shown to work on a new, ownerless group.

## Goal

When someone installs Aurora, the first Aurora admin becomes an owner of the Aurora stub volume group, and so can change that group's boot policy. Later admins can be added and removed. In the end nothing should depend on a macOS install being present, so a Mac with macOS fully removed still has an owner who can change boot security.

## What an owner is on these Macs

From Apple's public documents (see Sources):

- Each volume group has owners. On a Mac with Apple silicon, changing a group's boot security policy (its LocalPolicy) needs the authorization of one of its owners, given with that owner's password. [1]
- An owner is a user with a secure token: their password wraps a key-encryption key stored in the volume's keybag, and only the Secure Enclave can use it. The first user created on a new install normally gets the first secure token, and later users get one only through an existing token holder. [1][2]
- Lowering security below Full Security and allowing a custom kernel are only allowed from the group's own paired recoveryOS (1TR). [1]

From our own measurements (our Macs, our tools; the raw captures stay private because they contain device nonces and policies):

- macOS's `bless` and `bputil` reach the Secure Enclave's boot-policy service with an authorization obtained by checking the owner's password against records the system reads from disk. The same two records are used in separate sessions, and the enclave never hands them back. So they are persistent per-owner records, not session values.
- Asked from normal macOS, the enclave created a group's Full Security policy pair under that authorization. It refused a Permissive policy with a boot-mode error, and the following reset worked. `kmutil configure-boot` refused before reaching the enclave ("must be run from macOS Recovery").
- On the internal SSD the container keybag is wrapped by an enclave-held media key. A plain keybag decrypt with the container UUID, as in the published APFS format [3], does not work there. Linux can reach the owner records only through the enclave, which our Linux SEP driver can already talk to.
- Recovery lists admins from `Preboot/<group>/var/db/AdminUserRecoveryInfo.plist` (one entry per account).

## Target state of an Aurora stub

1. The stub's Data volume is keybagged and encrypted at rest, as a group made by macOS is.
2. At least one Aurora admin holds a secure token for that volume.
3. `AdminUserRecoveryInfo.plist` in the stub's Preboot lists exactly the token holders.
4. The stub's LocalPolicy pair exists and was created under an owner's authorization.

## Flows

### A. Install with an existing owner (the first path to build)

1. Linux creates the stub group and stages its files and boot objects.
2. The user types the password of an existing owner of the Mac: the macOS admin, or the owner of an existing Aurora stub.
3. Linux creates the Full Security policy pair for the new group under that owner's authorization. The other groups' policies are re-signed in the same transaction, and nothing is committed until every new file is safely on disk.
4. The user boots the new stub's own Recovery once, as that owner, and runs step 2 (`bputil` to lower security, `kmutil` to install Stage 1), as with the Asahi and current Aurora installers.

Step 1 is demonstrated: a Linux-made 27.2 stub group is staged on a lab Mac and stays hidden. Step 3 exists as request builders checked byte for byte against our captures, but has not been sent to a real Mac. Step 4 is the same step 2 today's installers use, but it has not yet been run on a Linux-made stub.

### B. First Aurora admin becomes the owner (hypothesis)

The intended flow: the installer asks for the first admin's name and password before it creates the policy, makes that account a token holder on the new stub's Data volume, publishes the owner record, and then runs A.3 with that admin's authorization instead of an existing owner's. Nothing here is proven. See "Not proven yet".

### C. Add, remove, change password (an `aurora-owner` tool)

- Every change needs an existing owner's authorization.
- Being in `wheel` on Linux does not make anyone an owner. Owner status is granted explicitly.
- Remove refuses to remove the last owner (see below).

### D. Boot-policy changes from Linux

Stub create or upgrade, and re-signing after another group changes: these follow A.3 with the authorization of any current owner.

### E. Recovery

The owner signs in with the same password, and `bputil` and `kmutil` work as today.

## Partial writes and the last owner

An owner exists in two places that must agree: the keybag entry (what the enclave checks) and the Preboot owner record (what Recovery shows). Any change that touches both must be safe if it stops halfway.

- **Order.** Change the keybag first, then the Preboot record. A keybag change that succeeded with a stale record still lets the owner authenticate. A record without a keybag entry would show an owner who cannot sign in.
- **Password change.** Keep the old wrapped entry until the new one has been verified: authenticate with the new password through the enclave, then remove the old entry, then rewrite the record. If any step fails, the old password keeps working and the tool says which step failed.
- **Verification after every change.** Re-read both places and require: every listed owner authenticates through the enclave, and every keybag owner is listed. On a mismatch, stop and report. Never "repair" by deleting entries.
- **Last owner.** Never remove or replace the last entry that authenticates. Before any removal, prove that at least one other owner authenticates with its current password. A password change counts as removal of the old entry, so the new entry must authenticate first.
- **First-owner publication (flow B).** The new group stays hidden from the boot picker until it is complete: owner entry, matching record and policy pair all verified. A group without a policy makes the picker restart the Mac today. If publication fails, the group stays hidden and is removed, and the Mac's existing groups are untouched.

## Not proven yet (blocks flow B)

1. How a user gets the first secure token on a new group that has no owner and no policy yet. On a fresh macOS install this happens in Setup Assistant on the first boot. We have not observed it.
2. Whether such a group can take its first owner before its first LocalPolicy exists, or whether it always needs an existing owner of the Mac (flow A).
3. Writing the volume keybag from Linux under the enclave-wrapped container keybag.
4. The parameters of the password verifier in the owner record.
5. Whether the boot picker accepts a Linux-made group that is keybagged and has its policy.

## Sources

1. Apple Platform Security Guide: "Boot process for a Mac with Apple silicon", "Startup Disk security policy control for a Mac with Apple silicon", "LocalPolicy signing-key creation and management". https://support.apple.com/guide/security/welcome/web
2. Apple Platform Deployment: "Use secure token, bootstrap token, and volume ownership in deployments". https://support.apple.com/guide/deployment/use-secure-and-bootstrap-tokens-dep24dbdcf9e/web
3. Apple File System Reference, chapter "Encryption" (keybag layout, container and volume keybags). https://developer.apple.com/support/downloads/Apple-File-System-Reference.pdf

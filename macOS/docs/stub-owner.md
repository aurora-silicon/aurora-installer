# Stub owner: Aurora's first admin owns the Mac (design)

Status: design, nothing implemented. It replaces "the macOS admin approves the stub in Recovery" with an owner that
exists without macOS.

## Goal

When someone installs Aurora, the first Aurora admin becomes the owner of the Aurora stub volume group, and so of
the Mac's boot policy for that group. Later admins can be added and removed. Nothing depends on a macOS install
being present, so a Mac with macOS fully removed still has an owner who can change boot security.

## What an owner is on these Macs

Measured on our own Macs (macOS guest traces of `bless`, `bputil` and `diskutil`, and the stub's own Preboot):

- A volume group's owners are the users who hold a wrapped key-encryption key (KEK) in that group's Data-volume
  keybag. Only the Secure Enclave can unwrap it, and only with the user's password.
- Recovery lists owners from `Preboot/<group>/var/db/AdminUserRecoveryInfo.plist`. Each record has a user UUID, a
  real name and an authentication-authority list: a password verifier, a "secure token" marker and a Kerberos realm.
- Changing a group's boot policy (creating or re-signing its LocalPolicy) needs an owner authorization context. The
  enclave's credential service creates a 16-byte context. One keystore request with the owner's password and their
  wrapped keys binds the context to that owner. The boot-policy requests then carry the context.
- From a normal OS (macOS or Linux) the enclave creates a group's Full Security policy pair. Lowering security and
  installing a custom kernel (our Stage 1) are refused outside Recovery. This step 2 stays in the stub's own Recovery.

## Target state of an Aurora stub

1. The stub's Data volume is keybagged and encrypted at rest, as a group made by macOS is.
2. The first Aurora admin holds a KEK in that keybag.
3. `AdminUserRecoveryInfo.plist` in the stub's Preboot lists that admin. Its user UUID matches the KEK, and its
   password verifier is made from the same password.
4. The stub's LocalPolicy pair was created under that owner's context.

## Flows

- **Install (no macOS needed).** The installer asks for the first admin's name and password before it creates the
  stub's policy. That account becomes both the first Aurora user and the stub owner. The installer then enrolls the
  owner, creates the Full Security policy pair under the owner's context, and the user finishes step 2 once in the
  new stub's Recovery as that owner.
- **Enroll.** The enclave creates the user's KEK for the stub Data volume, wrapped by the password. The installer
  stores it in the volume keybag and writes the owner record.
- **Add, remove, change password** (an `aurora-owner` tool). Every change needs an existing owner's authorization.
  Remove refuses the last owner. A password change rewraps the KEK and rewrites the verifier. Being in `wheel` on
  Linux does not make anyone an owner on its own; enrollment is an explicit step.
- **Boot-policy changes from Linux** (stub create or upgrade, re-signing after another group changes). These use the
  credential context, the password bind and then the boot-policy requests.
- **Recovery.** The owner signs in with the same password, and `bputil`/`kmutil` work as today.

## Open items before any implementation

1. The keystore request that creates a user's KEK for a volume, and the format of the keybag entry it returns.
2. The keystore requests made while a keybagged group is created.
3. Writing the volume keybag from Linux under the enclave-wrapped container keybag.
4. The parameters of the password verifier.
5. Whether the boot picker accepts a group that is keybagged and has its policy. A group without a policy makes the
   picker restart the Mac today, so new groups stay hidden until they are complete.

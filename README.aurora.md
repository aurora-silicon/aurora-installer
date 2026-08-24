# Aurora installer design note

The active Aurora-specific scope, storage invariants, and replaceable stage-2
contract are documented in [README.md](README.md).

The Windows option stages and verifies Microsoft media plus a user-supplied,
cataloged AIC HAL-extension/driver tree, then creates an automated WinPE
deployment on installer-created partitions. No private drivers are part of the
public installer. The current stage-2 payload remains m1n1 proxy from
`Aurora-Silicon/m1n1@main`; Mu is launched through the existing tethered
hypervisor workflow until a resident autonomous Mu loader is available.

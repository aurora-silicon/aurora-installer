# Aurora installer design note

The active Aurora-specific scope, storage invariants, and replaceable stage-2
contract are documented in [README.md](README.md).

The Windows option stages and verifies Microsoft media, Aurora drivers, and an
automated WinPE deployment on installer-created partitions. The current stage-2
payload remains m1n1 proxy; Mu is launched through the existing tethered
hypervisor workflow until a resident autonomous Mu loader is available.

# Stage 1 key block fixtures

Written by aura's `tools/secboot_sign.py` (aura bb45ca3b). `Tests/Stage1KeysCheck.swift` checks that the installer fills the same bytes.

- `stage1-unfilled.bin`: a placeholder Stage 1 the way aura's `tests/python/test_secboot_sign.py` builds one: `head`, an empty `AURORA-S1-KEY01` block (version 1), `STACKBOT`.
- `aurora-lab-20261111.pub`: the public half of Aurora's lab Stage 2 key (key id ac020765a9ed5164).
- `owner-test.key`, `owner-test.pub`: a test-only owner key. The seed is SHA-256 of `aurora-installer Stage1KeyBlock test owner key`; the public key is `secboot_sign.pubkey(seed)` (key id 8f73cefd62612f1f).
- The filled images:

```
secboot_sign.py fill-keys --pub aurora-lab-20261111.pub --min-secver 1 stage1-unfilled.bin stage1-aurora.bin
secboot_sign.py fill-keys --pub owner-test.pub --min-secver 1 stage1-unfilled.bin stage1-owner.bin
secboot_sign.py fill-keys --pub aurora-lab-20261111.pub --pub owner-test.pub --min-secver 1 stage1-unfilled.bin stage1-both.bin
secboot_sign.py fill-keys --pub owner-test.pub --pub aurora-lab-20261111.pub --pub owner-test.pub --pub aurora-lab-20261111.pub --min-secver 7 --enforce stage1-unfilled.bin stage1-four-enforce.bin
```

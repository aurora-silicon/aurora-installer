# Touch ID keyboard host certificate chain for an existing install

A Magic Keyboard with Touch ID pairs only after the host sends it this Mac's attestation certificate chain: a leaf bound to the Mac's Secure Enclave and its intermediate, two DER certificates of about 1.6 KB together. The kernel loads it as the firmware file `apple/stac-host-chain.der`.

New installs collect the chain from the macOS Hardware volume at install time and put it in this Mac's vendor firmware package on the ESP (see [the installer firmware inputs](../../macOS/docs/FIRMWARE-INPUTS.md)). This tool is for a system installed before that. It reads the chain from Linux, from the same Mac's internal disk, without booting macOS.

```sh
sudo python3 -I tools/stac-host-chain/stac_host_chain.py --check
sudo python3 -I tools/stac-host-chain/stac_host_chain.py
```

Run it from a checkout of this repository; it uses the repository's `asahi_firmware` (read only) and only the Python standard library.

## What it does

1. Opens the internal disk (`/dev/nvme0n1`, or `--disk DEV`) with `O_RDONLY` and finds the iBoot System Container partition in its GPT, by its partition type GUID (`69646961-6700-11AA-AA11-00306543ECAC`) or its name (`iBootSystemContainer`). `--device DEV` reads a given partition or an image of it instead.
2. Reads that partition as raw bytes, in 4 MiB chunks that overlap by 128 KiB, and looks for the chain by content: raw DER and base64 (PEM, or a property list's `<data>`). Lengths are parsed with strict DER bounds. Only a leaf with CN = 64 lowercase hex digits, OU `BAA Certification`, O `Apple Inc.` and issuer `Basic Attestation User Sub CA2`, and an intermediate `Basic Attestation User Sub CA2` issued by `Basic Attestation User Root CA`, are accepted. Validity dates are not checked; the leaf is normally expired.
3. Writes the leaf followed by the intermediate to `/lib/firmware/vendor/apple/stac-host-chain.der` (the first of `/lib/firmware/vendor/apple` and `/run/aurora-firmware/vendorfw/apple` that exists, as in `tools/speaker-tuning`), or to `-o FILE`. The file is written atomically, mode 0644, owned by root when run as root. An existing file with the same chain is left alone; a different one is kept unless `--force` is given.

`--check` finds the chain and writes nothing.

The disk is never mounted and never written. The tool does not parse APFS: APFS is copy-on-write, so earlier copies of the certificate can still be in free blocks. Copies whose leaves name the same enclave key (the same CN) are re-issues of one Mac's certificate, and the one with the latest notBefore is written. Leaves for different keys are refused.

The kernel checks that the leaf's CN is the SHA-256 of this Mac's enclave host key before it sends the chain to a keyboard, so a chain from another Mac is never used.

## Exit status

| Status | Meaning |
| --- | --- |
| 0 | Written, already present, or found with `--check` |
| 1 | Error: no single container partition, several different chains, or the output could not be written |
| 2 | No chain on this Mac (it never had one, for example because no such keyboard was ever paired under macOS) |

## Where the file lives

`/lib/firmware/vendor` is unpacked from the ESP's vendor firmware package when the system boots, so a file written there lasts until the package is unpacked again. For a lasting copy, reinstall the vendor firmware from a package that holds the chain, or run this tool again after boot. The chain is per-machine Apple-issued data: keep it on this Mac only, and do not post it or attach it to bug reports.

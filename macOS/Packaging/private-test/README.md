# Omarchy private M3 test

This is an experimental private tester build, not a public release. The installer app and helper have ad-hoc signatures tied to their exact binaries. The package has no Apple Developer ID signature or notarization, so macOS will ask you to approve it explicitly.

The image installed and booted on a 13-inch M3 Air. The 16-inch M3 Pro is included for its first physical test; its peripherals and first boot are not yet validated. The included system uses the tested Asahi kernel, GRUB, software rendering and **no Linux disk encryption**. It does not include the later Aurora experiment or encryption/Limine work. Back up the Mac before installing.

## 1. Download, extract and check

Download the ZIP and its separately supplied SHA-256 checksum. In Terminal, run `shasum -a 256` on the ZIP and compare the result with that checksum. Double-click the ZIP to extract it completely.

Open Terminal, type `cd `, drag the extracted folder into the window, and press Return. Then run:

```bash
bash Preflight.command
```

This verifies the bundle checksums and checks the Mac model, macOS version and existing installer files. It does not install anything or change partitions. macOS 15 or later is required. If it reports existing installer/helper files or an unsupported model, stop and send the exact result to Scott. If another Linux installation is already present, tell Scott before proceeding; do not use an old removal script.

Keep the extracted folder available until installation finishes. Allow space for the extracted image and another staging copy, in addition to the Linux size shown in the app. The preflight reports the current free space.

## 2. Stage the image

In the same Terminal window, run:

```bash
bash "Stage assets.command"
```

Wait for the message that all three assets were verified and staged. This copies only the bundled image, metadata and engine into your private user cache. Run it as your normal user, without sudo. The installer can still need Internet access for Apple's firmware/recovery downloads.

## 3. Install the helper package

Double-click `Omarchy-M3-Private-Test.pkg`. If macOS blocks it because the developer cannot be verified, open **System Settings → Privacy & Security**, scroll to **Open Anyway**, and approve this specific package. Retry opening it if necessary. Apple's instructions are at https://support.apple.com/en-us/102445.

The macOS Installer asks for administrator approval. The package installs the app in Applications and registers its privileged helper. It does not start a Linux installation or open the app automatically. Do not disable Gatekeeper, remove quarantine with a command, or bypass a model rejection. If macOS reports malware, damage, a failed signature, or does not offer Open Anyway, stop and report the exact message.

## 4. Open the app and review the plan

Open **Omarchy Installer** from Applications. If macOS blocks the app too, use the same per-item **Open Anyway** process for the app. This package's Gatekeeper approval and helper installation are part of the private test; their end-to-end behavior on a downloaded copy has not yet been physically validated.

Check the model, available space and proposed Linux size. The app must say that this private test installs Linux **without disk encryption**. Keep the default Asahi image; this build does not offer a channel switch. If the helper cannot be reached or any check fails, stop and send Scott the exact error instead of using sudo or an older installer.

Choosing **Install** and confirming the requested authorization begins disk changes. Review the plan before doing so. Follow the app's Recovery handoff and startup instructions. Do not repeat a failed disk-operation step just to reproduce an error.

## 5. Report the result

Use `Feedback.md`. First boot, Wi-Fi, display responsiveness, audio, explicit microphone selection, lid suspend/resume and a second normal boot are the initial checks. GPU acceleration, camera, Bluetooth, external displays, encryption and snapshots are not qualified by this image. Omit passwords, recovery keys and serial numbers from feedback.

This package refuses to replace an existing installer/helper. Ask Scott before installing a later installer version or removing the helper; this private build installs it under `/Library/PrivilegedHelperTools`.

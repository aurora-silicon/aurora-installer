#!/bin/bash
# Pure Recovery fixtures; never enroll a boot object or change a live account.
set -euo pipefail
cd "$(dirname "$0")"
[[ $(uname -s) == Darwin ]] || { echo 'Recovery Swift/AppKit checks require macOS' >&2; exit 1; }
out="${1:?test output directory}"
mkdir -p "$out"
xcrun clang -Wall -Wextra -Werror Tests/AuthorizationCheck.c -o "$out/authorization-check"
"$out/authorization-check"
compile_run() {
  local name=$1
  shift
  xcrun swiftc "$@" -o "$out/$name"
  "$out/$name"
}
compile_run enrollment Sources/EnrollmentGate.swift Tests/EnrollmentGateCheck.swift
compile_run digest Sources/Account/RecoveryDigest.swift Tests/RecoveryDigestCheck.swift
compile_run owner Sources/RecoveryOwner.swift Sources/Account/AuraStage1.swift Sources/Account/RecoveryDigest.swift Sources/Stage1Reenrollment.swift Sources/BootSelection.swift Tests/RecoveryOwnerCheck.swift
compile_run bootstrap-owner Sources/RecoveryOwner.swift Sources/Account/AuraStage1.swift Sources/Account/RecoveryDigest.swift Sources/Stage1Reenrollment.swift Sources/BootSelection.swift Tests/BootstrapOwnerCheck.swift
compile_run boot-selection Sources/Account/AuraStage1.swift Sources/BootSelection.swift Tests/BootSelectionCheck.swift
compile_run macho-boot-object Sources/Account/AuraStage1.swift Tests/MachOBootObjectCheck.swift
compile_run stage1-keys Sources/Account/AuraStage1.swift Sources/Account/Ed25519.swift Sources/Account/StartupKeys.swift Tests/Stage1KeysCheck.swift
compile_run stage1-reenrollment Sources/Account/AuraStage1.swift Sources/Account/RecoveryDigest.swift Sources/BootSelection.swift Sources/Stage1Reenrollment.swift Tests/Stage1ReenrollmentCheck.swift
xcrun swiftc Sources/Account/AuraStage1.swift Tools/ExecuteWindowTool.swift -o "$out/aura-execute-window"
"$out/aura-execute-window" --help >/dev/null
compile_run installer-log Sources/InstallerLog.swift Tests/InstallerLogCheck.swift
compile_run command-log Sources/InstallerLog.swift Tests/CommandLogCheck.swift
compile_run log-view Sources/InstallerTheme.swift Sources/LogTextView.swift Tests/LogTextViewCheck.swift
compile_run sheet-presenter Sources/SheetPresenter.swift Tests/SheetPresenterCheck.swift
compile_run primary-action Sources/RecoveryPrimaryAction.swift Sources/RecoveryAccountForm.swift Tests/RecoveryPrimaryActionCheck.swift
compile_run busy-action Sources/InstallerTheme.swift Sources/RecoveryTheme.swift Sources/RecoveryPrimaryAction.swift Sources/RecoveryBusyAction.swift Sources/RecoverySheet.swift Tests/RecoveryBusyActionCheck.swift
compile_run log-menu Sources/RecoveryLogMenu.swift Tests/RecoveryLogMenuCheck.swift
compile_run configuration Sources/RecoveryOwner.swift Sources/Account/RecoveryDigest.swift Sources/Stage1Reenrollment.swift Sources/BootSelection.swift Sources/Account/AuraStage1.swift Sources/Account/Ed25519.swift Sources/Account/StartupKeys.swift Sources/InstallConfiguration.swift Tests/InstallConfigurationCheck.swift
compile_run file-transaction Sources/Account/RecoveryDigest.swift Sources/Account/RecoveryFileTransaction.swift Tests/RecoveryFileTransactionCheck.swift
compile_run installation-journal Sources/RecoveryInstallationJournal.swift Tests/RecoveryInstallationJournalCheck.swift
compile_run account-restart Sources/RecoveryAccountRestart.swift Tests/RecoveryAccountRestartCheck.swift
compile_run directory-swap Sources/Account/RecoveryDigest.swift Sources/Account/RecoveryFileTransaction.swift Sources/RecoveryDirectorySwap.swift Tests/RecoveryDirectorySwapCheck.swift
compile_run baseline Sources/Account/RecoveryDigest.swift Sources/RecoveryBaseline.swift Tests/RecoveryBaselineCheck.swift
compile_run restore-image-key -parse-as-library Sources/RestoreImageKey.swift Sources/RestoreImageKeyAgreement.swift Tests/RestoreImageKeyCheck.swift
compile_run restore-image-key-cryptokit -parse-as-library Sources/RestoreImageKey.swift Sources/RestoreImageKeyAgreement.swift Tests/RestoreImageKeyCryptoKitCheck.swift
compile_run restore-image-member -parse-as-library Sources/RestoreImageMember.swift Tests/RestoreImageMemberCheck.swift
compile_run restore-image-stub-plan -parse-as-library Sources/Account/RecoveryDigest.swift Sources/RestoreImageMember.swift Sources/RestoreImageDirectory.swift Sources/RestoreImageStubPlan.swift Tests/RestoreImageStubPlanCheck.swift
# LZFSE from libcompression through the app's own C module (Compression/), as the app links
# it, built for the app's oldest recoveryOS (Package.swift: macOS 13) like the checks below.
xcrun clang -target "$(uname -m)-apple-macos13.0" -c -Wall -Wextra -Werror -I Compression/include Compression/RecoveryCompression.c -o "$out/recovery-compression.o"
./Tools/require-macos13.sh "$out/recovery-compression.o"
archive=(-parse-as-library -I Compression/include Sources/Account/RecoveryDigest.swift Sources/RestoreImageKey.swift Sources/RestoreImageKeyAgreement.swift Sources/RestoreImageMember.swift Sources/RestoreImageDirectory.swift Sources/RestoreImageStream.swift Sources/RestoreImageArchive.swift Sources/RestoreImageResourceFork.swift Sources/RestoreImageStubPlan.swift Sources/RestoreImageStubFiles.swift "$out/recovery-compression.o" -lcompression)
# For the app's oldest recoveryOS (macOS 13), so an API it lacks fails the build.
compile_run restore-image-archive -target "$(uname -m)-apple-macos13.0" "${archive[@]}" Tests/RestoreImageArchiveCheck.swift
compile_run restore-image-stub-files -target "$(uname -m)-apple-macos13.0" "${archive[@]}" Tests/RestoreImageStubFilesCheck.swift
./Tools/require-macos13.sh "$out/restore-image-archive" "$out/restore-image-stub-files"
# The in-place startup firmware upgrade: request and checks, network reader and
# archive keys (a fake transport), and the in-place writer on a fake stub.
upgrade=("${archive[@]}" Sources/RestoreImageRemote.swift Sources/StubUpgradeRequest.swift Sources/StubUpgradeCheck.swift Sources/StubUpgradeGrow.swift Sources/StubUpgradeRecords.swift Sources/RestoreImageStubUpgrade.swift Sources/RecoveryDirectorySwap.swift Sources/Account/RecoveryFileTransaction.swift Sources/Account/AuraStage1.swift Sources/RecoveryOwner.swift Sources/Stage1Reenrollment.swift Sources/BootSelection.swift)
compile_run stub-upgrade-request -target "$(uname -m)-apple-macos13.0" "${upgrade[@]}" Tests/StubUpgradeRequestCheck.swift
compile_run restore-image-remote -target "$(uname -m)-apple-macos13.0" "${upgrade[@]}" Tests/RestoreImageRemoteCheck.swift
compile_run restore-image-stub-upgrade -target "$(uname -m)-apple-macos13.0" "${upgrade[@]}" Tests/RestoreImageStubUpgradeCheck.swift
compile_run stub-upgrade-grow -target "$(uname -m)-apple-macos13.0" "${upgrade[@]}" Tests/StubUpgradeGrowCheck.swift
./Tools/require-macos13.sh "$out/stub-upgrade-request" "$out/restore-image-remote" "$out/restore-image-stub-upgrade" "$out/stub-upgrade-grow"
# Built for the app's oldest recoveryOS (Package.swift: macOS 13) so the same
# binary can be run there by hand; CI keeps it with the Recovery evidence.
xcrun swiftc -target "$(uname -m)-apple-macos13.0" -parse-as-library Sources/RestoreImageKey.swift Sources/RestoreImageKeyAgreement.swift Sources/RestoreImageMember.swift Tools/RestoreImageKeyTool.swift -o "$out/aurora-restore-key"
Tests/RestoreImageKeyTool.sh "$out/aurora-restore-key"

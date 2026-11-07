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
compile_run owner Sources/RecoveryOwner.swift Tests/RecoveryOwnerCheck.swift
compile_run bootstrap-owner Sources/RecoveryOwner.swift Tests/BootstrapOwnerCheck.swift
compile_run boot-selection Sources/Account/AuraStage1.swift Sources/BootSelection.swift Tests/BootSelectionCheck.swift
compile_run macho-boot-object Sources/Account/AuraStage1.swift Tests/MachOBootObjectCheck.swift
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
compile_run configuration Sources/RecoveryOwner.swift Sources/Account/AuraStage1.swift Sources/BootSelection.swift Sources/InstallConfiguration.swift Tests/InstallConfigurationCheck.swift
compile_run file-transaction Sources/Account/RecoveryDigest.swift Sources/Account/RecoveryFileTransaction.swift Tests/RecoveryFileTransactionCheck.swift
compile_run installation-journal Sources/RecoveryInstallationJournal.swift Tests/RecoveryInstallationJournalCheck.swift
compile_run account-restart Sources/RecoveryAccountRestart.swift Tests/RecoveryAccountRestartCheck.swift
compile_run directory-swap Sources/Account/RecoveryDigest.swift Sources/Account/RecoveryFileTransaction.swift Sources/RecoveryDirectorySwap.swift Tests/RecoveryDirectorySwapCheck.swift
compile_run baseline Sources/Account/RecoveryDigest.swift Sources/RecoveryBaseline.swift Tests/RecoveryBaselineCheck.swift

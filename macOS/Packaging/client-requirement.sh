#!/bin/bash
# The client requirements the privileged helper accepts from its launchd job.
# Mirrors HelperClientRequirement.enforced(for:) in
# Sources/AuroraAppleInstaller/HelperClientRequirement.swift exactly: the
# helper refuses any other text at launch and exits, and launchd respawns it.
# Sourced by packagers.

# Prints the form of the requirement and succeeds when the helper accepts it:
# developer-id, legacy-team (held to the Developer ID form of that team),
# cdhash, or never. Fails, printing nothing, for anything else.
installer_client_requirement_form() {
  local requirement=$1 app=$2 anchored markers team_prefix pin_prefix rest
  local upper=ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 hex=0123456789abcdef
  [[ -n $app ]] || return 1
  if [[ $requirement == never ]]; then
    echo never
    return 0
  fi
  pin_prefix="identifier \"$app\" and cdhash H\""
  if [[ $requirement == "$pin_prefix"* ]]; then
    rest=${requirement#"$pin_prefix"}
    if [[ $rest =~ ^[$hex]{40}\"$ ]]; then
      echo cdhash
      return 0
    fi
    return 1
  fi
  anchored="anchor apple generic and identifier \"$app\""
  markers=" and certificate 1[field.1.2.840.113635.100.6.2.6]"
  markers+=" and certificate leaf[field.1.2.840.113635.100.6.1.13]"
  team_prefix=" and certificate leaf[subject.OU] = \""
  if [[ $requirement == "$anchored$markers$team_prefix"* ]]; then
    rest=${requirement#"$anchored$markers$team_prefix"}
    [[ $rest =~ ^[$upper]{10}\"$ ]] || return 1
    echo developer-id
    return 0
  fi
  if [[ $requirement == "$anchored$team_prefix"* ]]; then
    rest=${requirement#"$anchored$team_prefix"}
    [[ $rest =~ ^[$upper]{10}\"$ ]] || return 1
    echo legacy-team
    return 0
  fi
  return 1
}

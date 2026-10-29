enum InstallerAppError: Error {
  case hostChanged
  case workspaceUnavailable
  case inspectionRequired
  case approvalUnavailable
  case previewFixtureUnavailable
}

import Foundation
import PackagePlugin

@main
struct AuroraFirmwareRecipePlugin: BuildToolPlugin {
  func createBuildCommands(context: PluginContext, target: any Target) throws -> [Command] {
    let recipe = context.package.directoryURL.appending(
      components: "Sources", "AuroraFirmware", "Resources", "j700-25G83-ranges.json")
    let output = context.pluginWorkDirectoryURL.appending(component: "EmbeddedFirmwareRecipe.swift")
    return [
      .buildCommand(
        displayName: "Embedding sealed firmware recipe",
        executable: try context.tool(named: "AuroraFirmwareRecipeGenerator").url,
        arguments: [recipe.path(percentEncoded: false), output.path(percentEncoded: false)],
        inputFiles: [recipe], outputFiles: [output])
    ]
  }
}

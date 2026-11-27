import Foundation
import PackagePlugin

@main
struct AuroraFirmwareRecipePlugin: BuildToolPlugin {
  func createBuildCommands(context: PluginContext, target: any Target) throws -> [Command] {
    let resources = context.package.directoryURL.appending(
      components: "Sources", "AuroraFirmware", "Resources")
    let recipe = resources.appending(component: "j700-25G83-ranges.json")
    let output = context.pluginWorkDirectoryURL.appending(component: "EmbeddedFirmwareRecipe.swift")
    let generator = try context.tool(named: "AuroraFirmwareRecipeGenerator").url
    // Each restore image list and every recipe beside it; the generator
    // checks each against its pinned index.
    func list(_ kind: String, _ directory: String, _ type: String, _ name: String) throws
      -> Command
    {
      let folder = resources.appending(component: directory)
      let index = folder.appending(component: "index.json")
      let recipes = try FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: nil
      )
      .filter { $0.pathExtension == "json" && $0.lastPathComponent != "index.json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      let generated = context.pluginWorkDirectoryURL.appending(component: type + ".swift")
      return .buildCommand(
        displayName: "Embedding " + name + " restore image recipes",
        executable: generator,
        arguments: [kind, index.path(percentEncoded: false), generated.path(percentEncoded: false)]
          + recipes.map { $0.path(percentEncoded: false) },
        inputFiles: [index] + recipes, outputFiles: [generated])
    }
    return [
      .buildCommand(
        displayName: "Embedding sealed firmware recipe",
        executable: generator,
        arguments: [recipe.path(percentEncoded: false), output.path(percentEncoded: false)],
        inputFiles: [recipe], outputFiles: [output]),
      try list(
        "speaker-tuning", "speaker-tuning", "EmbeddedSpeakerTuningRecipes", "speaker tuning"),
      try list(
        "radio-firmware", "radio-firmware", "EmbeddedRadioFirmwareRecipes", "Wi-Fi firmware"),
    ]
  }
}

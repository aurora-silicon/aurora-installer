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
    // The speaker tuning pin and every recipe beside it; the generator
    // checks each against the pinned index.
    let tuning = resources.appending(component: "speaker-tuning")
    let index = tuning.appending(component: "index.json")
    let recipes = try FileManager.default.contentsOfDirectory(
      at: tuning, includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "json" && $0.lastPathComponent != "index.json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    let tuningOutput = context.pluginWorkDirectoryURL.appending(
      component: "EmbeddedSpeakerTuningRecipes.swift")
    return [
      .buildCommand(
        displayName: "Embedding sealed firmware recipe",
        executable: generator,
        arguments: [recipe.path(percentEncoded: false), output.path(percentEncoded: false)],
        inputFiles: [recipe], outputFiles: [output]),
      .buildCommand(
        displayName: "Embedding speaker tuning restore image recipes",
        executable: generator,
        arguments: [
          "speaker-tuning", index.path(percentEncoded: false),
          tuningOutput.path(percentEncoded: false),
        ]
          + recipes.map { $0.path(percentEncoded: false) },
        inputFiles: [index] + recipes, outputFiles: [tuningOutput]),
    ]
  }
}

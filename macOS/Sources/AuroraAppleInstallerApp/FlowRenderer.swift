#if DEBUG
  import AppKit
  import AuroraAppleInstallerTrustCore
  import AuroraInstallerUXCore
  import SwiftUI

  /// Debug-only: drives simulation sessions through the real pages and writes
  /// each step to PNG (`--render-flow=DIRECTORY`). It uses the simulation
  /// environment only: no helper, download, account or disk operation.
  @MainActor
  enum FlowRenderer {
    static let windowSize = NSSize(width: 840, height: 680)

    static func run(directory: URL) async {
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      var number = 0
      func save(_ image: NSBitmapImageRep?, _ name: String) {
        number += 1
        guard let image, let data = image.representation(using: .png, properties: [:]) else {
          fputs("render-flow: \(name) failed\n", stderr)
          return
        }
        let file = directory.appendingPathComponent(String(format: "%02d-%@.png", number, name))
        try? data.write(to: file)
        print(file.path)
      }
      let selection = AuroraInstallationSelection()

      // System chooser, then Partitions on this Mac.
      save(
        await render(
          AuroraWelcomeView(selection: .constant(selection), device: .simulation, onContinue: {})),
        "system-chooser")
      let main = await inspected(.partitions, selection: selection)
      guard let session = main.session, case .partitions(_, let layout) = session.phase else {
        fputs("render-flow: the partitions scenario did not reach its screen\n", stderr)
        return
      }
      save(await page(session, selection), "partitions")
      save(await page(session, selection, dark: true), "partitions-dark")

      // Shrink macOS → size → password → installing → Start in Recovery.
      if let shrink = layout.options.first(where: { $0.kind == .shrink }) {
        save(await page(session, selection, option: shrink.id), "partitions-shrink-selected")
        await session.install(into: shrink.target)
        session.continueToPlanReview()
        save(await page(session, selection), "shrink-macos-size")
        session.setAcknowledged(true)
        session.approve()
        if case .awaitingInstall(let plan, let helper, _) = session.phase {
          let sheet = CredentialSheet(
            context: CredentialSheetContext(
              kind: .install, bindingDigest: plan.bindingDigest,
              mentionsBackgroundItem: helper.willInstall),
            isSimulation: false, onCancel: {}, onSubmit: { _ in })
          save(
            await composite(page: page(session, selection), sheet: render(sheet, size: nil)),
            "password")
        }
        session.presentInstallCredentials()
        if let authorization = try? MachineOwnerAuthorization(
          username: "owner", password: Data("simulation".utf8))
        {
          let running = Task { await session.submit(authorization) }
          if await wait(
            for: session,
            {
              if case .installing(let progress) = $0 { progress.stepIndex >= 3 } else { false }
            })
          {
            save(await page(session, selection), "installing")
          }
          await running.value
          save(await page(session, selection), "start-in-recovery")
        }
      }

      // Use free space → size.
      let free = await inspected(.partitions, selection: selection)
      if let session = free.session,
        let option = free.layout?.options.first(where: {
          $0.kind == .freeSpace
        })
      {
        save(await page(session, selection, option: option.id), "partitions-free-selected")
        await session.install(into: option.target)
        session.continueToPlanReview()
        save(await page(session, selection), "use-free-space-size")
      }

      // Erase: free space right after macOS and one Aurora installation.
      let lone = await inspected(.partitionsFreeAfterMacOS, selection: selection)
      if let session = lone.session, let layout = lone.layout {
        let pageImage = await page(session, selection)
        save(pageImage, "partitions-free-after-macos")
        if let row = layout.rows.first(where: { $0.erase?.isAvailable == true }) {
          let sheet = EraseInstallationSheet(layout: layout, row: row, onCancel: {}, onErase: {})
          save(await composite(page: pageImage, sheet: render(sheet, size: nil)), "erase-sheet")
        }
      }

      // Reset and the row's ⋯ menu, on the main layout.
      let reset = await inspected(.partitions, selection: selection)
      if let session = reset.session, let layout = reset.layout,
        let row = layout.rows.last(where: { $0.reset?.isAvailable == true })
      {
        let sheet = ResetInstallationSheet(
          row: row, selection: selection, onCancel: {}, onReset: {})
        save(
          await composite(page: page(session, selection), sheet: render(sheet, size: nil)),
          "reset-sheet")
        save(await page(session, selection, menuRow: row.id), "row-menu")
        await session.reset(row.id)
        session.continueToPlanReview()
        save(await page(session, selection), "reset-review")
      }

      for (scenario, name) in [
        (InstallerSimulationScenario.partitionsNoRoom, "no-room"),
        (.partitionsTwoMacOS, "two-macos"),
      ] {
        let other = await inspected(scenario, selection: selection)
        if let session = other.session { save(await page(session, selection), name) }
      }
    }

    // MARK: Sessions

    private static func inspected(
      _ scenario: InstallerSimulationScenario, selection: AuroraInstallationSelection
    ) async -> (session: InstallerSession?, layout: DiskLayoutDisplay?) {
      let session = InstallerSession(
        environment: InstallerSimulationEnvironment(
          scenario: scenario, delay: .milliseconds(120)),
        allowsEncryption: selection.distribution.supportsDesktop
          && InstallerBuildProfile.current.allowsEncryption)
      await session.inspect()
      guard case .partitions(_, let layout) = session.phase else { return (nil, nil) }
      return (session, layout)
    }

    private static func wait(
      for session: InstallerSession, _ condition: (InstallerSessionPhase) -> Bool
    ) async -> Bool {
      for _ in 0..<400 {
        if condition(session.phase) { return true }
        try? await Task.sleep(for: .milliseconds(25))
      }
      return false
    }

    // MARK: Rendering

    private static func page(
      _ session: InstallerSession, _ selection: AuroraInstallationSelection, dark: Bool = false,
      option: String? = nil, menuRow: String? = nil
    ) async -> NSBitmapImageRep? {
      await render(
        OnePageInstallerView(
          renderingSession: session, selection: selection, selectedPartitionOption: option
        )
        .environment(\.partitionMenuPreviewRow, menuRow),
        dark: dark)
    }

    /// A view in an offscreen window the size of the installer's, with the
    /// app scene's own modifiers.
    static func render<V: View>(
      _ view: V, size: NSSize? = windowSize, dark: Bool = false
    ) async -> NSBitmapImageRep? {
      let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      let root =
        view
        .frame(width: size?.width, height: size?.height)
        .environment(\.installerDrawsBorderedButtons, true)
        .auroraTypography()
        .tint(.gray)
        .foregroundStyle(InstallerTheme.text)
        .background(InstallerTheme.window)
        .environment(\.colorScheme, dark ? .dark : .light)
      let host = NSHostingView(rootView: root)
      // The window keeps the installer's size instead of the page's ideal one.
      if size != nil { host.sizingOptions = [] }
      host.appearance = appearance
      let frame = NSRect(origin: .zero, size: size ?? host.fittingSize)
      let window = NSWindow(
        contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.appearance = appearance
      window.contentView = host
      host.frame = frame
      try? await Task.sleep(for: .milliseconds(450))
      host.layoutSubtreeIfNeeded()
      host.display()
      guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
      host.cacheDisplay(in: host.bounds, to: image)
      // Not closed: closing the last window would end the app mid-render.
      window.contentView = nil
      window.orderOut(nil)
      return image
    }

    /// The sheet over its page, as macOS presents it: centred near the top
    /// edge with a shadow, the page dimmed slightly.
    static func composite(page: NSBitmapImageRep?, sheet: NSBitmapImageRep?) async
      -> NSBitmapImageRep?
    {
      guard let page, let sheet,
        let output = NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: page.pixelsWide, pixelsHigh: page.pixelsHigh,
          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: output)
      else { return nil }
      let scale = CGFloat(page.pixelsWide) / windowSize.width
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = context
      let full = NSRect(x: 0, y: 0, width: page.pixelsWide, height: page.pixelsHigh)
      page.draw(in: full)
      NSColor.black.withAlphaComponent(0.12).setFill()
      full.fill()
      let width = CGFloat(sheet.pixelsWide)
      let height = CGFloat(sheet.pixelsHigh)
      let rect = NSRect(
        x: (full.width - width) / 2, y: full.height - height - 24 * scale, width: width,
        height: height)
      let path = NSBezierPath(roundedRect: rect, xRadius: 14 * scale, yRadius: 14 * scale)
      NSGraphicsContext.saveGraphicsState()
      let shadow = NSShadow()
      shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
      shadow.shadowBlurRadius = 30 * scale
      shadow.shadowOffset = NSSize(width: 0, height: -8 * scale)
      shadow.set()
      NSColor.windowBackgroundColor.setFill()
      path.fill()
      NSGraphicsContext.restoreGraphicsState()
      NSGraphicsContext.saveGraphicsState()
      path.addClip()
      sheet.draw(in: rect)
      NSGraphicsContext.restoreGraphicsState()
      NSGraphicsContext.restoreGraphicsState()
      return output
    }
  }

  /// The row menu as macOS draws it, from the same items as the real menu.
  /// AppKit menus are their own windows and can't be captured offscreen.
  struct PartitionRowMenuPreview: View {
    let row: DiskLayoutDisplay.Row

    var body: some View {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(PartitionRowMenu.items(for: row)) { item in
          if item.separatorBefore { Divider().padding(.vertical, 4) }
          HStack(spacing: 8) {
            Image(systemName: item.systemImage).frame(width: 16)
            Text(item.title)
            Spacer()
          }
          .font(.system(size: 13))
          .foregroundStyle(item.enabled ? InstallerTheme.text : InstallerTheme.secondaryText)
          .padding(.horizontal, 8).frame(height: 24)
        }
      }
      .padding(5)
      .frame(width: 200)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
      .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(InstallerTheme.text.opacity(0.12)))
      .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
    }
  }
#endif

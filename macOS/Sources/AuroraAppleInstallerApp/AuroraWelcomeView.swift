import AppKit
import AuroraAppleInstallerTrustCore
import SwiftUI

struct AuroraWelcomeView: View {
  @Binding var selection: AuroraInstallationSelection
  var device: MacHeaderDisplay = .unknown
  var channel: ReleaseChannel? = nil
  /// Developer mode may add distributions that aren't ready for everyone.
  var distributions: [AuroraDistribution] = AuroraDistribution.installable
  var onContinue: () -> Void
  private let columns = Array(
    repeating: GridItem(.flexible(minimum: 0), spacing: Space.l), count: 3)
  private var distributionColumns: [GridItem] {
    Array(
      repeating: GridItem(.flexible(minimum: 0), spacing: Space.l),
      count: max(distributions.count, 1))
  }

  var body: some View {
    VStack(spacing: 0) {
      // The same column as every other page: the logo's left edge to the
      // device identity's right edge.
      InstallerMasthead(device: device, channel: channel).inPageColumn().padding(.top, Space.l)
      Text("Choose your distribution and desktop.")
        .font(InstallerTheme.title)
        .inPageColumn().padding(.top, Space.xl)
      VStack(alignment: .leading, spacing: Space.s) {
        sectionTitle("Distribution")
        LazyVGrid(columns: distributionColumns, spacing: Space.l) {
          ForEach(distributions) { distribution in
            SelectionCard(
              selected: selection.distribution == distribution, label: distribution.title
            ) {
              selection.selectDistribution(distribution)
            } content: {
              Text(distribution.title).font(InstallerTheme.label)
                .lineLimit(1).minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity).frame(height: 66)
            }
          }
        }
        sectionTitle("Desktop environment").padding(.top, Space.m)
        if selection.distribution.supportsDesktop {
          LazyVGrid(columns: columns, spacing: Space.l) {
            ForEach(selection.distribution.availableDesktops) { desktop in
              SelectionCard(selected: selection.desktop == desktop, label: desktop.title) {
                selection.desktop = desktop
              } content: {
                VStack(alignment: .leading, spacing: Space.s) {
                  DesktopPreview(desktop: desktop).clipShape(RoundedRectangle(cornerRadius: 9))
                  Text(desktop.title).font(InstallerTheme.label).lineLimit(1)
                  Text(desktopDescription(desktop)).font(InstallerTheme.caption).foregroundStyle(
                    .secondary)
                }.padding(Space.m).frame(maxWidth: .infinity, alignment: .leading)
              }
            }
          }
        }
      }.inPageColumn().padding(.top, Space.xl)
      Spacer(minLength: 18)
      Text(Self.notice(for: selection.distribution))
        .font(InstallerTheme.caption).foregroundStyle(.secondary)
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        .inPageColumn(alignment: .center).padding(.bottom, Space.xxs)
      Button("Continue", action: onContinue)
        .auroraPrimaryButton()
        .frame(minHeight: InstallerTheme.buttonHeight)
        .inPageColumn(alignment: .trailing)
        .padding(.top, Space.m).padding(.bottom, Space.l)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  /// What each distribution's trademark terms ask a modified release to say.
  static func noticeMarkdown(for distribution: AuroraDistribution) -> String {
    switch distribution {
    case .fedora:
      "Aurora Fedora Remix contains modified Fedora® software and is not provided or supported "
        + "by the Fedora Project. Official Fedora is available at "
        + "[fedoraproject.org](https://fedoraproject.org/). Fedora is a registered trademark of "
        + "Red Hat, Inc., or its subsidiaries in the United States and other countries."
    case .arch:
      "Aurora Alarm is based on Arch Linux ARM and is not provided or endorsed by the "
        + "Arch Linux or Arch Linux ARM projects."
    case .nixos:
      "Aurora NixOS is based on NixOS and is not provided or endorsed by the NixOS project."
    case .omarchy:
      "Omarchy Aurora combines Omarchy with Aurora's Arch Linux ARM hardware stack and is not "
        + "provided or endorsed by the Omarchy project."
    }
  }

  static func notice(for distribution: AuroraDistribution) -> AttributedString {
    let markdown = noticeMarkdown(for: distribution)
    return (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
  }

  private func sectionTitle(_ text: String) -> some View {
    Text(text).font(InstallerTheme.sectionLabel).foregroundStyle(.secondary)
  }

  private func desktopDescription(_ desktop: AuroraDesktop) -> String {
    switch desktop {
    case .kde: "Familiar and customizable"
    case .gnome: "Clean and focused"
    case .minimal: "A lightweight shell"
    case .hyprland: "Omarchy's tiling desktop"
    }
  }
}

private struct SelectionCard<Content: View>: View {
  let selected: Bool
  let label: String
  let action: () -> Void
  @ViewBuilder var content: () -> Content
  @State private var hovered = false

  var body: some View {
    Button(action: action) {
      content()
        .background(
          InstallerTheme.card, in: RoundedRectangle(cornerRadius: InstallerTheme.cardRadius)
        )
        .overlay {
          RoundedRectangle(cornerRadius: InstallerTheme.cardRadius)
            .strokeBorder(
              selected
                ? InstallerTheme.accent
                : (hovered ? Color.primary.opacity(0.25) : InstallerTheme.separator),
              lineWidth: selected ? 2 : 1)
        }
        .overlay(alignment: .topTrailing) {
          if selected {
            Image(systemName: "checkmark.circle.fill")
              .imageScale(.large)
              .symbolRenderingMode(.palette)
              .foregroundStyle(.white, InstallerTheme.accent)
              .padding(Space.s)
              .accessibilityHidden(true)
          }
        }
        .contentShape(RoundedRectangle(cornerRadius: InstallerTheme.cardRadius))
    }
    .buttonStyle(.plain).onHover { hovered = $0 }
    .accessibilityLabel(label).accessibilityAddTraits(selected ? .isSelected : [])
  }
}

struct BrandImage: View {
  let name: String
  init(_ name: String) { self.name = name }
  var body: some View {
    if let url = Bundle.main.url(forResource: name, withExtension: "png"),
      let image = NSImage(contentsOf: url)
    {
      Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
    }
  }
}

struct AuroraMark: View {
  var body: some View { BrandImage("AuroraLogo").accessibilityLabel("Aurora Silicon") }
}

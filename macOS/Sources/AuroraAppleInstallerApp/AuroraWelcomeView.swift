import AppKit
import AuroraAppleInstallerTrustCore
import SwiftUI

struct AuroraWelcomeView: View {
  @Binding var selection: AuroraInstallationSelection
  var device: MacHeaderDisplay = .unknown
  var onContinue: () -> Void
  private let columns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 18), count: 3)

  var body: some View {
    VStack(spacing: 0) {
      // The same column as every other page: the logo's left edge to the
      // device identity's right edge.
      InstallerMasthead(device: device).inPageColumn().padding(.top, 20)
      Text("Choose your distribution and desktop.")
        .font(.system(size: 20, weight: .medium))
        .inPageColumn().padding(.top, 28)
      VStack(alignment: .leading, spacing: 10) {
        sectionTitle("Distribution")
        LazyVGrid(columns: columns, spacing: 18) {
          ForEach(AuroraDistribution.allCases) { distribution in
            SelectionCard(
              selected: selection.distribution == distribution, label: distribution.title
            ) {
              selection.distribution = distribution
            } content: {
              Text(distribution.title).font(.system(size: 13, weight: .medium))
                .lineLimit(1).minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity).frame(height: 66)
            }
          }
        }
        sectionTitle("Desktop environment").padding(.top, 12)
        if selection.distribution.supportsDesktop {
          LazyVGrid(columns: columns, spacing: 18) {
            ForEach(AuroraDesktop.allCases) { desktop in
              SelectionCard(selected: selection.desktop == desktop, label: desktop.title) {
                selection.desktop = desktop
              } content: {
                VStack(alignment: .leading, spacing: 10) {
                  DesktopPreview(desktop: desktop).clipShape(RoundedRectangle(cornerRadius: 9))
                  Text(desktop.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                  Text(desktopDescription(desktop)).font(.system(size: 11)).foregroundStyle(
                    .secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
              }
            }
          }
        }
      }.inPageColumn().padding(.top, 26)
      Spacer(minLength: 18)
      Text(Self.notice(for: selection.distribution))
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        .inPageColumn(alignment: .center).padding(.bottom, 2)
      Button("Continue", action: onContinue)
        .auroraPrimaryButton()
        .frame(minHeight: InstallerTheme.buttonHeight)
        .inPageColumn(alignment: .trailing)
        .padding(.top, 12).padding(.bottom, 20)
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
    }
  }

  static func notice(for distribution: AuroraDistribution) -> AttributedString {
    let markdown = noticeMarkdown(for: distribution)
    return (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
  }

  private func sectionTitle(_ text: String) -> some View {
    Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
  }

  private func desktopDescription(_ desktop: AuroraDesktop) -> String {
    switch desktop {
    case .kde: "Familiar and customizable"
    case .gnome: "Clean and focused"
    case .minimal: "A lightweight shell"
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
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
          RoundedRectangle(cornerRadius: 14)
            .strokeBorder(
              selected ? Color.primary.opacity(0.65) : Color.primary.opacity(hovered ? 0.25 : 0.10),
              lineWidth: selected ? 1.5 : 1)
        }
        .overlay(alignment: .topTrailing) {
          if selected {
            Image(systemName: "checkmark.circle.fill")
              .font(.system(size: 15, weight: .medium))
              .symbolRenderingMode(.palette)
              .foregroundStyle(Color(nsColor: .windowBackgroundColor), Color.primary)
              .padding(8)
          }
        }
        .shadow(color: .black.opacity(selected ? 0.055 : 0.025), radius: 5, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 14))
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

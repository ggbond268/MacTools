import AppKit

@MainActor
final class AIUsageProviderAssets {
    private let images: [AIUsageProvider: NSImage]

    init(bundle: Bundle) {
        images = Dictionary(uniqueKeysWithValues: AIUsageProvider.allCases.map { provider in
            let name = provider == .codex ? "CodexLogo" : "ClaudeLogo"
            let image = bundle.url(forResource: name, withExtension: "svg").flatMap(NSImage.init(contentsOf:))
                ?? NSImage(systemSymbolName: provider.symbol, accessibilityDescription: provider.title) ?? NSImage()
            image.isTemplate = true
            return (provider, image)
        })
    }

    func image(for provider: AIUsageProvider) -> NSImage { images[provider]! }
}

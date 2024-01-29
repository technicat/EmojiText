//
//  EmojiText.swift
//  EmojiText
//
//  Created by David Walter on 11.01.23.
//

import SwiftUI
import Nuke
import OSLog

/// A view that displays one or more lines of text with support for custom emojis.
///
/// Custom Emojis are in the format `:emoji:`.
/// Supports local and remote custom emojis.
///
/// Remote emojis are resolved using [Nuke](https://github.com/kean/Nuke)
public struct EmojiText: View {
    @Environment(\.font) var font
    @Environment(\.dynamicTypeSize) var dynamicTypeSize
    @Environment(\.displayScale) var displayScale
    
    @Environment(\.emojiImagePipeline) var imagePipeline
    @Environment(\.emojiPlaceholder) var emojiPlaceholder
    @Environment(\.emojiSize) var emojiSize
    @Environment(\.emojiBaselineOffset) var emojiBaselineOffset
    #if os(watchOS) || os(macOS)
    @Environment(\.emojiTimer) var emojiTimer
    #endif
    @Environment(\.emojiAnimatedMode) var emojiAnimatedMode
    
    @ScaledMetric
    var scaleFactor: CGFloat = 1.0
    
    let raw: String
    let emojis: [any CustomEmoji]
    let renderer: EmojiRenderer
    
    var prepend: (() -> Text)?
    var append: (() -> Text)?
    
    var shouldAnimateIfNeeded: Bool = false
    
    @State var renderedEmojis: [String: RenderedEmoji]?
    @State var renderTime: CFTimeInterval = 0
    
    public var body: some View {
        makeContent
            .task(id: hashValue, priority: .high) {
                guard !emojis.isEmpty else {
                    renderedEmojis = [:]
                    return
                }
                
                // Hash of currently displayed emojis
                let renderedHash = renderedEmojis.hashValue
                var emojis: [String: RenderedEmoji] = renderedEmojis ?? [:]
                
                // Set placeholders
                emojis = emojis.merging(loadEmojis()) { current, new in
                    if current.hasSameSource(as: new) {
                        if !new.isPlaceholder || current.isPlaceholder {
                            return new
                        } else {
                            return current
                        }
                    } else {
                        return new
                    }
                }
                renderedEmojis = emojis
                
                // Load actual emojis if needed (e.g. placeholders were set or source emojis changed)
                if renderedHash != emojis.hashValue || emojis.contains(where: \.value.isPlaceholder) {
                    emojis = emojis.merging(await loadRemoteEmojis()) { _, new in
                        new
                    }
                    renderedEmojis = emojis
                }
                
                guard shouldAnimateIfNeeded, needsAnimation else { return }
                
                #if os(iOS) || targetEnvironment(macCatalyst) || os(tvOS) || os(visionOS)
                for await targetTimestamp in CADisplayLink.publish(mode: .common, stopOnLowPowerMode: emojiAnimatedMode.disabledOnLowPower).values.map(\.targetTimestamp) {
                    renderTime = targetTimestamp
                }
                #else
                for await time in emojiTimer.values(stopOnLowPowerMode: emojiAnimatedMode.disabledOnLowPower) {
                    renderTime = time.timeIntervalSinceReferenceDate as CFTimeInterval
                }
                #endif
            }
    }
    
    var makeContent: Text {
        let result: Text
        
        if needsAnimation {
            result = renderer.renderAnimated(string: raw, emojis: renderedEmojis ?? loadEmojis(), at: renderTime)
        } else {
            result = renderer.render(string: raw, emojis: renderedEmojis ?? loadEmojis())
        }
        
        return [prepend?(), result, append?()]
            .compactMap { $0 }
            .joined()
    }

    // MARK: - Load Emojis
    
    func loadEmojis() -> [String: RenderedEmoji] {
        let font = EmojiFont.preferredFont(from: font, for: dynamicTypeSize)
        let baselineOffset = emojiBaselineOffset ?? -(font.pointSize - font.capHeight) / 2
        
        var renderedEmojis = [String: RenderedEmoji]()
        
        for emoji in emojis {
            switch emoji {
            case let localEmoji as LocalEmoji:
                // Local emoji don't require a placeholder as they can be loaded instantly
                renderedEmojis[emoji.shortcode] = RenderedEmoji(
                    from: localEmoji,
                    targetHeight: targetHeight,
                    baselineOffset: baselineOffset
                )
            case let sfSymbolEmoji as SFSymbolEmoji:
                // SF Symbol emoji don't require a placeholder as they can be loaded instantly
                renderedEmojis[emoji.shortcode] = RenderedEmoji(
                    from: sfSymbolEmoji
                )
            case let remoteEmoji as RemoteEmoji:
                // Try to load remote emoji from cache
                let resizeHeight = targetHeight * displayScale
                let request = ImageRequest(
                    url: remoteEmoji.url,
                    processors: [.resize(height: resizeHeight)]
                )
                if let imageContainer = imagePipeline.cache[request] {
                    // Remote emoji is available in cache and can be loaded instantly
                    renderedEmojis[remoteEmoji.shortcode] = RenderedEmoji(
                        from: remoteEmoji,
                        image: RawImage(image: imageContainer.image),
                        animated: shouldAnimateIfNeeded,
                        targetHeight: targetHeight,
                        baselineOffset: baselineOffset
                    )
                } else {
                    // Remote emoji wasn't found in cache and a placholder will be used instead
                    fallthrough
                }
            default:
                // Set a placeholder for all other emoji
                renderedEmojis[emoji.shortcode] = RenderedEmoji(
                    from: emoji,
                    placeholder: emojiPlaceholder,
                    targetHeight: targetHeight,
                    baselineOffset: baselineOffset
                )
            }
        }
        
        return renderedEmojis
    }
    
    func loadRemoteEmojis() async -> [String: RenderedEmoji] {
        let font = EmojiFont.preferredFont(from: font, for: dynamicTypeSize)
        let baselineOffset = emojiBaselineOffset ?? -(font.pointSize - font.capHeight) / 2
        let resizeHeight = targetHeight * displayScale
        
        return await withTaskGroup(of: RenderedEmoji?.self, returning: [String: RenderedEmoji].self) { [targetHeight, shouldAnimateIfNeeded] group in
            for emoji in emojis {
                switch emoji {
                case let remoteEmoji as RemoteEmoji:
                    _ = group.addTaskUnlessCancelled {
                        do {
                            let image: RawImage
                            let request = ImageRequest(
                                url: remoteEmoji.url,
                                processors: [.resize(height: resizeHeight)]
                            )
                            if shouldAnimateIfNeeded {
                                let (data, _) = try await imagePipeline.data(for: request)
                                image = try RawImage(data: data)
                            } else {
                                let data = try await imagePipeline.image(for: request)
                                image = RawImage(image: data)
                            }
                            return RenderedEmoji(
                                from: remoteEmoji,
                                image: image,
                                animated: shouldAnimateIfNeeded,
                                targetHeight: targetHeight,
                                baselineOffset: baselineOffset
                            )
                        } catch {
                            Logger.emojiText.error("Unable to load custom emoji \(emoji.shortcode): \(error.localizedDescription)")
                            return nil
                        }
                    }
                default:
                    continue
                }
            }
            // Collect TaskGroup results
            return await group.reduce(into: [:]) { partialResult, emoji in
                if let emoji {
                    partialResult[emoji.shortcode] = emoji
                }
            }
        }
    }
    
    // MARK: - Initializers
    
    /// Initialize a Markdown formatted ``EmojiText`` with support for custom emojis.
    ///
    /// - Parameters:
    ///     - markdown: The string that contains the Markdown formatting.
    ///     - interpretedSyntax: The syntax for intepreting a Markdown string. Defaults to `.inlineOnlyPreservingWhitespace`.
    ///     - emojis: The custom emojis to render.
    ///     - shoulOmitSpacesBetweenEmojis: Whether to omit spaces between emojis. Defaults to `true.`
    ///
    /// > Info:
    /// > Consider removing spaces between emojis as this will often drastically reduce
    /// the amount of text contactenations needed to render the emojis.
    /// >
    /// > There is a limit in SwiftUI Text concatenations and if this limit is reached the application will crash.
    public init(
        markdown content: String,
        interpretedSyntax: AttributedString.MarkdownParsingOptions.InterpretedSyntax = .inlineOnlyPreservingWhitespace,
        emojis: [any CustomEmoji],
        shouldOmitSpacesBetweenEmojis: Bool = true
    ) {
        self.renderer = MarkdownEmojiRenderer(shouldOmitSpacesBetweenEmojis: shouldOmitSpacesBetweenEmojis, interpretedSyntax: interpretedSyntax)
        self.raw = content
        self.emojis = emojis.filter { content.contains(":\($0.shortcode):") }
    }
    
    /// Initialize a ``EmojiText`` with support for custom emojis.
    ///
    /// - Parameters:
    ///     - verbatim: A string to display without localization.
    ///     - emojis: The custom emojis to render.
    ///     - shoulOmitSpacesBetweenEmojis: Whether to omit spaces between emojis. Defaults to `true.
    ///
    /// > Info:
    /// > Consider removing spaces between emojis as this will often drastically reduce
    /// the amount of text contactenations needed to render the emojis.
    /// >
    /// > There is a limit in SwiftUI Text concatenations and if this limit is reached the application will crash.
    public init(
        verbatim content: String,
        emojis: [any CustomEmoji],
        shouldOmitSpacesBetweenEmojis: Bool = true
    ) {
        self.renderer = VerbatimEmojiRenderer(shouldOmitSpacesBetweenEmojis: shouldOmitSpacesBetweenEmojis)
        self.raw = content
        self.emojis = emojis.filter { content.contains(":\($0.shortcode):") }
    }
    
    /// Initialize a ``EmojiText`` with support for custom emojis.
    ///
    /// - Parameters:
    ///     - content: A string value to display without localization.
    ///     - emojis: The custom emojis to render.
    ///
    /// > Info:
    /// > Consider removing spaces between emojis as this will often drastically reduce
    /// the amount of text contactenations needed to render the emojis.
    /// >
    /// > There is a limit in SwiftUI Text concatenations and if this limit is reached the application will crash.
    public init<S>(
        _ content: S,
        emojis: [any CustomEmoji],
        shouldOmitSpacesBetweenEmojis: Bool = true
    ) where S: StringProtocol {
        self.init(verbatim: String(content), emojis: emojis, shouldOmitSpacesBetweenEmojis: shouldOmitSpacesBetweenEmojis)
    }

    
    // MARK: - Modifier
    
    /// Prepend `Text` to the ``EmojiText`` view.
    ///
    /// - Parameter text: Callback generating the text to prepend
    /// - Returns: ``EmojiText`` with some text prepended
    public func prepend(text: @escaping () -> Text) -> Self {
        var view = self
        view.prepend = text
        return view
    }
    
    /// Append `Text` to the ``EmojiText`` view.
    ///
    /// - Parameter text: Callback generating the text to append
    /// - Returns: ``EmojiText`` with some text appended
    public func append(text: @escaping () -> Text) -> Self {
        var view = self
        view.append = text
        return view
    }
    
    // MARK: - Modifier
    
    /// Enable animated emoji
    ///
    /// - Parameter value: Enable or disable the animated emoji
    /// - Returns: ``EmojiText`` with animated emoji enabled or disabled.
    public func animated(_ value: Bool = true) -> Self {
        var view = self
        view.shouldAnimateIfNeeded = value
        return view
    }
    
    // MARK: - Helper
    
    // swiftlint:disable:next legacy_hashing
    var hashValue: Int {
        var hasher = Hasher()
        hasher.combine(raw)
        for emoji in emojis {
            hasher.combine(emoji)
        }
        hasher.combine(shouldAnimateIfNeeded)
        hasher.combine(emojiSize)
        hasher.combine(emojiAnimatedMode)
        hasher.combine(displayScale)
        return hasher.finalize()
    }
    
    var targetHeight: CGFloat {
        if let emojiSize = emojiSize {
            return emojiSize
        } else {
            let font = EmojiFont.preferredFont(from: font, for: dynamicTypeSize)
            return font.pointSize * scaleFactor
        }
    }
    
    var needsAnimation: Bool {
        guard let renderedEmojis else { return false }
        
        guard case .never = emojiAnimatedMode else {
            return renderedEmojis.contains { $1.isAnimated }
        }
        
        return false
    }
}

#if DEBUG
#Preview {
    List {
        EmojiText(verbatim: "Hello World :mastodon:", emojis: EmojiText.emojis)
        EmojiText(verbatim: "Hello iPhone :iphone:", emojis: EmojiText.emojis)
        EmojiText(markdown: "**Hello** _World_ :mastodon:", emojis: EmojiText.emojis)
    }
}
#endif

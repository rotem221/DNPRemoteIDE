import Foundation
import Combine
import AppKit
import os
import Sparkle

private let logger = Logger(subsystem: "com.dnp.remote.mac", category: "UpdateService")

/// Update channels we publish to GitHub Releases. Each channel has its own
/// appcast file so release notes from one stream don't bleed into the other.
///
/// `feedURL` always points at the canonical "latest" appcast for the matching
/// architecture, so users on Apple Silicon and Intel only ever see updates
/// they can actually install. `archSlug` is computed from the running binary
/// at first use, so a Universal build correctly routes to the right feed.
enum DNPUpdateChannel: String, CaseIterable, Identifiable {
    case stable
    case beta

    static let storageKey = "dnp.mac.update.channel"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stable: return "Stable"
        case .beta:   return "Beta"
        }
    }

    /// Where Sparkle pulls the appcast from. The stable feed lives at
    /// `releases/latest/download/...` so it auto-tracks the latest GitHub
    /// release; the beta feed lives under a fixed "beta-channel" tag that
    /// each beta workflow run replaces in place — that way Sparkle always
    /// has a stable URL to poll.
    var feedURL: String {
        switch self {
        case .stable:
            return "https://github.com/\(Self.repoSlug)/releases/latest/download/appcast-\(Self.archSlug).xml"
        case .beta:
            return "https://github.com/\(Self.repoSlug)/releases/download/beta-channel/appcast-beta-\(Self.archSlug).xml"
        }
    }

    /// Owner/repo on GitHub. Single source of truth for every place that
    /// builds a feed or release URL — change this if the repo ever moves.
    static let repoSlug = "rotem221/DNPRemoteIDE"

    private static var archSlug: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}

/// Wraps Sparkle's `SPUStandardUpdaterController` and exposes a small,
/// SwiftUI-friendly surface so the Settings UI can show the current
/// version, an "available update" banner, a Check Now button, and a
/// channel picker — without having to know Sparkle internals.
///
/// Mirrors the muxy-app/muxy `UpdateService` pattern: the controller is
/// owned here as a process-wide singleton, kicked off from
/// `applicationDidFinishLaunching`. Channel changes route at runtime via
/// `SPUUpdaterDelegate.feedURLString(for:)` — the Info.plist `SUFeedURL`
/// is just a default fallback; the delegate wins.
@MainActor
final class UpdateService: NSObject, ObservableObject {
    static let shared = UpdateService()

    // Sparkle plumbing. `controller` is started lazily from `start()` so
    // we can opt out of automatic checks in unit tests / SwiftUI previews
    // by simply never calling start.
    private let controller: SPUStandardUpdaterController
    private let feedDelegate: FeedDelegate
    private var cancellables = Set<AnyCancellable>()

    /// True once Sparkle has finished its first probe and the next "Check
    /// Now" press will actually do something. The Settings button binds
    /// to this so we don't enable a button that would silently no-op.
    @Published private(set) var canCheckForUpdates = false

    /// Latest version Sparkle has surfaced as installable, or `nil` when
    /// we're already up to date / haven't checked yet. Drives the
    /// Settings banner and the menu badge.
    @Published private(set) var availableUpdateVersion: String?

    /// Last time a check completed (success or "no update"). `nil` until
    /// the first probe finishes — the Settings card shows "Never checked"
    /// in that state. Persisted across launches via `UserDefaults` so the
    /// label survives quit/relaunch.
    @Published private(set) var lastCheckedAt: Date?

    /// User-selected channel. Writes update Sparkle's resolved feed URL
    /// AND trigger an immediate background re-check, so flipping to beta
    /// surfaces the newest beta within a couple of seconds.
    var channel: DNPUpdateChannel {
        get { feedDelegate.channel }
        set {
            guard newValue != feedDelegate.channel else { return }
            feedDelegate.channel = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: DNPUpdateChannel.storageKey)
            availableUpdateVersion = nil
            objectWillChange.send()
            updater.checkForUpdatesInBackground()
        }
    }

    /// Master switch for background polling. Mirrors Sparkle's own
    /// `automaticallyChecksForUpdates` so the user's preference persists
    /// in the standard `SUEnableAutomaticChecks` UserDefaults key Sparkle
    /// reads on its own.
    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set {
            updater.automaticallyChecksForUpdates = newValue
            objectWillChange.send()
        }
    }

    private var updater: SPUUpdater { controller.updater }

    /// Display string for the Sparkle "last checked" line. `nil` rather
    /// than an empty string so the Settings UI can render a placeholder
    /// instead of a blank.
    var lastCheckedDescription: String? {
        guard let date = lastCheckedAt else { return nil }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }

    private static let lastCheckedDefaultsKey = "dnp.mac.update.lastCheckedAt"

    override private init() {
        let stored = UserDefaults.standard.string(forKey: DNPUpdateChannel.storageKey)
            .flatMap { DNPUpdateChannel(rawValue: $0) } ?? .stable
        let delegate = FeedDelegate(channel: stored)
        self.feedDelegate = delegate
        // `startingUpdater: false` — we call `start()` from the app
        // delegate so we have a known launch point and can fail loudly
        // (logger.warning) instead of crashing the SwiftUI render pass
        // if the bundle is missing required Info.plist keys.
        self.controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        self.lastCheckedAt = UserDefaults.standard.object(forKey: Self.lastCheckedDefaultsKey) as? Date
        super.init()
        observeUpdaterState()
        observeUpdateNotifications()
    }

    /// Boot the updater. Safe to call once per process. `start()` only
    /// throws if the bundle is missing Sparkle plist keys — we log and
    /// continue so the app still launches even when an unsigned/dev build
    /// has no SUFeedURL configured.
    func start() {
        do {
            try updater.start()
            logger.info("Sparkle updater started — channel=\(self.channel.rawValue, privacy: .public) feed=\(self.feedDelegate.channel.feedURL, privacy: .public)")
        } catch {
            logger.warning("Sparkle updater failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// User pressed "Check for Updates" in Settings or the menu. Pops
    /// Sparkle's standard "checking…" UI so the user gets feedback even
    /// when there's nothing to install.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Open the GitHub releases page in the user's browser. Used as a
    /// fallback action on the "update available" banner so a user who
    /// hit a Sparkle install error still has a path forward.
    func openReleasesPage() {
        guard let url = URL(string: "https://github.com/\(DNPUpdateChannel.repoSlug)/releases") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Observation

    private func observeUpdaterState() {
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: \.canCheckForUpdates, on: self)
            .store(in: &cancellables)
    }

    private func observeUpdateNotifications() {
        // `SUUpdaterDidFindValidUpdate` fires once per Sparkle probe that
        // resolves to an installable update. We surface the human-readable
        // version string so the Settings banner reads "v0.2.1 available"
        // rather than the internal build number.
        NotificationCenter.default.publisher(for: .SUUpdaterDidFindValidUpdate)
            .compactMap { $0.userInfo?[SUUpdaterAppcastItemNotificationKey] as? SUAppcastItem }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] item in
                guard let self else { return }
                self.availableUpdateVersion = item.displayVersionString
                self.markChecked()
                logger.info("Update available: \(item.displayVersionString, privacy: .public)")
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .SUUpdaterDidNotFindUpdate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.availableUpdateVersion = nil
                self.markChecked()
            }
            .store(in: &cancellables)
    }

    private func markChecked() {
        let now = Date()
        lastCheckedAt = now
        UserDefaults.standard.set(now, forKey: Self.lastCheckedDefaultsKey)
    }
}

/// Routes Sparkle's feed-URL lookup to the user-selected channel at
/// runtime. Without this, Sparkle would pin to whatever URL was baked
/// into Info.plist at build time — flipping channels in Settings would
/// have no effect until the next release.
private final class FeedDelegate: NSObject, SPUUpdaterDelegate {
    var channel: DNPUpdateChannel

    init(channel: DNPUpdateChannel) {
        self.channel = channel
        super.init()
    }

    func feedURLString(for _: SPUUpdater) -> String? {
        return channel.feedURL
    }

    /// Sparkle uses these to filter which `<sparkle:channel>` items in
    /// an appcast a given installation is allowed to receive. Stable
    /// users only see items with no channel marker; beta users see
    /// items tagged `beta`.
    func allowedChannels(for _: SPUUpdater) -> Set<String> {
        switch channel {
        case .stable: return []
        case .beta:   return [channel.rawValue]
        }
    }
}

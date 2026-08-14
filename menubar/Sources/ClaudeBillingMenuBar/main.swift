import AppKit
import CoreText
import Foundation

struct DesktopState: Decodable, Equatable {
    let available: Bool
    let account: String?
}

/// One AWS SSO login from ~/.aws/config, paired with the expiry of its cached
/// access token. Bedrock profiles stop working once this expires, so the menu
/// surfaces it; the CLI owns all of the parsing and expiry maths.
struct SSOSessionState: Decodable, Equatable {
    let name: String
    let profiles: [String]
    let expiresAt: String?
    let secondsRemaining: Int?
    let status: String
    let active: Bool

    var needsRefresh: Bool {
        status == "expired" || status == "signed-out"
    }

    var symbolName: String {
        switch status {
        case "valid": return "checkmark.circle"
        case "expiring": return "clock.badge.exclamationmark"
        default: return "exclamationmark.triangle.fill"
        }
    }

    var detail: String {
        switch status {
        case "signed-out": return "signed out"
        case "expired": return "expired"
        case "expiring": return "expires in \(SSOSessionState.humanized(secondsRemaining))"
        case "valid": return "valid for \(SSOSessionState.humanized(secondsRemaining))"
        default: return status
        }
    }

    var menuTitle: String {
        "\(name)\(active ? " (in use)" : "") · \(detail)"
    }

    /// The AWS profiles this one login covers — the only part of a session that
    /// says which AWS accounts it actually reaches.
    var profileSummary: String {
        guard !profiles.isEmpty else { return "no profiles use this session" }
        let shown = profiles.prefix(5).joined(separator: ", ")
        let extra = profiles.count - min(profiles.count, 5)
        return extra > 0 ? "\(shown) +\(extra) more" : shown
    }

    static func humanized(_ seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "unknown" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

/// How close a limit is to biting. Thresholds are fixed rather than taken from
/// the endpoint's own `severity`, so the same percentage always gets the same
/// colour and the scale stays predictable.
enum UsageLevel {
    case ok
    case warning
    case critical

    init(percent: Int) {
        switch percent {
        case ..<60: self = .ok
        case ..<85: self = .warning
        default: self = .critical
        }
    }

    var color: NSColor {
        switch self {
        case .ok: return .systemGreen
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }
}

/// Width of the filled part of a usage bar. Split out from the drawing so the
/// rules are testable: a non-zero percentage always leaves a visible sliver, and
/// anything short of 100% never fills the track completely — otherwise 1% looks
/// untouched and 99% looks like you're already cut off. Out-of-range values from
/// the unofficial endpoint are clamped rather than allowed to overflow.
func usageBarFillWidth(percent: Int, width: CGFloat) -> CGFloat {
    let clamped = CGFloat(min(max(percent, 0), 100))
    guard clamped > 0 else { return 0 }
    guard clamped < 100 else { return width }
    let minimumVisible: CGFloat = 3
    return min(max(clamped / 100 * width, minimumVisible), width - 1)
}

/// One continuous bar that fills as usage climbs. Menus have no progress-bar
/// item, so it is drawn as the item's image — simpler and better behaved than a
/// custom menu-item view, and it sits in the same column as every other icon.
func usageBarImage(
    percent: Int,
    color: NSColor,
    size: NSSize = NSSize(width: 46, height: 8)
) -> NSImage {
    let image = NSImage(size: size, flipped: false) { rect in
        let radius = rect.height / 2
        let track = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        color.withAlphaComponent(0.22).setFill()
        track.fill()

        let fillWidth = usageBarFillWidth(percent: percent, width: rect.width)
        if fillWidth > 0 {
            let fillRect = NSRect(x: rect.minX, y: rect.minY, width: fillWidth, height: rect.height)
            // Clip to the track so the fill keeps the rounded ends.
            track.setClip()
            color.setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).fill()
        }
        return true
    }
    // Not a template image: templates get recoloured to match the menu.
    image.isTemplate = false
    image.accessibilityDescription = "\(min(max(percent, 0), 100)) percent used"
    return image
}

/// The bar as an inline run of text, for placing it *after* a title. A menu
/// item's image always precedes its title and occupies the shared icon column,
/// so a wide bar there would indent that row's text past every other row.
func usageBarAttachment(
    percent: Int,
    color: NSColor,
    size: NSSize = NSSize(width: 46, height: 8)
) -> NSAttributedString {
    let attachment = NSTextAttachment()
    attachment.image = usageBarImage(percent: percent, color: color, size: size)
    // Nudged down so the bar sits on the text's optical centre, not its baseline.
    attachment.bounds = CGRect(x: 0, y: -1, width: size.width, height: size.height)
    return NSAttributedString(attachment: attachment)
}

/// One plan limit as reported by Claude's OAuth usage endpoint.
struct UsageLimit: Decodable, Equatable {
    let kind: String
    let percent: Int
    let severity: String
    let resetsAt: String?
    let isActive: Bool

    var name: String {
        switch kind {
        case "session": return "5-hour session"
        case "weekly_all": return "Weekly · all models"
        case "weekly_opus": return "Weekly · Opus"
        case "weekly_sonnet": return "Weekly · Sonnet"
        default: return kind.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// Reset times arrive as ISO-8601 UTC; show them in the user's own zone,
    /// since "resets at 02:00 UTC" needs mental arithmetic at a glance.
    var resetDescription: String? {
        guard let resetsAt else { return nil }
        let parsers = [ISO8601DateFormatter(), ISO8601DateFormatter()]
        parsers[0].formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        parsers[1].formatOptions = [.withInternetDateTime]
        guard let date = parsers.compactMap({ $0.date(from: resetsAt) }).first else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE HH:mm"
        return formatter.string(from: date)
    }

    var level: UsageLevel { UsageLevel(percent: percent) }

    /// When the limit clears. A 5-hour window only has a reset time once it has
    /// started, so an idle one says so rather than implying a deadline.
    var statusSuffix: String {
        if let resetDescription { return " · resets \(resetDescription)" }
        if kind == "session", !isActive { return " · no active window" }
        return ""
    }

    /// The bar and percentage carry the number, so the label only has to say
    /// which limit it is and when it clears.
    var detailLabel: String { "\(name)\(statusSuffix)" }
}

struct UsageSpend: Decodable, Equatable {
    let percent: Int
    let used: Double
    let limit: Double
    let currency: String
    let severity: String

    var level: UsageLevel { UsageLevel(percent: percent) }

    /// What's left of the monthly credit cap. The endpoint reports only spent
    /// and cap, so this is derived — and phrased as "left" rather than
    /// "balance", because it's headroom under a cap, not a prepaid pot.
    var remaining: Double { max(limit - used, 0) }

    /// Symbols for the currencies Claude bills in; anything else keeps its code
    /// rather than guessing a glyph.
    var currencySymbol: String {
        switch currency.uppercased() {
        case "USD": return "$"
        case "EUR": return "€"
        case "GBP": return "£"
        case "JPY": return "¥"
        default: return "\(currency) "
        }
    }

    var detailLabel: String {
        String(
            format: "Usage credits · %@%.2f left of %@%.2f",
            currencySymbol, remaining, currencySymbol, limit
        )
    }
}

/// Plan usage for one subscription account. Anything other than `ok` carries a
/// reason instead of numbers — the endpoint is unofficial, so failure is normal
/// and must read as "unknown", never as "0%".
struct UsageAccount: Decodable, Equatable {
    let account: String
    let status: String
    let limits: [UsageLimit]?
    let spend: UsageSpend?
    let ageSeconds: Int?
    let staleReason: String?
    let detail: String?

    var displayName: String { account.isEmpty ? "Subscription" : account }
    var isOK: Bool { status == "ok" }

    /// The 5-hour session limit is the one that actually stops work, so it is
    /// always the headline; anything else only stands in when it's absent.
    var headline: UsageLimit? {
        let all = limits ?? []
        return all.first { $0.kind == "session" }
            ?? all.max { ($0.percent, $0.isActive ? 1 : 0) < ($1.percent, $1.isActive ? 1 : 0) }
    }

    var problem: String? {
        switch status {
        case "ok": return nil
        case "token-expired": return "token expired — switch to this account to refresh"
        case "no-token": return "no stored login"
        default: return detail ?? "usage unavailable"
        }
    }

    var ageNote: String? {
        guard let ageSeconds, ageSeconds > 60 else { return nil }
        let minutes = ageSeconds / 60
        let base = minutes < 60 ? "cached \(minutes) min ago" : "cached \(minutes / 60)h ago"
        return staleReason.map { "\(base) — \($0)" } ?? base
    }
}

struct BillingState: Decodable, Equatable {
    let mode: String
    let kind: String
    let account: String?
    let awsProfile: String?
    let accounts: [String]
    let desktop: DesktopState?
    let awsSso: [SSOSessionState]?
    let bedrockProfile: String?
    let bedrockProfileSource: String?

    /// Names the profile a Bedrock switch would select, so the row says what a
    /// click will do rather than only what it did. An inherited profile depends
    /// on the environment of whoever launches Claude Code — and a login item
    /// doesn't inherit a shell's `AWS_PROFILE` — so it is never named.
    var bedrockRowTitle: String {
        if kind == "bedrock" {
            return "AWS Bedrock · \(awsProfile ?? "default")"
        }
        switch bedrockProfileSource {
        case "settings", "config":
            if let bedrockProfile { return "AWS Bedrock · \(bedrockProfile)" }
            return "AWS Bedrock"
        case "inherited":
            return "AWS Bedrock · inherited profile"
        default:
            return "AWS Bedrock"
        }
    }

    var ssoSessions: [SSOSessionState] { awsSso ?? [] }

    /// The SSO sessions live in a submenu, so the row that opens it carries the
    /// count of stale logins — otherwise nothing would look like it needed a
    /// refresh until you went looking.
    var ssoMenuTitle: String {
        let stale = ssoSessions.filter(\.needsRefresh).count
        guard stale > 0 else { return "AWS SSO sessions" }
        return "AWS SSO · \(stale) login\(stale == 1 ? "" : "s") to refresh"
    }

    var statusIconLetter: String {
        switch kind {
        case "api": return "A"
        case "bedrock": return "B"
        case "subscription": return "S"
        default: return "?"
        }
    }

    var displayName: String {
        switch kind {
        case "api":
            return "Anthropic API"
        case "bedrock":
            return "AWS Bedrock · \(awsProfile ?? "default")"
        case "subscription":
            return "Subscription · \(account ?? "Default")"
        default:
            return "Unknown billing mode"
        }
    }

    var symbolName: String {
        switch kind {
        case "api": return "key.fill"
        case "bedrock": return "cloud.fill"
        case "subscription": return "person.crop.circle.fill"
        default: return "questionmark.circle"
        }
    }
}

enum BillingAction: Equatable {
    case subscription(account: String?)
    case api
    case bedrock
    case desktop(account: String)

    var arguments: [String] {
        switch self {
        case let .subscription(account):
            return ["subscription"] + (account.map { [$0] } ?? [])
        case .api:
            return ["api"]
        case .bedrock:
            return ["bedrock"]
        case let .desktop(account):
            return ["desktop", account]
        }
    }

    var progressDescription: String {
        switch self {
        case let .subscription(account):
            return "Switching to Subscription · \(account ?? "Default")"
        case .api:
            return "Switching to Anthropic API"
        case .bedrock:
            return "Switching to AWS Bedrock"
        case let .desktop(account):
            return "Switching Claude Desktop to \(account)"
        }
    }

    var errorTitle: String {
        switch self {
        case .subscription:
            return "Couldn’t Switch Subscription"
        case .api:
            return "Couldn’t Switch to Anthropic API"
        case .bedrock:
            return "Couldn’t Switch to AWS Bedrock"
        case .desktop:
            return "Couldn’t Switch Claude Desktop"
        }
    }

    var requiresConfirmation: Bool {
        if case .desktop = self { return true }
        return false
    }
}

enum ManagementCommand: Equatable {
    case addAccount(String)
    case removeAccount(String)
    case configureBedrock
    case updateAPIKey
    case login
    case ssoLogin(String)

    var arguments: [String] {
        switch self {
        case let .addAccount(account):
            return ["add-account", account]
        case let .removeAccount(account):
            return ["remove-account", account, "--yes"]
        case .configureBedrock:
            return ["config"]
        case .updateAPIKey:
            return ["add-key"]
        case .login:
            return ["login"]
        case let .ssoLogin(session):
            return ["sso-login", session]
        }
    }

    var progressDescription: String {
        switch self {
        case let .ssoLogin(session):
            return "Refreshing the AWS SSO login for \(session)"
        case let .removeAccount(account):
            return "Removing account \(account)"
        case let .addAccount(account):
            return "Adding account \(account)"
        case .configureBedrock:
            return "Configuring AWS Bedrock"
        case .updateAPIKey:
            return "Updating the Anthropic API key"
        case .login:
            return "Signing in to Claude.ai"
        }
    }

    var errorTitle: String {
        switch self {
        case .removeAccount:
            return "Couldn’t Remove Account"
        case .addAccount:
            return "Couldn’t Add Account"
        case .configureBedrock:
            return "Couldn’t Open Bedrock Configuration"
        case .updateAPIKey:
            return "Couldn’t Open API Key Setup"
        case .login:
            return "Couldn’t Open Claude.ai Login"
        case .ssoLogin:
            return "Couldn’t Start the AWS SSO Login"
        }
    }
}

func isValidAccountName(_ name: String) -> Bool {
    !name.isEmpty && name.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
}

func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

func terminalScript(arguments: [String]) -> String {
    let quotedArguments = arguments.map(shellQuote).joined(separator: " ")
    return """
    #!/bin/zsh
    script_path="$0"
    rm -f "$script_path"
    source "$HOME/.claude-billing/claude_billing.sh"
    claude_billing \(quotedArguments)
    command_status=$?
    printf '\nPress Return to close this window.'
    read -r
    exit "$command_status"
    """
}

func conciseMenuMessage(_ message: String, limit: Int = 96) -> String {
    let singleLine = message
        .split(whereSeparator: \Character.isNewline)
        .first
        .map(String.init)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let fallback = singleLine.isEmpty ? "No additional details were provided." : singleLine
    guard fallback.count > limit else { return fallback }
    return String(fallback.prefix(max(1, limit - 1))) + "…"
}

func centeredDrawingOrigin(contentBounds: CGRect, in container: CGRect) -> CGPoint {
    CGPoint(
        x: container.midX - contentBounds.midX,
        y: container.midY - contentBounds.midY
    )
}

private struct CommandResult {
    let status: Int32
    let standardOutput: String
    let standardError: String
}

private enum BillingClientError: LocalizedError {
    case commandFailed(String)
    case invalidState(String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(message), let .invalidState(message):
            return message
        }
    }
}

private final class BillingClient {
    private let shellURL = URL(fileURLWithPath: "/bin/zsh")
    private let bridge = #"source "$HOME/.claude-billing/claude_billing.sh"; claude_billing "$@""#

    func loadState(completion: @escaping (Result<BillingState, Error>) -> Void) {
        run(arguments: ["status", "--json"]) { result in
            guard result.status == 0 else {
                completion(.failure(BillingClientError.commandFailed(result.message)))
                return
            }

            do {
                let state = try JSONDecoder().decode(BillingState.self, from: Data(result.standardOutput.utf8))
                completion(.success(state))
            } catch {
                completion(.failure(BillingClientError.invalidState(
                    "Could not read claude-billing status. \(error.localizedDescription)"
                )))
            }
        }
    }

    /// Reads the shell utility's usage cache; it only reaches the network when
    /// an entry is stale, or when `refresh` forces it.
    func loadUsage(refresh: Bool, completion: @escaping (Result<[UsageAccount], Error>) -> Void) {
        run(arguments: ["usage", "--json"] + (refresh ? ["--refresh"] : [])) { result in
            guard result.status == 0 else {
                completion(.failure(BillingClientError.commandFailed(result.message)))
                return
            }
            do {
                let usage = try JSONDecoder().decode([UsageAccount].self, from: Data(result.standardOutput.utf8))
                completion(.success(usage))
            } catch {
                completion(.failure(BillingClientError.invalidState(
                    "Could not read plan usage. \(error.localizedDescription)"
                )))
            }
        }
    }

    func perform(_ action: BillingAction, completion: @escaping (Result<String, Error>) -> Void) {
        perform(arguments: action.arguments, completion: completion)
    }

    func perform(_ command: ManagementCommand, completion: @escaping (Result<String, Error>) -> Void) {
        perform(arguments: command.arguments, completion: completion)
    }

    func openInTerminal(_ command: ManagementCommand) throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-billing-\(UUID().uuidString).command")
        do {
            try terminalScript(arguments: command.arguments).write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            guard NSWorkspace.shared.open(scriptURL) else {
                throw BillingClientError.commandFailed("Terminal could not open the claude-billing command.")
            }
        } catch {
            try? FileManager.default.removeItem(at: scriptURL)
            throw error
        }
    }

    private func perform(arguments: [String], completion: @escaping (Result<String, Error>) -> Void) {
        run(arguments: arguments) { result in
            guard result.status == 0 else {
                completion(.failure(BillingClientError.commandFailed(result.message)))
                return
            }
            completion(.success(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
    }

    private func run(arguments: [String], completion: @escaping (CommandResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.executableURL = self.shellURL
            process.arguments = ["-c", self.bridge, "claude-billing-menubar"] + arguments
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = environment

            do {
                try process.run()
                process.waitUntilExit()
                completion(CommandResult(
                    status: process.terminationStatus,
                    standardOutput: String(
                        data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    ) ?? "",
                    standardError: String(
                        data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    ) ?? ""
                ))
            } catch {
                completion(CommandResult(status: 1, standardOutput: "", standardError: error.localizedDescription))
            }
        }
    }
}

private extension CommandResult {
    var message: String {
        let error = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if !error.isEmpty { return error }
        let output = standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? "claude-billing did not return an error message." : output
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let client = BillingClient()
    private var statusItem: NSStatusItem!
    private var currentState: BillingState?
    private var usage: [UsageAccount] = []
    private var isSwitching = false
    private var isLoadingUsage = false
    private var refreshTimer: Timer?
    private var usageTimer: Timer?
    private var progressIndicator: NSProgressIndicator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setStatusIcon(letter: "?", description: "Claude Billing — Loading")
        rebuildMenu()
        refreshState(showError: false)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refreshState(showError: false)
        }
        // Usage can involve a network call, so it runs on its own slower timer
        // and never gates the billing state the menu is really about.
        refreshUsage(force: false)
        usageTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshUsage(force: false)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        usageTimer?.invalidate()
    }

    private func refreshUsage(force: Bool) {
        guard !isLoadingUsage else { return }
        isLoadingUsage = true
        client.loadUsage(refresh: force) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoadingUsage = false
                // A usage failure is not worth an alert; the row says so itself.
                if case let .success(usage) = result {
                    self.usage = usage
                    self.rebuildMenu()
                }
            }
        }
    }

    private func refreshState(showError: Bool) {
        guard !isSwitching else { return }
        client.loadState { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case let .success(state):
                    self.currentState = state
                    self.setStatusIcon(
                        letter: state.statusIconLetter,
                        description: "Claude Code CLI — \(state.displayName)"
                    )
                    self.rebuildMenu()
                case let .failure(error):
                    self.setStatusIcon(letter: "!", description: "Claude Billing — Error")
                    self.rebuildMenu(errorMessage: error.localizedDescription)
                    if showError { self.showError(error) }
                }
            }
        }
    }

    private func rebuildMenu(errorMessage: String? = nil) {
        let menu = NSMenu()

        if let errorMessage {
            let errorItem = NSMenuItem(title: "Unable to load billing state", action: nil, keyEquivalent: "")
            errorItem.image = menuImage(named: "exclamationmark.triangle.fill", description: "Error")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
            let detailItem = NSMenuItem(title: conciseMenuMessage(errorMessage), action: nil, keyEquivalent: "")
            detailItem.isEnabled = false
            menu.addItem(detailItem)
            menu.addItem(.separator())
        } else if let currentState {
            // One header for the provider group whose rows can't name
            // themselves; the checkmark already says which mode is current, so
            // no separate current-state row is needed.
            menu.addItem(sectionItem(title: currentState.accounts.isEmpty
                ? "Claude Code CLI subscription"
                : "Claude Code CLI subscriptions"))

            if currentState.accounts.isEmpty {
                menu.addItem(actionItem(
                    title: "Claude Subscription",
                    action: .subscription(account: nil),
                    isCurrent: currentState.kind == "subscription",
                    symbolName: "person.crop.circle"
                ))
            } else {
                for account in currentState.accounts {
                    menu.addItem(actionItem(
                        title: account,
                        action: .subscription(account: account),
                        isCurrent: currentState.mode == "sub:\(account)",
                        symbolName: "person.crop.circle"
                    ))
                }
            }

            if !usage.isEmpty {
                menu.addItem(usageMenuItem(activeAccount: currentState.account))
            }

            // Bedrock and the API key are separate providers, so they get their
            // own sections rather than one "other billing" bucket. Bedrock
            // leads because it carries the SSO sessions and sees more use.
            menu.addItem(.separator())
            menu.addItem(actionItem(
                title: currentState.bedrockRowTitle,
                action: .bedrock,
                isCurrent: currentState.kind == "bedrock",
                symbolName: "cloud"
            ))
            if !currentState.ssoSessions.isEmpty {
                menu.addItem(ssoMenuItem(for: currentState))
            }

            menu.addItem(.separator())
            menu.addItem(actionItem(
                title: "Anthropic API",
                action: .api,
                isCurrent: currentState.kind == "api",
                symbolName: "key"
            ))
            if currentState.desktop?.available == true {
                menu.addItem(.separator())
                menu.addItem(desktopMenuItem(for: currentState))
            }
            menu.addItem(.separator())
            menu.addItem(managementMenuItem(for: currentState))
            menu.addItem(.separator())
        }

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshClicked), keyEquivalent: "r")
        refreshItem.image = menuImage(named: "arrow.clockwise", description: "Refresh")
        refreshItem.target = self
        refreshItem.isEnabled = !isSwitching
        menu.addItem(refreshItem)

        let quitItem = NSMenuItem(title: "Quit Claude Billing", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.image = menuImage(named: "power", description: "Quit")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func sectionItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// Read-only detail under an item — profile lists, usage figures. Smaller
    /// secondary text reads as detail; a plain disabled row reads as a command
    /// you're not allowed to use.
    private func detailItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        return item
    }

    /// A metered detail row: the bar in the icon column, then the percentage in
    /// monospaced digits so the numbers align, then the label.
    private func meterItem(percent: Int, level: UsageLevel, label: String) -> NSMenuItem {
        let shown = min(max(percent, 0), 100)
        let percentText = String(format: "%3d%%  ", shown)
        let item = NSMenuItem(title: percentText + label, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.image = usageBarImage(percent: percent, color: level.color)

        let attributed = NSMutableAttributedString(string: percentText, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ])
        attributed.append(NSAttributedString(string: label, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        item.attributedTitle = attributed
        item.toolTip = label
        item.setAccessibilityLabel("\(label): \(shown) percent used")
        return item
    }

    private func actionItem(
        title: String,
        action: BillingAction,
        isCurrent: Bool,
        symbolName: String
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(switchClicked(_:)), keyEquivalent: "")
        if action.requiresConfirmation {
            item.title += "…"
        }
        item.target = self
        item.representedObject = action
        item.image = menuImage(named: symbolName, description: title)
        item.state = isCurrent ? .on : .off
        // The current mode stays enabled — greying it out reads as "unavailable"
        // rather than "already selected". switchClicked ignores clicks on it, so
        // re-running a transition can't disturb a working setup.
        item.isEnabled = !isSwitching
        return item
    }

    /// Claude Desktop owns exactly one subscription login, independent of CLI
    /// billing. Its accounts live in a submenu so the same account name can't
    /// appear twice at the top level meaning two different things.
    private func desktopMenuItem(for state: BillingState) -> NSMenuItem {
        let owner = state.desktop?.account ?? "Unknown account"
        let item = NSMenuItem(title: "Claude Desktop · \(owner)", action: nil, keyEquivalent: "")
        item.image = menuImage(named: "desktopcomputer", description: "Claude Desktop")

        let submenu = NSMenu()
        if state.accounts.isEmpty {
            submenu.addItem(detailItem(title: "Register subscription accounts from the CLI first"))
        } else {
            for account in state.accounts {
                submenu.addItem(actionItem(
                    title: account,
                    action: .desktop(account: account),
                    isCurrent: state.desktop?.account == account,
                    symbolName: "person.crop.circle"
                ))
            }
        }
        item.submenu = submenu
        return item
    }

    /// Plan usage for the subscription accounts. The row summarises the active
    /// account (the plan being spent right now) and the submenu breaks every
    /// account down. Figures come from an unofficial endpoint, so the submenu
    /// says so and unavailable accounts show a reason instead of a number.
    private func usageMenuItem(activeAccount: String?) -> NSMenuItem {
        let active = usage.first { $0.account == (activeAccount ?? "") } ?? usage.first
        let item = NSMenuItem(title: "Plan usage", action: nil, keyEquivalent: "")
        item.image = menuImage(named: "chart.bar", description: "Plan usage")
        item.toolTip = "Subscription plan usage for the active Claude Code CLI account."

        // The bar carries the headline number; which limit it is, and when it
        // clears, belong on hover rather than in the row.
        if let active, let headline = active.headline, active.isOK {
            // The reset time earns its place in the row: it says how long you'd
            // have to wait, which the bar alone can't.
            let text = "Plan usage · \(headline.percent)%\(headline.statusSuffix)  "
            item.title = text
            // Keep the shared icon column, and trail the bar after the text so
            // this row's label lines up with every other row's.
            let attributed = NSMutableAttributedString(string: text, attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.labelColor,
            ])
            attributed.append(usageBarAttachment(
                percent: headline.percent,
                color: headline.level.color
            ))
            item.attributedTitle = attributed
            item.toolTip = "\(active.displayName): \(headline.detailLabel) · \(headline.percent)% used"
            item.setAccessibilityLabel("Plan usage: \(headline.detailLabel), \(headline.percent) percent used")
        } else if let active, let problem = active.problem {
            item.title = "Plan usage · \(problem.split(separator: "—").first?.trimmingCharacters(in: .whitespaces) ?? problem)"
            item.image = menuImage(named: "exclamationmark.triangle.fill", description: "Plan usage unavailable")
            item.toolTip = "\(active.displayName): \(problem)"
        }

        let submenu = NSMenu()
        for (index, account) in usage.enumerated() {
            if index > 0 { submenu.addItem(.separator()) }
            submenu.addItem(sectionItem(title: account.displayName))
            if let problem = account.problem {
                submenu.addItem(detailItem(title: problem))
                continue
            }
            for limit in account.limits ?? [] {
                submenu.addItem(meterItem(
                    percent: limit.percent,
                    level: limit.level,
                    label: limit.detailLabel
                ))
            }
            if let spend = account.spend {
                submenu.addItem(meterItem(
                    percent: spend.percent,
                    level: spend.level,
                    label: spend.detailLabel
                ))
            }
            if let ageNote = account.ageNote {
                submenu.addItem(detailItem(title: ageNote))
            }
        }
        // No refresh action or source note here: the menu's own Refresh forces a
        // usage fetch, and the endpoint caveat lives in the docs and CLI output.
        item.submenu = submenu
        return item
    }

    /// AWS SSO expiry sits in its own submenu so the Bedrock row stays a
    /// one-click switch — AppKit ignores the action of an item that owns a
    /// submenu. Each session lists the AWS profiles it signs in, because the
    /// session name is just a label from ~/.aws/config and says nothing about
    /// which accounts it covers.
    private func ssoMenuItem(for state: BillingState) -> NSMenuItem {
        let needsRefresh = state.ssoSessions.contains(where: \.needsRefresh)
        let item = NSMenuItem(title: state.ssoMenuTitle, action: nil, keyEquivalent: "")
        item.image = menuImage(
            named: needsRefresh ? "exclamationmark.triangle.fill" : "clock.arrow.circlepath",
            description: state.ssoMenuTitle
        )

        let submenu = NSMenu()
        for (index, session) in state.ssoSessions.enumerated() {
            if index > 0 { submenu.addItem(.separator()) }
            let sessionItem = NSMenuItem(
                title: "\(session.menuTitle)…",
                action: #selector(ssoLoginClicked(_:)),
                keyEquivalent: ""
            )
            sessionItem.target = self
            sessionItem.representedObject = session.name
            sessionItem.image = menuImage(named: session.symbolName, description: session.detail)
            sessionItem.toolTip = "Sign in to this AWS SSO portal again in Terminal."
            sessionItem.isEnabled = !isSwitching
            submenu.addItem(sessionItem)
            submenu.addItem(detailItem(title: session.profileSummary))
        }
        submenu.addItem(.separator())
        submenu.addItem(detailItem(title: "One login per SSO portal, shared by its profiles"))
        item.submenu = submenu
        return item
    }

    private func managementMenuItem(for state: BillingState) -> NSMenuItem {
        let item = NSMenuItem(title: "Manage Claude Code CLI", action: nil, keyEquivalent: "")
        item.image = menuImage(named: "gearshape", description: "Manage Claude Code CLI")
        let submenu = NSMenu()

        submenu.addItem(menuActionItem(
            title: "Add Subscription Account…",
            action: #selector(addAccountClicked),
            symbolName: "person.crop.circle.badge.plus"
        ))

        let removeItem = NSMenuItem(title: "Remove Subscription Account", action: nil, keyEquivalent: "")
        removeItem.image = menuImage(named: "person.crop.circle.badge.minus", description: "Remove Subscription Account")
        let removeMenu = NSMenu()
        if state.accounts.isEmpty {
            let emptyItem = NSMenuItem(title: "No Registered Accounts", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            removeMenu.addItem(emptyItem)
        } else {
            for account in state.accounts {
                let accountItem = NSMenuItem(
                    title: "\(account)…",
                    action: #selector(removeAccountClicked(_:)),
                    keyEquivalent: ""
                )
                accountItem.target = self
                accountItem.representedObject = account
                accountItem.image = menuImage(named: "person.crop.circle", description: account)
                accountItem.isEnabled = !isSwitching
                removeMenu.addItem(accountItem)
            }
        }
        removeItem.submenu = removeMenu
        submenu.addItem(removeItem)
        submenu.addItem(.separator())

        submenu.addItem(menuActionItem(
            title: "Configure AWS Bedrock…",
            action: #selector(configureBedrockClicked),
            symbolName: "cloud"
        ))
        submenu.addItem(menuActionItem(
            title: "Update Anthropic API Key…",
            action: #selector(updateAPIKeyClicked),
            symbolName: "key"
        ))
        submenu.addItem(menuActionItem(
            title: "Sign In to Claude.ai…",
            action: #selector(loginClicked),
            symbolName: "person.crop.circle.badge.checkmark"
        ))
        submenu.addItem(.separator())

        let terminalNote = NSMenuItem(title: "Interactive setup opens in Terminal", action: nil, keyEquivalent: "")
        terminalNote.isEnabled = false
        submenu.addItem(terminalNote)

        item.submenu = submenu
        return item
    }

    private func menuActionItem(title: String, action: Selector, symbolName: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = menuImage(named: symbolName, description: title)
        item.isEnabled = !isSwitching
        return item
    }

    @objc private func switchClicked(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? BillingAction, !isSwitching else { return }
        // Clicking the mode you're already on is a no-op, not a re-transition.
        guard sender.state != .on else { return }
        if case let .desktop(account) = action, !confirmDesktopSwitch(to: account) {
            return
        }
        isSwitching = true
        setSwitchingIndicator(description: "Claude Billing — \(action.progressDescription)…")
        rebuildMenu()

        client.perform(action) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSwitching = false
                switch result {
                case .success:
                    self.refreshState(showError: true)
                case let .failure(error):
                    self.showError(error, title: action.errorTitle)
                    self.refreshState(showError: false)
                }
            }
        }
    }

    @objc private func refreshClicked() {
        refreshState(showError: true)
        refreshUsage(force: true)
    }


    @objc private func addAccountClicked() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = symbolAlertIcon(named: "person.crop.circle.badge.plus", description: "Add Account")
        alert.messageText = "Add a Claude Code CLI subscription account"
        alert.informativeText = "Choose a short name such as work or personal. Authentication continues in Terminal."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        nameField.placeholderString = "Account name"
        nameField.setAccessibilityLabel("Account name")
        alert.accessoryView = nameField
        alert.window.initialFirstResponder = nameField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let account = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidAccountName(account) else {
            showError(
                BillingClientError.invalidState("Use only letters, numbers, hyphens, and underscores."),
                title: "Invalid Account Name"
            )
            return
        }
        guard currentState?.accounts.contains(account) != true else {
            showError(
                BillingClientError.invalidState("An account named \(account) is already registered."),
                title: "Account Already Exists"
            )
            return
        }
        openInTerminal(.addAccount(account))
    }

    @objc private func removeAccountClicked(_ sender: NSMenuItem) {
        guard let account = sender.representedObject as? String, !isSwitching else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = symbolAlertIcon(named: "person.crop.circle.badge.minus", description: "Remove Account")
        alert.messageText = "Remove \(account) from Claude Billing?"
        alert.informativeText = "Stored Claude Code CLI credentials and any saved Claude Desktop session for this account will be removed. A live login stays signed in but will no longer be managed."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performManagement(.removeAccount(account))
    }

    @objc private func configureBedrockClicked() {
        openInTerminal(.configureBedrock)
    }

    @objc private func updateAPIKeyClicked() {
        openInTerminal(.updateAPIKey)
    }

    @objc private func loginClicked() {
        openInTerminal(.login)
    }

    // `aws sso login` opens a browser and waits for approval, so it belongs in
    // Terminal like the other interactive flows rather than in a blocking
    // in-app process.
    @objc private func ssoLoginClicked(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? String, !isSwitching else { return }
        openInTerminal(.ssoLogin(session))
    }

    private func openInTerminal(_ command: ManagementCommand) {
        do {
            try client.openInTerminal(command)
        } catch {
            showError(error, title: command.errorTitle)
        }
    }

    private func performManagement(_ command: ManagementCommand) {
        isSwitching = true
        setSwitchingIndicator(description: "Claude Billing — \(command.progressDescription)…")
        rebuildMenu()
        client.perform(command) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSwitching = false
                switch result {
                case .success:
                    self.refreshState(showError: true)
                case let .failure(error):
                    self.showError(error, title: command.errorTitle)
                    self.refreshState(showError: false)
                }
            }
        }
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }

    private func showError(_ error: Error, title: String = "Couldn’t Load Billing Status") {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = symbolAlertIcon(named: "exclamationmark.triangle.fill", description: "Error")
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private func confirmDesktopSwitch(to account: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = claudeDesktopIcon()
        alert.messageText = "Switch Claude Desktop to \(account)?"
        if let owner = currentState?.desktop?.account {
            alert.informativeText = "If it’s running, Claude Desktop will quit, move its login from \(owner) to \(account), and reopen."
        } else {
            alert.informativeText = "If it’s running, Claude Desktop will quit, preserve its current login safely, switch accounts, and reopen."
        }
        alert.addButton(withTitle: "Switch")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func claudeDesktopIcon() -> NSImage? {
        if let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.anthropic.claudefordesktop"
        ), let icon = NSWorkspace.shared.icon(forFile: appURL.path).copy() as? NSImage {
            icon.size = NSSize(width: 64, height: 64)
            icon.accessibilityDescription = "Claude Desktop"
            return icon
        }
        return symbolAlertIcon(named: "desktopcomputer", description: "Claude Desktop")
    }

    private func symbolAlertIcon(named name: String, description: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(configuration)
    }

    private func setStatusIcon(letter: String, description: String) {
        guard let button = statusItem.button else { return }
        removeProgressIndicator()
        button.title = ""
        button.image = letterBadgeImage(letter: letter)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }

    private func setSwitchingIndicator(description: String) {
        guard let button = statusItem.button else { return }
        removeProgressIndicator()
        button.title = ""
        button.image = nil
        button.toolTip = description
        button.setAccessibilityLabel(description)

        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isIndeterminate = true
        indicator.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 14),
            indicator.heightAnchor.constraint(equalToConstant: 14),
        ])
        indicator.startAnimation(nil)
        progressIndicator = indicator
    }

    private func removeProgressIndicator() {
        progressIndicator?.stopAnimation(nil)
        progressIndicator?.removeFromSuperview()
        progressIndicator = nil
    }

    private func letterBadgeImage(letter: String) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let badgeRect = rect.insetBy(dx: 1.25, dy: 1.25)
            let badge = NSBezierPath(roundedRect: badgeRect, xRadius: 4.25, yRadius: 4.25)
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            badge.fill()
            badge.lineWidth = 1.35
            NSColor.labelColor.setStroke()
            badge.stroke()

            let baseFont = NSFont.systemFont(ofSize: 10.5, weight: .bold)
            let roundedFont = baseFont.fontDescriptor.withDesign(.rounded)
                .flatMap { NSFont(descriptor: $0, size: 10.5) } ?? baseFont
            let attributes: [NSAttributedString.Key: Any] = [
                .font: roundedFont,
                .foregroundColor: NSColor.labelColor,
            ]
            let text = NSAttributedString(string: letter, attributes: attributes)
            let line = CTLineCreateWithAttributedString(text)
            let textBounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            let textOrigin = centeredDrawingOrigin(contentBounds: textBounds, in: badgeRect)
            if let context = NSGraphicsContext.current?.cgContext {
                context.saveGState()
                context.textPosition = textOrigin
                CTLineDraw(line, context)
                context.restoreGState()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Claude Billing \(letter)"
        return image
    }

    private func menuImage(named name: String, description: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        image?.isTemplate = true
        return image
    }
}

private let app = NSApplication.shared
private let appDelegate = AppDelegate()
app.delegate = appDelegate
app.run()

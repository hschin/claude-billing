import AppKit
import Foundation

struct DesktopState: Decodable, Equatable {
    let available: Bool
    let account: String?
}

struct BillingState: Decodable, Equatable {
    let mode: String
    let kind: String
    let account: String?
    let awsProfile: String?
    let accounts: [String]
    let desktop: DesktopState?

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

    var claudeCodeDisplayName: String {
        "Claude Code CLI · \(displayName)"
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
        }
    }

    var progressDescription: String {
        switch self {
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
    private var isSwitching = false
    private var refreshTimer: Timer?
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
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
            let currentItem = NSMenuItem(title: currentState.claudeCodeDisplayName, action: nil, keyEquivalent: "")
            currentItem.image = menuImage(named: currentState.symbolName, description: currentState.displayName)
            currentItem.isEnabled = false
            menu.addItem(currentItem)
            menu.addItem(.separator())

            menu.addItem(sectionItem(title: currentState.accounts.isEmpty ? "CLI subscription" : "CLI subscriptions"))

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

            menu.addItem(.separator())
            menu.addItem(sectionItem(title: "Other CLI billing"))
            menu.addItem(actionItem(
                title: "Anthropic API",
                action: .api,
                isCurrent: currentState.kind == "api",
                symbolName: "key"
            ))
            let bedrockTitle = currentState.kind == "bedrock"
                ? "AWS Bedrock · \(currentState.awsProfile ?? "default")"
                : "AWS Bedrock"
            menu.addItem(actionItem(
                title: bedrockTitle,
                action: .bedrock,
                isCurrent: currentState.kind == "bedrock",
                symbolName: "cloud"
            ))
            menu.addItem(.separator())

            let restartItem = NSMenuItem(title: "CLI billing changes require a Claude Code restart", action: nil, keyEquivalent: "")
            restartItem.image = menuImage(named: "exclamationmark.circle", description: "Restart required")
            restartItem.isEnabled = false
            menu.addItem(restartItem)

            if currentState.desktop?.available == true {
                menu.addItem(.separator())
                let desktopOwner = currentState.desktop?.account ?? "Unknown account"
                let desktopSection = sectionItem(title: "Claude Desktop · \(desktopOwner)")
                desktopSection.image = menuImage(named: "desktopcomputer", description: "Claude Desktop")
                menu.addItem(desktopSection)

                if currentState.accounts.isEmpty {
                    let emptyItem = NSMenuItem(title: "Register subscription accounts from the CLI first", action: nil, keyEquivalent: "")
                    emptyItem.isEnabled = false
                    menu.addItem(emptyItem)
                } else {
                    for account in currentState.accounts {
                        menu.addItem(actionItem(
                            title: account,
                            action: .desktop(account: account),
                            isCurrent: currentState.desktop?.account == account,
                            symbolName: "person.crop.circle"
                        ))
                    }
                }
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
        item.isEnabled = !isCurrent && !isSwitching
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

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let baseFont = NSFont.systemFont(ofSize: 10.5, weight: .bold)
            let roundedFont = baseFont.fontDescriptor.withDesign(.rounded)
                .flatMap { NSFont(descriptor: $0, size: 10.5) } ?? baseFont
            let attributes: [NSAttributedString.Key: Any] = [
                .font: roundedFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
            let text = NSAttributedString(string: letter, attributes: attributes)
            let textSize = text.size()
            text.draw(at: NSPoint(
                x: floor((rect.width - textSize.width) / 2),
                y: floor((rect.height - textSize.height) / 2) - 0.25
            ))
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

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
        run(arguments: action.arguments) { result in
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
        client.loadState { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case let .success(state):
                    self.currentState = state
                    self.setStatusIcon(
                        letter: state.statusIconLetter,
                        description: "Claude Billing — \(state.displayName)"
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
            let detailItem = NSMenuItem(title: errorMessage, action: nil, keyEquivalent: "")
            detailItem.isEnabled = false
            detailItem.indentationLevel = 1
            menu.addItem(detailItem)
            menu.addItem(.separator())
        } else if let currentState {
            let currentItem = NSMenuItem(title: "Current: \(currentState.displayName)", action: nil, keyEquivalent: "")
            currentItem.image = menuImage(named: currentState.symbolName, description: currentState.displayName)
            currentItem.isEnabled = false
            menu.addItem(currentItem)
            menu.addItem(.separator())

            menu.addItem(sectionItem(title: currentState.accounts.isEmpty ? "Subscription" : "Subscriptions"))

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

            menu.addItem(sectionItem(title: "Other billing"))
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

            let restartItem = NSMenuItem(title: "Billing changes require a Claude Code restart", action: nil, keyEquivalent: "")
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
                    emptyItem.indentationLevel = 1
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
        item.target = self
        item.representedObject = action
        item.image = menuImage(named: symbolName, description: title)
        item.indentationLevel = 1
        item.state = isCurrent ? .on : .off
        item.isEnabled = !isCurrent && !isSwitching
        return item
    }

    @objc private func switchClicked(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? BillingAction, !isSwitching else { return }
        if case let .desktop(account) = action, !confirmDesktopSwitch(to: account) {
            return
        }
        isSwitching = true
        statusItem.button?.toolTip = "Claude Billing — Switching…"
        rebuildMenu()

        client.perform(action) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSwitching = false
                switch result {
                case .success:
                    self.refreshState(showError: true)
                case let .failure(error):
                    self.showError(error)
                    self.refreshState(showError: false)
                }
            }
        }
    }

    @objc private func refreshClicked() {
        refreshState(showError: true)
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }

    private func showError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Claude Billing"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private func confirmDesktopSwitch(to account: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Switch Claude Desktop to \(account)?"
        if let owner = currentState?.desktop?.account {
            alert.informativeText = "Claude Desktop will close so its login can move from \(owner) to \(account)."
        } else {
            alert.informativeText = "Claude Desktop will close. Its current login will be preserved safely before switching."
        }
        alert.addButton(withTitle: "Switch")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func setStatusIcon(letter: String, description: String) {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.image = letterBadgeImage(letter: letter)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.toolTip = description
        button.setAccessibilityLabel(description)
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

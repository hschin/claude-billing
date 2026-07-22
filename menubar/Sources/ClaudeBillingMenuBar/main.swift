import AppKit
import Foundation

struct BillingState: Decodable, Equatable {
    let mode: String
    let kind: String
    let account: String?
    let awsProfile: String?
    let accounts: [String]

    var statusItemTitle: String {
        switch kind {
        case "api":
            return "Claude · API"
        case "bedrock":
            return "Claude · AWS \(awsProfile ?? "default")"
        case "subscription":
            return "Claude · \(account ?? "Subscription")"
        default:
            return "Claude Billing"
        }
    }
}

enum BillingAction: Equatable {
    case subscription(account: String?)
    case api
    case bedrock

    var arguments: [String] {
        switch self {
        case let .subscription(account):
            return ["subscription"] + (account.map { [$0] } ?? [])
        case .api:
            return ["api"]
        case .bedrock:
            return ["bedrock"]
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

    func switchBilling(to action: BillingAction, completion: @escaping (Result<String, Error>) -> Void) {
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
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Claude · …"
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
                    self.statusItem.button?.title = state.statusItemTitle
                    self.rebuildMenu()
                case let .failure(error):
                    self.statusItem.button?.title = "Claude · !"
                    self.rebuildMenu(errorMessage: error.localizedDescription)
                    if showError { self.showError(error) }
                }
            }
        }
    }

    private func rebuildMenu(errorMessage: String? = nil) {
        let menu = NSMenu()

        if let errorMessage {
            let errorItem = NSMenuItem(title: errorMessage, action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
            menu.addItem(.separator())
        } else if let currentState {
            let currentItem = NSMenuItem(title: "Current: \(currentState.statusItemTitle)", action: nil, keyEquivalent: "")
            currentItem.isEnabled = false
            menu.addItem(currentItem)
            menu.addItem(.separator())

            let sectionItem = NSMenuItem(title: "Switch billing mode", action: nil, keyEquivalent: "")
            sectionItem.isEnabled = false
            menu.addItem(sectionItem)

            if currentState.accounts.isEmpty {
                menu.addItem(actionItem(
                    title: "Claude Subscription",
                    action: .subscription(account: nil),
                    isCurrent: currentState.kind == "subscription"
                ))
            } else {
                for account in currentState.accounts {
                    menu.addItem(actionItem(
                        title: "Subscription · \(account)",
                        action: .subscription(account: account),
                        isCurrent: currentState.mode == "sub:\(account)"
                    ))
                }
            }

            menu.addItem(actionItem(title: "Anthropic API", action: .api, isCurrent: currentState.kind == "api"))
            let bedrockTitle = currentState.kind == "bedrock"
                ? "AWS Bedrock · \(currentState.awsProfile ?? "default")"
                : "AWS Bedrock"
            menu.addItem(actionItem(title: bedrockTitle, action: .bedrock, isCurrent: currentState.kind == "bedrock"))
            menu.addItem(.separator())
        }

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshClicked), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.isEnabled = !isSwitching
        menu.addItem(refreshItem)

        let quitItem = NSMenuItem(title: "Quit Claude Billing", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func actionItem(title: String, action: BillingAction, isCurrent: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(switchClicked(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action
        item.state = isCurrent ? .on : .off
        item.isEnabled = !isCurrent && !isSwitching
        return item
    }

    @objc private func switchClicked(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? BillingAction, !isSwitching else { return }
        isSwitching = true
        statusItem.button?.title = "Claude · Switching…"
        rebuildMenu()

        client.switchBilling(to: action) { [weak self] result in
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
}

private let app = NSApplication.shared
private let appDelegate = AppDelegate()
app.delegate = appDelegate
app.run()

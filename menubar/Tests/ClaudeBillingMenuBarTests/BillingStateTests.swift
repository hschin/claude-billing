import XCTest
@testable import ClaudeBillingMenuBar

final class BillingStateTests: XCTestCase {
    func testEachBillingKindHasADistinctMenuBarLetter() {
        let subscription = BillingState(mode: "sub:work", kind: "subscription", account: "work", awsProfile: nil, accounts: ["work"], desktop: nil)
        let api = BillingState(mode: "api", kind: "api", account: nil, awsProfile: nil, accounts: [], desktop: nil)
        let bedrock = BillingState(mode: "bedrock:work-aws", kind: "bedrock", account: nil, awsProfile: "work-aws", accounts: [], desktop: nil)

        XCTAssertEqual(subscription.statusIconLetter, "S")
        XCTAssertEqual(api.statusIconLetter, "A")
        XCTAssertEqual(bedrock.statusIconLetter, "B")
    }

    func testBedrockDisplayIncludesTheEffectiveAWSProfile() throws {
        let data = Data(#"{"mode":"bedrock:work-aws","kind":"bedrock","account":null,"awsProfile":"work-aws","accounts":["work","personal"]}"#.utf8)

        let state = try JSONDecoder().decode(BillingState.self, from: data)

        XCTAssertEqual(state.displayName, "AWS Bedrock · work-aws")
        XCTAssertEqual(state.claudeCodeDisplayName, "Claude Code CLI · AWS Bedrock · work-aws")
    }

    func testSubscriptionActionPassesTheAccountAsASeparateArgument() {
        XCTAssertEqual(
            BillingAction.subscription(account: "work").arguments,
            ["subscription", "work"]
        )
    }

    func testDesktopActionUsesTheIndependentDesktopCommand() {
        XCTAssertEqual(
            BillingAction.desktop(account: "personal").arguments,
            ["desktop", "personal"]
        )
    }

    func testDesktopActionsRequireConfirmation() {
        XCTAssertTrue(BillingAction.desktop(account: "personal").requiresConfirmation)
        XCTAssertFalse(BillingAction.api.requiresConfirmation)
        XCTAssertFalse(BillingAction.bedrock.requiresConfirmation)
        XCTAssertFalse(BillingAction.subscription(account: "work").requiresConfirmation)
    }

    func testActionsDescribeProgressAndFailureSpecifically() {
        XCTAssertEqual(
            BillingAction.desktop(account: "personal").progressDescription,
            "Switching Claude Desktop to personal"
        )
        XCTAssertEqual(BillingAction.bedrock.errorTitle, "Couldn’t Switch to AWS Bedrock")
    }

    func testConciseMenuMessageUsesOneTruncatedLine() {
        XCTAssertEqual(
            conciseMenuMessage("A detailed first line that is too long\nsecond line", limit: 20),
            "A detailed first li…"
        )
        XCTAssertEqual(conciseMenuMessage("\n"), "No additional details were provided.")
    }

    func testDesktopStateDecodesSeparatelyFromBillingState() throws {
        let data = Data(#"{"mode":"api","kind":"api","account":null,"awsProfile":null,"accounts":["work","personal"],"desktop":{"available":true,"account":"personal"}}"#.utf8)

        let state = try JSONDecoder().decode(BillingState.self, from: data)

        XCTAssertEqual(state.desktop?.account, "personal")
    }

    func testManagementCommandsDelegateToTheCLI() {
        XCTAssertEqual(
            ManagementCommand.removeAccount("work").arguments,
            ["remove-account", "work", "--yes"]
        )
        XCTAssertEqual(ManagementCommand.configureBedrock.arguments, ["config"])
        XCTAssertEqual(ManagementCommand.updateAPIKey.arguments, ["add-key"])
        XCTAssertEqual(ManagementCommand.login.arguments, ["login"])
    }

    func testAccountNameValidationMatchesTheCLI() {
        XCTAssertTrue(isValidAccountName("work-2_primary"))
        XCTAssertFalse(isValidAccountName(""))
        XCTAssertFalse(isValidAccountName("work account"))
        XCTAssertFalse(isValidAccountName("work;open"))
    }

    func testTerminalScriptQuotesEveryArgument() {
        let script = terminalScript(arguments: ["add-account", "team's"])

        XCTAssertTrue(script.contains("claude_billing 'add-account' 'team'\"'\"'s'"))
        XCTAssertTrue(script.contains("source \"$HOME/.claude-billing/claude_billing.sh\""))
    }
}

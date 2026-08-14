import XCTest
@testable import ClaudeBillingMenuBar

final class BillingStateTests: XCTestCase {
    func testEachBillingKindHasADistinctMenuBarLetter() {
        let subscription = BillingState(mode: "sub:work", kind: "subscription", account: "work", awsProfile: nil, accounts: ["work"], desktop: nil, awsSso: nil)
        let api = BillingState(mode: "api", kind: "api", account: nil, awsProfile: nil, accounts: [], desktop: nil, awsSso: nil)
        let bedrock = BillingState(mode: "bedrock:work-aws", kind: "bedrock", account: nil, awsProfile: "work-aws", accounts: [], desktop: nil, awsSso: nil)

        XCTAssertEqual(subscription.statusIconLetter, "S")
        XCTAssertEqual(api.statusIconLetter, "A")
        XCTAssertEqual(bedrock.statusIconLetter, "B")
    }

    func testStatusIconContentIsCenteredWithinTheBadge() {
        let badge = CGRect(x: 1.25, y: 1.25, width: 15.5, height: 15.5)
        let glyphBounds = CGRect(x: -0.4, y: 1.1, width: 7.2, height: 8.6)

        let origin = centeredDrawingOrigin(contentBounds: glyphBounds, in: badge)

        XCTAssertEqual(glyphBounds.midX + origin.x, badge.midX, accuracy: 0.0001)
        XCTAssertEqual(glyphBounds.midY + origin.y, badge.midY, accuracy: 0.0001)
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

    func testSSOSessionsDecodeAndDescribeTheirExpiry() throws {
        let data = Data(#"""
        {"mode":"bedrock:dev","kind":"bedrock","account":null,"awsProfile":"dev","accounts":[],
         "awsSso":[
           {"name":"admin","profiles":["dev","prod"],"expiresAt":"2026-08-14T13:59:14Z","secondsRemaining":9000,"status":"valid","active":true},
           {"name":"stale","profiles":["iam"],"expiresAt":"2026-07-01T15:07:58Z","secondsRemaining":-500,"status":"expired","active":false},
           {"name":"gone","profiles":["other"],"expiresAt":null,"secondsRemaining":null,"status":"signed-out","active":false}
         ]}
        """#.utf8)

        let state = try JSONDecoder().decode(BillingState.self, from: data)

        XCTAssertEqual(state.ssoSessions.count, 3)
        XCTAssertEqual(state.ssoSessions[0].menuTitle, "admin (in use) · valid for 2h 30m")
        XCTAssertEqual(state.ssoSessions[1].menuTitle, "stale · expired")
        XCTAssertEqual(state.ssoSessions[2].menuTitle, "gone · signed out")
        XCTAssertFalse(state.ssoSessions[0].needsRefresh)
        XCTAssertTrue(state.ssoSessions[1].needsRefresh)
        XCTAssertTrue(state.ssoSessions[2].needsRefresh)
    }

    func testSSORowCountsOnlySessionsNeedingRefresh() {
        func session(_ name: String, _ status: String) -> SSOSessionState {
            SSOSessionState(
                name: name, profiles: [], expiresAt: nil,
                secondsRemaining: 60, status: status, active: false
            )
        }
        func state(_ sessions: [SSOSessionState]) -> BillingState {
            BillingState(
                mode: "bedrock:dev", kind: "bedrock", account: nil, awsProfile: "dev",
                accounts: [], desktop: nil, awsSso: sessions
            )
        }

        XCTAssertEqual(state([session("a", "valid")]).ssoMenuTitle, "AWS SSO sessions")
        XCTAssertEqual(
            state([session("a", "valid"), session("b", "expired")]).ssoMenuTitle,
            "AWS SSO · 1 login to refresh"
        )
        XCTAssertEqual(
            state([session("a", "signed-out"), session("b", "expired")]).ssoMenuTitle,
            "AWS SSO · 2 logins to refresh"
        )
    }

    func testSessionProfileSummaryNamesTheProfilesTheLoginCovers() {
        func session(_ profiles: [String]) -> SSOSessionState {
            SSOSessionState(
                name: "admin", profiles: profiles, expiresAt: nil,
                secondsRemaining: 60, status: "valid", active: false
            )
        }

        XCTAssertEqual(session(["dev", "prod"]).profileSummary, "dev, prod")
        XCTAssertEqual(
            session(["a", "b", "c", "d", "e", "f", "g"]).profileSummary,
            "a, b, c, d, e +2 more"
        )
        XCTAssertEqual(session([]).profileSummary, "no profiles use this session")
    }

    func testExpiringSessionsAreFlaggedButNotTreatedAsNeedingRefresh() {
        let expiring = SSOSessionState(
            name: "admin", profiles: ["dev"], expiresAt: nil,
            secondsRemaining: 900, status: "expiring", active: false
        )

        XCTAssertEqual(expiring.detail, "expires in 15m")
        XCTAssertEqual(expiring.symbolName, "clock.badge.exclamationmark")
        XCTAssertFalse(expiring.needsRefresh)
    }

    func testSSOLoginCommandDelegatesToTheCLI() {
        XCTAssertEqual(ManagementCommand.ssoLogin("admin").arguments, ["sso-login", "admin"])
        XCTAssertEqual(ManagementCommand.ssoLogin("admin").errorTitle, "Couldn’t Start the AWS SSO Login")
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

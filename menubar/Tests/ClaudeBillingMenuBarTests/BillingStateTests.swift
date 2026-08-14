import XCTest
@testable import ClaudeBillingMenuBar

final class BillingStateTests: XCTestCase {
    func testEachBillingKindHasADistinctMenuBarLetter() {
        let subscription = BillingState(mode: "sub:work", kind: "subscription", account: "work", awsProfile: nil, accounts: ["work"], desktop: nil, awsSso: nil, bedrockProfile: nil, bedrockProfileSource: nil)
        let api = BillingState(mode: "api", kind: "api", account: nil, awsProfile: nil, accounts: [], desktop: nil, awsSso: nil, bedrockProfile: nil, bedrockProfileSource: nil)
        let bedrock = BillingState(mode: "bedrock:work-aws", kind: "bedrock", account: nil, awsProfile: "work-aws", accounts: [], desktop: nil, awsSso: nil, bedrockProfile: nil, bedrockProfileSource: nil)

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
    }

    func testBedrockRowNamesTheProfileASwitchWouldSelect() throws {
        func state(_ json: String) throws -> BillingState {
            try JSONDecoder().decode(BillingState.self, from: Data(json.utf8))
        }

        // Active Bedrock: the profile in effect.
        XCTAssertEqual(
            try state(#"{"mode":"bedrock:internal","kind":"bedrock","account":null,"awsProfile":"internal","accounts":[],"bedrockProfile":"internal","bedrockProfileSource":"settings"}"#).bedrockRowTitle,
            "AWS Bedrock · internal"
        )
        // On a subscription, with an explicitly configured profile: deterministic, so name it.
        XCTAssertEqual(
            try state(#"{"mode":"sub:work","kind":"subscription","account":"work","awsProfile":null,"accounts":["work"],"bedrockProfile":"eaix-bedrock","bedrockProfileSource":"config"}"#).bedrockRowTitle,
            "AWS Bedrock · eaix-bedrock"
        )
        // Inherited: depends on the launching environment, so never named.
        XCTAssertEqual(
            try state(#"{"mode":"sub:work","kind":"subscription","account":"work","awsProfile":null,"accounts":["work"],"bedrockProfile":null,"bedrockProfileSource":"inherited"}"#).bedrockRowTitle,
            "AWS Bedrock · inherited profile"
        )
        // Older CLI without the field at all.
        XCTAssertEqual(
            try state(#"{"mode":"api","kind":"api","account":null,"awsProfile":null,"accounts":[]}"#).bedrockRowTitle,
            "AWS Bedrock"
        )
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
                accounts: [], desktop: nil, awsSso: sessions,
                bedrockProfile: nil, bedrockProfileSource: nil
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

    func testUsageDecodesAndSurfacesTheLimitClosestToBiting() throws {
        let data = Data(#"""
        [{"account":"work","status":"ok","fetchedAt":1786708800,"ageSeconds":0,
          "limits":[{"kind":"session","group":"session","percent":72,"severity":"warning","resetsAt":null,"isActive":true},
                    {"kind":"weekly_all","group":"weekly","percent":41,"severity":"normal","resetsAt":"2026-08-19T01:59:59.838154+00:00","isActive":true}],
          "spend":{"percent":86,"used":17.2,"limit":20,"currency":"USD","severity":"warning"}},
         {"account":"personal","status":"token-expired"}]
        """#.utf8)

        let usage = try JSONDecoder().decode([UsageAccount].self, from: data)

        XCTAssertEqual(usage[0].headline?.kind, "session")
        XCTAssertEqual(usage[0].headline?.percent, 72)
        XCTAssertEqual(usage[0].limits?[0].detailLabel, "5-hour session")
        XCTAssertEqual(usage[0].limits?[1].name, "Weekly · all models")
        XCTAssertEqual(usage[0].spend?.detailLabel, "Extra usage credits · USD 17.20 of 20.00")
        XCTAssertNil(usage[0].problem)
        XCTAssertEqual(usage[1].problem, "token expired — switch to this account to refresh")
        XCTAssertFalse(usage[1].isOK)
    }

    func testTheFiveHourLimitIsAlwaysTheHeadline() {
        func limit(_ kind: String, _ percent: Int) -> UsageLimit {
            UsageLimit(kind: kind, percent: percent, severity: "normal", resetsAt: nil, isActive: true)
        }
        func account(_ limits: [UsageLimit]) -> UsageAccount {
            UsageAccount(
                account: "work", status: "ok", limits: limits, spend: nil,
                ageSeconds: nil, staleReason: nil, detail: nil
            )
        }

        // The session limit headlines even when a weekly limit is far higher.
        XCTAssertEqual(
            account([limit("weekly_all", 90), limit("session", 3)]).headline?.kind,
            "session"
        )
        // With no session limit reported, the tightest remaining one stands in.
        XCTAssertEqual(
            account([limit("weekly_all", 90), limit("weekly_opus", 12)]).headline?.kind,
            "weekly_all"
        )
        XCTAssertNil(account([]).headline)
    }

    func testUsageBarFillsProportionallyWithoutMisleadingEnds() {
        XCTAssertEqual(usageBar(percent: 0), "▯▯▯▯▯▯▯▯▯▯")
        XCTAssertEqual(usageBar(percent: 100), "▮▮▮▮▮▮▮▮▮▮")
        XCTAssertEqual(usageBar(percent: 50), "▮▮▮▮▮▯▯▯▯▯")
        // Any usage at all shows a cell, and short of the limit never looks full.
        XCTAssertEqual(usageBar(percent: 1), "▮▯▯▯▯▯▯▯▯▯")
        XCTAssertEqual(usageBar(percent: 99), "▮▮▮▮▮▮▮▮▮▯")
        // Out-of-range input from an unofficial endpoint must not break the bar.
        XCTAssertEqual(usageBar(percent: -5), "▯▯▯▯▯▯▯▯▯▯")
        XCTAssertEqual(usageBar(percent: 250), "▮▮▮▮▮▮▮▮▮▮")
        XCTAssertEqual(usageBar(percent: 50, width: 4).count, 4)
    }

    func testUsageLevelThresholdsMapToTrafficLightColours() {
        XCTAssertEqual(UsageLevel(percent: 0).color, NSColor.systemGreen)
        XCTAssertEqual(UsageLevel(percent: 59).color, NSColor.systemGreen)
        XCTAssertEqual(UsageLevel(percent: 60).color, NSColor.systemOrange)
        XCTAssertEqual(UsageLevel(percent: 84).color, NSColor.systemOrange)
        XCTAssertEqual(UsageLevel(percent: 85).color, NSColor.systemRed)
        XCTAssertEqual(UsageLevel(percent: 100).color, NSColor.systemRed)
    }

    func testUsageFailuresNeverReadAsZeroPercent() {
        let unavailable = UsageAccount(
            account: "work", status: "unavailable", limits: nil, spend: nil,
            ageSeconds: nil, staleReason: nil, detail: "could not reach api.anthropic.com"
        )

        XCTAssertNil(unavailable.headline)
        XCTAssertEqual(unavailable.problem, "could not reach api.anthropic.com")
    }

    func testUsageAgeNoteAppearsOnlyOnceFiguresAreStale() {
        func account(age: Int?, reason: String? = nil) -> UsageAccount {
            UsageAccount(
                account: "work", status: "ok", limits: [], spend: nil,
                ageSeconds: age, staleReason: reason, detail: nil
            )
        }

        XCTAssertNil(account(age: nil).ageNote)
        XCTAssertNil(account(age: 30).ageNote)
        XCTAssertEqual(account(age: 600).ageNote, "cached 10 min ago")
        XCTAssertEqual(
            account(age: 7_200, reason: "api.anthropic.com returned HTTP 500").ageNote,
            "cached 2h ago — api.anthropic.com returned HTTP 500"
        )
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

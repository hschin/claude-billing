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

    func testDesktopStateDecodesSeparatelyFromBillingState() throws {
        let data = Data(#"{"mode":"api","kind":"api","account":null,"awsProfile":null,"accounts":["work","personal"],"desktop":{"available":true,"account":"personal"}}"#.utf8)

        let state = try JSONDecoder().decode(BillingState.self, from: data)

        XCTAssertEqual(state.desktop?.account, "personal")
    }
}

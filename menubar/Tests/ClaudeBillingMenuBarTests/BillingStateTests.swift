import XCTest
@testable import ClaudeBillingMenuBar

final class BillingStateTests: XCTestCase {
    func testBedrockDisplayIncludesTheEffectiveAWSProfile() throws {
        let data = Data(#"{"mode":"bedrock:work-aws","kind":"bedrock","account":null,"awsProfile":"work-aws","accounts":["work","personal"]}"#.utf8)

        let state = try JSONDecoder().decode(BillingState.self, from: data)

        XCTAssertEqual(state.statusItemTitle, "Claude · AWS work-aws")
    }

    func testSubscriptionActionPassesTheAccountAsASeparateArgument() {
        XCTAssertEqual(
            BillingAction.subscription(account: "work").arguments,
            ["subscription", "work"]
        )
    }
}

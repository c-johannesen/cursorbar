import XCTest
@testable import PaceCore

final class CycleStartSpendTests: XCTestCase {
    func testReconcile_scalesSplitOntoIncludedTotal() {
        let spend = CycleStartSpend.reconcile(autoCents: 100, apiCents: 50, includedUsedCents: 300)
        XCTAssertEqual(spend.autoCents, 200)
        XCTAssertEqual(spend.apiCents, 100)
        XCTAssertEqual(spend.totalCents, spend.autoCents + spend.apiCents)
        XCTAssertEqual(spend.totalCents, 300)
    }

    func testReconcile_shrinksAnOverReportedSplit() {
        let spend = CycleStartSpend.reconcile(autoCents: 80, apiCents: 20, includedUsedCents: 50)
        XCTAssertEqual(spend.totalCents, 50)
        XCTAssertEqual(spend.autoCents + spend.apiCents, 50)
        XCTAssertEqual(spend.autoCents, 40)
        XCTAssertEqual(spend.apiCents, 10)
    }

    func testReconcile_doesNotInventASplitWhenEventsAreEmpty() {
        let spend = CycleStartSpend.reconcile(autoCents: 0, apiCents: 0, includedUsedCents: 500)
        XCTAssertEqual(spend, ReconciledSpend(totalCents: 0, autoCents: 0, apiCents: 0))
    }
}

final class UsageEventPagerTests: XCTestCase {
    func testDecision_keepsPagingPastTheOldTenPageCap() {
        XCTAssertEqual(
            UsageEventPager.decision(page: 10, pageSize: 100, eventsOnPage: 100, totalCount: 2_500),
            .fetchNext
        )
    }

    func testDecision_stopsWhenTheReportedTotalIsCovered() {
        XCTAssertEqual(
            UsageEventPager.decision(page: 25, pageSize: 100, eventsOnPage: 100, totalCount: 2_500),
            .done
        )
    }

    func testDecision_stopsOnAnEmptyPage() {
        XCTAssertEqual(
            UsageEventPager.decision(page: 3, pageSize: 100, eventsOnPage: 0, totalCount: 2_500),
            .done
        )
    }

    func testDecision_refusesToPretendASafetyCapIsComplete() {
        XCTAssertEqual(
            UsageEventPager.decision(page: UsageEventPager.safetyPageLimit, pageSize: 100, eventsOnPage: 100, totalCount: 1_000_000),
            .incomplete
        )
    }
}

final class ReleaseAssetTests: XCTestCase {
    func testSelect_skipsAnUnrelatedZipAndRequiresADigest() {
        let assets = [
            ReleaseAsset(name: "notes.zip", downloadURL: "https://example.test/notes.zip", digest: "sha256:aa"),
            ReleaseAsset(name: "CursorBar-1.7.0.zip", downloadURL: "https://example.test/app.zip", digest: nil),
        ]
        XCTAssertNil(ReleaseAssetPicker.selectCursorBarZip(assets))
    }

    func testSelect_picksTheCursorBarZipWithItsDigest() {
        let assets = [
            ReleaseAsset(name: "other.zip", downloadURL: "https://example.test/other.zip", digest: "sha256:bbbb"),
            ReleaseAsset(
                name: "CursorBar-1.7.0.zip",
                downloadURL: "https://example.test/app.zip",
                digest: "sha256:abcd"
            ),
        ]
        XCTAssertEqual(
            ReleaseAssetPicker.selectCursorBarZip(assets),
            SelectedReleaseZip(downloadURL: "https://example.test/app.zip", digest: "sha256:abcd")
        )
    }

    func testDigest_matchesSHA256OfTheBytes() {
        let data = Data("abc".utf8)
        XCTAssertEqual(
            ReleaseDigest.sha256Hex(data),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertTrue(ReleaseDigest.matches(data: data, declared: "sha256:BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"))
        XCTAssertFalse(ReleaseDigest.matches(data: data, declared: "sha256:00"))
        XCTAssertFalse(ReleaseDigest.matches(data: data, declared: "md5:abc"))
    }
}

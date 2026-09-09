import XCTest
@testable import PaceCore

final class MenuBarSplitPolicyTests: XCTestCase {
    private let dailyOnly = MenuBarSplitPolicy.Prefs(
        showDaily: true,
        showAuto: false,
        showApi: false
    )

    func testWarningThresholdMatchesExistingYellowFloor() {
        XCTAssertEqual(MenuBarSplitPolicy.warningThreshold, 70)
    }

    func testPoolWarning_nilAndNotDepletedIsFalse() {
        XCTAssertFalse(MenuBarSplitPolicy.isPoolWarning(percent: nil, depleted: false))
    }

    func testPoolWarning_justBelowThresholdIsFalse() {
        XCTAssertFalse(MenuBarSplitPolicy.isPoolWarning(percent: 69.9, depleted: false))
    }

    func testPoolWarning_atThresholdIsTrue() {
        XCTAssertTrue(MenuBarSplitPolicy.isPoolWarning(percent: 70, depleted: false))
    }

    func testPoolWarning_depletedIsTrueEvenIfPercentNil() {
        XCTAssertTrue(MenuBarSplitPolicy.isPoolWarning(percent: nil, depleted: true))
    }

    func testPoolWarning_oneHundredIsTrue() {
        XCTAssertTrue(MenuBarSplitPolicy.isPoolWarning(percent: 100, depleted: false))
    }

    func testDailyOnlyStaysDailyWhenBothPoolsQuiet() {
        let vis = MenuBarSplitPolicy.effectiveVisibility(
            prefs: dailyOnly,
            autoIsWarning: false,
            apiIsWarning: false
        )
        XCTAssertEqual(vis, MenuBarSplitPolicy.Effective(
            showDaily: true,
            showAuto: false,
            showApi: false,
            isOverride: false
        ))
    }

    func testDailyOnlySplitsWhenApiWarns() {
        let vis = MenuBarSplitPolicy.effectiveVisibility(
            prefs: dailyOnly,
            autoIsWarning: false,
            apiIsWarning: true
        )
        XCTAssertEqual(vis, MenuBarSplitPolicy.Effective(
            showDaily: false,
            showAuto: true,
            showApi: true,
            isOverride: true
        ))
    }

    func testDailyOnlySplitsWhenAutoWarns() {
        let vis = MenuBarSplitPolicy.effectiveVisibility(
            prefs: dailyOnly,
            autoIsWarning: true,
            apiIsWarning: false
        )
        XCTAssertTrue(vis.isOverride)
        XCTAssertFalse(vis.showDaily)
        XCTAssertTrue(vis.showAuto)
        XCTAssertTrue(vis.showApi)
    }

    func testDailyOffNeverInjectsPools() {
        let vis = MenuBarSplitPolicy.effectiveVisibility(
            prefs: MenuBarSplitPolicy.Prefs(showDaily: false, showAuto: false, showApi: false),
            autoIsWarning: false,
            apiIsWarning: true
        )
        XCTAssertEqual(vis, MenuBarSplitPolicy.Effective(
            showDaily: false,
            showAuto: false,
            showApi: false,
            isOverride: false
        ))
    }

    func testExistingAPStayVisibleAndDailyHidesOnWarning() {
        let vis = MenuBarSplitPolicy.effectiveVisibility(
            prefs: MenuBarSplitPolicy.Prefs(showDaily: true, showAuto: true, showApi: true),
            autoIsWarning: false,
            apiIsWarning: true
        )
        XCTAssertEqual(vis, MenuBarSplitPolicy.Effective(
            showDaily: false,
            showAuto: true,
            showApi: true,
            isOverride: true
        ))
    }

    func testExistingAPUnchangedWhenDailyOff() {
        let vis = MenuBarSplitPolicy.effectiveVisibility(
            prefs: MenuBarSplitPolicy.Prefs(showDaily: false, showAuto: true, showApi: true),
            autoIsWarning: false,
            apiIsWarning: true
        )
        XCTAssertEqual(vis, MenuBarSplitPolicy.Effective(
            showDaily: false,
            showAuto: true,
            showApi: true,
            isOverride: false
        ))
    }

    func testDailyOnlySplitsWhenBothPoolsWarn() {
        let vis = MenuBarSplitPolicy.effectiveVisibility(
            prefs: dailyOnly,
            autoIsWarning: true,
            apiIsWarning: true
        )
        XCTAssertEqual(vis, MenuBarSplitPolicy.Effective(
            showDaily: false,
            showAuto: true,
            showApi: true,
            isOverride: true
        ))
    }

    func testDailyOffNeverInjectsWhenAutoWarns() {
        let vis = MenuBarSplitPolicy.effectiveVisibility(
            prefs: MenuBarSplitPolicy.Prefs(showDaily: false, showAuto: false, showApi: false),
            autoIsWarning: true,
            apiIsWarning: false
        )
        XCTAssertFalse(vis.isOverride)
        XCTAssertFalse(vis.showAuto)
        XCTAssertFalse(vis.showApi)
    }

    func testDisabledAutoSplitKeepsDailyOnlyWhenApiWarns() {
        let vis = MenuBarSplitPolicy.effectiveVisibility(
            prefs: dailyOnly,
            autoIsWarning: false,
            apiIsWarning: true,
            autoSplitEnabled: false
        )
        XCTAssertEqual(vis, MenuBarSplitPolicy.Effective(
            showDaily: true,
            showAuto: false,
            showApi: false,
            isOverride: false
        ))
    }
}

import XCTest

class SplitPanePage {
    let app: XCUIApplication

    init(_ app: XCUIApplication) { self.app = app }

    var container: XCUIElement { app.groups["splitPane.container"] }

    var panes: XCUIElementQuery {
        app.groups.matching(NSPredicate(format: "identifier BEGINSWITH 'splitPane.leaf.'"))
    }

    var dividers: XCUIElementQuery {
        app.groups.matching(NSPredicate(format: "identifier BEGINSWITH 'splitPane.divider.'"))
    }

    var paneCount: Int { panes.count }
    var dividerCount: Int { dividers.count }
}

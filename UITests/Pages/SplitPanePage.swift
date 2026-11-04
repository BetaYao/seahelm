import XCTest

class SplitPanePage {
    let app: XCUIApplication

    init(_ app: XCUIApplication) { self.app = app }

    var container: XCUIElement { app.descendants(matching: .any)["splitPane.container"] }

    var panes: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'splitPane.leaf.'"))
    }

    var dividers: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'splitPane.divider.'"))
    }

    var paneCount: Int { panes.count }
    var dividerCount: Int { dividers.count }
}

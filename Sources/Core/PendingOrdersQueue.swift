import Foundation

struct PendingOrder: Equatable, Identifiable {
    let id: String
    let action: FirstMateAction
}

/// 红区待批航令队列。同一 (worktreePath, kind) 至多一条(幂等)。
/// 必须在主线程使用。
final class PendingOrdersQueue {
    private(set) var orders: [PendingOrder] = []
    var onChange: (() -> Void)?

    static func key(_ a: FirstMateAction) -> String {
        let base = "\(a.worktreePath)#\(a.kind)"
        return a.payload.map { "\(base)#\($0)" } ?? base
    }

    func enqueue(_ action: FirstMateAction) {
        let id = Self.key(action)
        guard !orders.contains(where: { $0.id == id }) else { return }
        orders.append(PendingOrder(id: id, action: action))
        onChange?()
    }

    func all() -> [PendingOrder] { orders }

    func resolve(id: String) {
        let before = orders.count
        orders.removeAll { $0.id == id }
        if orders.count != before { onChange?() }
    }
}

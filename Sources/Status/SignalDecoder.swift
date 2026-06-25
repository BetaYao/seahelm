import Foundation

/// 信号员:把某条情报通道的原始输入解码成规范化的 StatusReport。
/// 主动通道(扫屏)与被动通道(钩子)各自实现本协议。
protocol SignalDecoder {
    /// 返回 nil 表示本次无可上报的变化。
    func decode() -> StatusReport?
}

import Foundation

/// 信号员:把某一来源的原始数据翻译成统一的 NormalizedEvent(只翻译,不裁决)。
protocol SignalDecoder {
    func decode() -> NormalizedEvent?   // 返回 nil = 本次无可上报
}

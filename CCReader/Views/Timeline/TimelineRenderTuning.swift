import Foundation

/// Centralized timeline rendering/paging tuning knobs.
/// Keep runtime behavior stable by changing values here only.
enum TimelineRenderTuning {
    // Session-side decode path
    static let firstPaintThreshold = 40
    static let firstPaintTailSize = 24
    static let yieldEveryRowsDuringDecode = 8

    // Host-side windowing / incremental DOM
    static let renderBatchSize = 100
    static let batchYieldSize = 40  // Yield every N payload builds to keep main thread responsive.
    static let followBottomThreshold: CGFloat = 96
    static let progressiveReplaceThreshold = 30
    static let progressiveInitialLatestCount = 18
    static let progressivePrependChunkSize = 16
}

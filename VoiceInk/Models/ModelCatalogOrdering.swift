import Foundation

enum ModelCatalogOrdering {
    struct Performance {
        let speed: Double?
        let accuracy: Double?
    }

    static func localModelsByPerformance(_ models: [any TranscriptionModel]) -> [any TranscriptionModel] {
        models.sorted { lhs, rhs in
            let lhsPerformance = performance(for: lhs)
            let rhsPerformance = performance(for: rhs)

            let lhsSpeed = lhsPerformance.speed ?? -.infinity
            let rhsSpeed = rhsPerformance.speed ?? -.infinity
            if lhsSpeed != rhsSpeed {
                return lhsSpeed > rhsSpeed
            }

            let lhsAccuracy = lhsPerformance.accuracy ?? -.infinity
            let rhsAccuracy = rhsPerformance.accuracy ?? -.infinity
            if lhsAccuracy != rhsAccuracy {
                return lhsAccuracy > rhsAccuracy
            }

            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    static func performance(for model: any TranscriptionModel) -> Performance {
        switch model {
        case let model as FluidAudioModel:
            return Performance(speed: model.speed, accuracy: model.accuracy)
        case let model as WhisperModel:
            return Performance(speed: model.speed, accuracy: model.accuracy)
        case let model as SherpaOnnxModel:
            return Performance(speed: model.speed, accuracy: nil)
        case let model as QwenMLXModel:
            return Performance(speed: model.speed, accuracy: model.accuracy)
        case let model as CloudModel:
            return Performance(speed: model.speed, accuracy: model.accuracy)
        default:
            return Performance(speed: nil, accuracy: nil)
        }
    }
}

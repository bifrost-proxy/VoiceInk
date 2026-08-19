import Foundation

enum LocalModelResourceRetentionPolicy {
    static func boundModelNames(in configurations: [ModeConfig]) -> Set<String> {
        Set(
            configurations.compactMap { configuration in
                guard let modelName = configuration.selectedTranscriptionModelName?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !modelName.isEmpty
                else {
                    return nil
                }
                return modelName
            }
        )
    }
}

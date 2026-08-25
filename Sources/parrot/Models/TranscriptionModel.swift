import Foundation

enum Engine: String, Codable {
    case canaryMLX
}

struct TranscriptionModel: Codable {
    let id: String
    let displayName: String
    let engine: Engine
    let sizeMB: Int
    let languages: [String]
    let recommended: Bool
}

struct ModelsManifest: Codable {
    let models: [TranscriptionModel]
}

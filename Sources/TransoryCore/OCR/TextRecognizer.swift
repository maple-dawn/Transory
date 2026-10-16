import CoreGraphics
import Foundation
import Vision

/// 识别出的一行文字。`boundingBox` 为归一化坐标（0...1），原点在左上角。
public struct RecognizedLine: Sendable, Equatable, Identifiable {
    public let id: Int
    public let text: String
    public let boundingBox: CGRect

    public init(id: Int, text: String, boundingBox: CGRect) {
        self.id = id
        self.text = text
        self.boundingBox = boundingBox
    }
}

/// 基于 Vision 的本地 OCR，离线可用。
public enum TextRecognizer {
    public static func recognize(_ image: CGImage) async throws -> [RecognizedLine] {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: image).perform([request])

            let observations = (request.results ?? [])
                .compactMap { observation -> (String, CGRect)? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    // Vision 的坐标原点在左下角，转成左上角。
                    let box = observation.boundingBox
                    return (candidate.string, CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height))
                }
                // 按阅读顺序：从上到下，同一行从左到右。
                .sorted { lhs, rhs in
                    abs(lhs.1.midY - rhs.1.midY) < min(lhs.1.height, rhs.1.height) / 2
                        ? lhs.1.minX < rhs.1.minX
                        : lhs.1.midY < rhs.1.midY
                }
            return observations.enumerated().map { RecognizedLine(id: $0.offset, text: $0.element.0, boundingBox: $0.element.1) }
        }.value
    }
}

import Foundation
import Vision
import CoreGraphics
import AppKit

/// What was on the user's screen at one moment of a meeting — captured on
/// demand, read into text on the Mac, and kept beside the transcript so the
/// notes and Ask can see the slide, the shared document, the demo.
struct ScreenFrame: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    /// When it was captured.
    var at: Date
    /// The text read off the image, in reading order, one line per line of
    /// the screen. Empty when nothing legible was on it.
    var text: String
    /// The app whose window was captured ("Zoom"), or nil for the whole screen.
    var sourceApp: String? = nil
    /// The image file's name inside the meeting's frames folder.
    var fileName: String

    /// How the frame is labelled wherever it is listed beside speech.
    var label: String { sourceApp.map { "On screen (\($0))" } ?? "On screen" }

    /// The text as one transcript line: the screen's lines joined, and capped
    /// so a dense document can't crowd out the conversation in a prompt.
    var transcriptLine: String {
        let joined = text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
        guard joined.count > 2500 else { return joined }
        return String(joined.prefix(2500)) + " …"
    }
}

/// Reads text off a captured image with the Vision framework — on the Mac,
/// in well under a second on the Neural Engine, no model to download.
enum ScreenTextReader {
    struct ReadLine: Equatable {
        let text: String
        /// Vision's normalized box: origin bottom-left, 0…1.
        let box: CGRect
    }

    /// Lines of text in reading order, joined with newlines. Empty if the
    /// image holds nothing legible.
    static func text(in image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations.compactMap { observation -> ReadLine? in
                    guard let best = observation.topCandidates(1).first else { return nil }
                    return ReadLine(text: best.string, box: observation.boundingBox)
                }
                continuation.resume(returning: readingOrder(lines).map(\.text).joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Top to bottom, and within a row left to right. Lines whose vertical
    /// centres sit within half a line height of each other are one row, so
    /// a title and the bullet beside it read in order rather than by column.
    static func readingOrder(_ lines: [ReadLine]) -> [ReadLine] {
        let byHeight = lines.sorted { $0.box.midY > $1.box.midY }
        var rows: [[ReadLine]] = []
        for line in byHeight {
            if let anchor = rows.last?.first,
               abs(anchor.box.midY - line.box.midY) < max(anchor.box.height, line.box.height) * 0.5 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.flatMap { $0.sorted { $0.box.minX < $1.box.minX } }
    }

    /// Writes the image as a JPEG no wider than `maxWidth`, which keeps a
    /// slide at roughly 100–250 KB — legible when opened, cheap to keep.
    static func writeJPEG(_ image: CGImage, to url: URL, maxWidth: Int = 1600, quality: CGFloat = 0.72) throws {
        let scale = min(1, Double(maxWidth) / Double(image.width))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let scaled = { () -> CGImage? in
                  context.interpolationQuality = .high
                  context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                  return context.makeImage()
              }() else {
            throw NSError(domain: "ScreenTextReader", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't scale the captured image."])
        }
        let bitmap = NSBitmapImageRep(cgImage: scaled)
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
            throw NSError(domain: "ScreenTextReader", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't encode the captured image."])
        }
        try data.write(to: url, options: .atomic)
    }
}

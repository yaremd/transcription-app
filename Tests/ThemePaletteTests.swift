import XCTest
import AppKit
import SwiftUI
@testable import Seal

/// The palette's contract, in both appearances.
///
/// Colour decisions in this app are argued from measurements in the token's
/// own doc comments — contrast against the grounds a colour is drawn on, and
/// OKLab distance from the accent. Those numbers were only ever checked by
/// hand, which is how the forest/lime rebrand shipped while `green` and the
/// whole tag palette stayed on the Linear values. This checks them.
final class ThemePaletteTests: XCTestCase {

    // MARK: - Resolving

    /// A dynamic `Color` as it actually renders in one appearance.
    private func rgb(_ color: Color, dark: Bool) throws -> (r: Double, g: Double, b: Double) {
        let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
        var out: (Double, Double, Double)?
        appearance.performAsCurrentDrawingAppearance {
            guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            out = (Double(srgb.redComponent), Double(srgb.greenComponent), Double(srgb.blueComponent))
        }
        return try XCTUnwrap(out)
    }

    private func relativeLuminance(_ c: (r: Double, g: Double, b: Double)) -> Double {
        func channel(_ v: Double) -> Double {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }

    private func contrast(_ a: (r: Double, g: Double, b: Double),
                          _ b: (r: Double, g: Double, b: Double)) -> Double {
        let (la, lb) = (relativeLuminance(a), relativeLuminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// OKLab, so "different enough" means perceptually rather than numerically.
    private func oklab(_ c: (r: Double, g: Double, b: Double)) -> (Double, Double, Double) {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let (r, g, b) = (lin(c.r), lin(c.g), lin(c.b))
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    private func distance(_ a: (r: Double, g: Double, b: Double),
                          _ b: (r: Double, g: Double, b: Double)) -> Double {
        let (x, y) = (oklab(a), oklab(b))
        return sqrt(pow(x.0 - y.0, 2) + pow(x.1 - y.1, 2) + pow(x.2 - y.2, 2))
    }

    // MARK: - The categorical set

    /// Every category must be legible where it is drawn. A tag dot sits on the
    /// sidebar, a speaker label on the transcript's inset panel.
    func testEveryCategoricalColourClearsAAOnItsGrounds() throws {
        for dark in [false, true] {
            let grounds = try [("surface", rgb(Theme.surface, dark: dark)),
                               ("inset", rgb(Theme.inset, dark: dark)),
                               ("sidebar", rgb(Theme.sidebar, dark: dark))]
            for (index, colour) in Theme.categoricalPalette.enumerated() {
                let c = try rgb(colour, dark: dark)
                for (name, ground) in grounds {
                    XCTAssertGreaterThanOrEqual(
                        contrast(c, ground), 4.5,
                        "categorical[\(index)] on \(name), \(dark ? "dark" : "light")")
                }
            }
        }
    }

    /// The whole point of a categorical set: no two members may be confusable.
    func testCategoricalColoursAreDistinguishableFromEachOther() throws {
        for dark in [false, true] {
            let resolved = try Theme.categoricalPalette.map { try rgb($0, dark: dark) }
            for i in resolved.indices {
                for j in resolved.indices where j > i {
                    XCTAssertGreaterThan(
                        distance(resolved[i], resolved[j]), 0.10,
                        "categorical[\(i)] and [\(j)] are too close in \(dark ? "dark" : "light")")
                }
            }
        }
    }

    /// No category may read as a selected or accented control.
    func testNoCategoricalColourIsMistakableForTheAccent() throws {
        for dark in [false, true] {
            let accent = try rgb(Theme.accent, dark: dark)
            for (index, colour) in Theme.categoricalPalette.enumerated() {
                let d = try distance(rgb(colour, dark: dark), accent)
                XCTAssertGreaterThan(d, 0.12,
                                     "categorical[\(index)] sits on the accent in \(dark ? "dark" : "light")")
            }
        }
    }

    /// The rebrand replaced the Linear accent and green everywhere it was the
    /// brand — and left both shipping as tag dots. They must not come back.
    func testThePaletteCarriesNoLinearLeftovers() throws {
        let retired: [(String, Double, Double, Double)] = [
            ("Linear indigo light", 0x5E / 255, 0x6A / 255, 0xD2 / 255),
            ("Linear indigo dark", 0x6E / 255, 0x79 / 255, 0xD6 / 255),
            ("Linear green light", 0x2F / 255, 0x9E / 255, 0x68 / 255),
            ("Linear green dark", 0x53 / 255, 0xB5 / 255, 0x7F / 255),
        ]
        for dark in [false, true] {
            for colour in Theme.categoricalPalette + [Theme.green, Theme.accent] {
                let c = try rgb(colour, dark: dark)
                for (name, r, g, b) in retired {
                    let same = abs(c.r - r) < 0.004 && abs(c.g - g) < 0.004 && abs(c.b - b) < 0.004
                    XCTAssertFalse(same, "\(name) is still in the palette")
                }
            }
        }
    }

    // MARK: - Speaker colours

    /// Most meetings have one far-side voice. That case must not change
    /// appearance just because diarization exists.
    func testFirstVoiceKeepsTheGreenItAlwaysHad() throws {
        for dark in [false, true] {
            let first = try rgb(Theme.speakerColor(voiceIndex: 0), dark: dark)
            let green = try rgb(Theme.green, dark: dark)
            XCTAssertEqual(first.r, green.r, accuracy: 0.001)
            XCTAssertEqual(first.g, green.g, accuracy: 0.001)
            XCTAssertEqual(first.b, green.b, accuracy: 0.001)
        }
    }

    /// The bug this was written for: "Speaker 1" and "Speaker 2" drawn in one
    /// colour, in the feature sold as "who said what, every voice named".
    func testEachVoiceGetsItsOwnColour() throws {
        for dark in [false, true] {
            let voices = try (0..<Theme.categoricalPalette.count)
                .map { try rgb(Theme.speakerColor(voiceIndex: $0), dark: dark) }
            for i in voices.indices {
                for j in voices.indices where j > i {
                    XCTAssertGreaterThan(distance(voices[i], voices[j]), 0.10,
                                         "voice \(i) and voice \(j) share a colour in \(dark ? "dark" : "light")")
                }
            }
        }
    }

    /// More voices than colours is a real meeting, not a crash.
    func testVoiceIndexWrapsAndSurvivesNonsense() throws {
        let count = Theme.categoricalPalette.count
        for dark in [false, true] {
            let first = try rgb(Theme.speakerColor(voiceIndex: 0), dark: dark)
            let wrapped = try rgb(Theme.speakerColor(voiceIndex: count), dark: dark)
            XCTAssertEqual(first.r, wrapped.r, accuracy: 0.001)
            XCTAssertEqual(first.g, wrapped.g, accuracy: 0.001)
            // A negative index must not trap.
            let negative = try rgb(Theme.speakerColor(voiceIndex: -3), dark: dark)
            XCTAssertEqual(negative.r, first.r, accuracy: 0.001)
        }
    }

    // MARK: - Voice -> colour slot

    private func meeting(voices: [String?]) -> Meeting {
        let lines = voices.enumerated().map { index, voice -> StoredLine in
            var line = StoredLine(speaker: voice == nil ? "You" : "Others", text: "line \(index)")
            line.voice = voice
            return line
        }
        return Meeting(title: "t", date: Date(), duration: 60, language: "en",
                       lines: lines, notes: "")
    }

    /// The mapping the transcript actually draws with. Voices are ordered by
    /// S-number, so the slot a voice gets is stable across launches — a
    /// speaker must not change colour because a later line was appended.
    func testVoicesTakeSlotsInSNumberOrder() {
        let m = meeting(voices: ["S2", nil, "S1", "S3", "S1"])
        let order = m.voiceOrder
        XCTAssertEqual(order["S1"], 0)
        XCTAssertEqual(order["S2"], 1)
        XCTAssertEqual(order["S3"], 2)

        XCTAssertEqual(m.voiceIndex(for: m.lines[0], in: order), 1, "S2 is the second voice")
        XCTAssertNil(m.voiceIndex(for: m.lines[1], in: order), "a You line has no far-side slot")
        XCTAssertEqual(m.voiceIndex(for: m.lines[2], in: order), 0)
        XCTAssertEqual(m.voiceIndex(for: m.lines[4], in: order), 0, "the same voice keeps its slot")
    }

    /// An undiarized meeting — most of them — must be untouched by all this.
    func testUndiarizedLinesFallToTheOriginalGreen() throws {
        let m = meeting(voices: [nil, nil])
        let order = m.voiceOrder
        XCTAssertTrue(order.isEmpty)
        for line in m.lines {
            XCTAssertNil(m.voiceIndex(for: line, in: order))
        }
        // Which is what TranscriptRow turns into slot 0.
        for dark in [false, true] {
            let slot0 = try rgb(Theme.speakerColor(voiceIndex: 0), dark: dark)
            let green = try rgb(Theme.green, dark: dark)
            XCTAssertEqual(slot0.g, green.g, accuracy: 0.001)
        }
    }

    /// End to end for the reported case: three far-side voices, three colours.
    func testThreeVoicesGetThreeDistinctColours() throws {
        let m = meeting(voices: ["S1", "S2", "S3"])
        let order = m.voiceOrder
        for dark in [false, true] {
            let colours = try m.lines.map { line -> (r: Double, g: Double, b: Double) in
                let slot = m.voiceIndex(for: line, in: order) ?? 0
                return try rgb(Theme.speakerColor(voiceIndex: slot), dark: dark)
            }
            for i in colours.indices {
                for j in colours.indices where j > i {
                    XCTAssertGreaterThan(distance(colours[i], colours[j]), 0.10,
                                         "speakers \(i + 1) and \(j + 1) share a colour")
                }
            }
        }
    }
}

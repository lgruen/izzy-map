import CryptoKit
import Foundation
import Testing
@testable import IzzyKit

/// The bundled acknowledgements.json (pipeline/build_acknowledgements.py)
/// against what actually ships: the pinned MapLibre version, the glyph
/// files, the licences each component must carry.
struct AcknowledgementsTests {
    let doc: Acknowledgements

    init() throws { doc = try TestData.data.acknowledgements() }

    @Test func listsEveryShippedComponent() throws {
        #expect(Set(doc.components.map(\.id)) == ["maplibre", "bioclip", "noto-sans"])
        for c in doc.components {
            #expect(!c.texts.isEmpty && c.texts.allSatisfy { !$0.body.isEmpty }, "\(c.id)")
        }
        #expect(!doc.data.isEmpty)
    }

    /// The text belongs to the MapLibre the project pins (project.yml).
    @Test func mapLibreMatchesTheProjectPin() throws {
        let yml = try String(contentsOf: TestData.package.deletingLastPathComponent().appending(path: "project.yml"), encoding: .utf8)
        let pin = try #require(yml.firstMatch(of: /maplibre-gl-native-distribution\s*\n\s*exactVersion:\s*"?([0-9.]+)/)?.1)
        let maplibre = try #require(doc.component("maplibre"))
        #expect(maplibre.version == String(pin))
        #expect(maplibre.licence == "BSD 2-Clause")
        let licence = try #require(maplibre.texts.first).body
        #expect(licence.hasPrefix("BSD 2-Clause License"))
        #expect(licence.contains("Copyright (c) 2021 MapLibre contributors"))
        #expect(licence.contains("Redistributions in binary form must reproduce the above copyright"))
    }

    @Test func bioclipCarriesItsMITNoticeAndCitation() throws {
        let c = try #require(doc.component("bioclip"))
        #expect(c.licence == "MIT")
        let mit = try #require(c.texts.first).body
        #expect(mit.hasPrefix("Copyright (c) 2023-2026 Imageomics Institute"))
        #expect(mit.contains("The above copyright notice and this permission notice shall be"))
        #expect(c.citations.contains { $0.text.hasPrefix("@inproceedings{NEURIPS2025_94da80cb,") })
    }

    /// The glyph files that ship are the ones whose source (and so font
    /// licence) the build verified.
    @Test func glyphsAreTheVerifiedFiles() throws {
        let glyphs = TestData.package.deletingLastPathComponent().appending(path: "IzzyMap/Resources/glyphs")
        #expect(doc.glyphs.count == 2)
        for (path, sha) in doc.glyphs {
            let bytes = try Data(contentsOf: glyphs.appending(path: path))
            #expect(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == sha, "\(path)")
        }
        let noto = try #require(doc.component("noto-sans"))
        #expect(noto.licence == "SIL Open Font License 1.1")
        #expect(noto.texts.contains { $0.body.contains("SIL OPEN FONT LICENSE Version 1.1") })
        #expect(noto.texts.contains { $0.body.contains("Copyright 2012 Google Inc.") })
    }

    @Test func reflowJoinsWrappedProseOnly() {
        let bsd = """
        BSD 2-Clause License

        Copyright (c) 2021 MapLibre contributors

        Redistribution and use in source and binary forms, with or without
        modification, are permitted provided that the following conditions are
        met:

        * Redistributions of source code must retain the above copyright
          notice, this list of conditions and the following disclaimer.
        1. Neither the name of the copyright holder nor the names of its
           contributors may be used.
        ===========================================================================
        Next
        """
        let out = Acknowledgements.reflow(bsd)
        #expect(out.contains("with or without modification, are permitted provided that the following conditions are met:"))
        #expect(out.contains("\n* Redistributions of source code must retain the above copyright notice, this list"))
        #expect(out.contains("\n1. Neither the name"))
        #expect(out.contains("BSD 2-Clause License\n\nCopyright (c) 2021 MapLibre contributors\n\n"))
        #expect(out.contains("\n=====") && out.hasSuffix("=\nNext"))
        // whitespace only
        #expect(out.split(whereSeparator: \.isWhitespace) == bsd.split(whereSeparator: \.isWhitespace))
        for c in doc.components {
            for t in c.texts {
                #expect(t.reflowed.split(whereSeparator: \.isWhitespace) == t.body.split(whereSeparator: \.isWhitespace))
            }
        }
    }

    @Test func commonNameHeadline() {
        #expect(CommonName.headline("christmas bells") == "Christmas bells")
        #expect(CommonName.headline("Christmas bells") == "Christmas bells")
        #expect(CommonName.headline("") == nil)
    }
}

/*
    Copyright (C) 2026 DroidStar-DMR contributors

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

import Foundation

// Ham-radio post-processing for live subtitles (SubtitleEngine.swift).
//
//   English text from the recognizer
//     -> cleanEnglish():            spelled callsigns collapsed ("Kilo Juliet 4 Charlie Papa Alpha"
//                                   -> "KJ4CPA"), fillers dropped, table fixes ("73 children" -> "73")
//     -> prepareForTranslation():   callsigns / Q-codes swapped for placeholders, a closing "over"
//                                   taken off (the translator turns it into "tamam mı?")
//     -> Apple Translation (en -> tr)
//     -> finishTranslation():       placeholders restored, radio phrases fixed
//                                   ("beni kopyalıyor musun" -> "beni duyuyor musun"), "tamam" appended
//
// Everything is table driven and deliberately conservative: a spelled callsign is only collapsed
// when the spelling is unambiguous (see collapseCallsigns). Pure Foundation, so the same file is
// compiled into the app and into the macOS test harness (ds-work/altyazi/stream-test).
enum SubtitleGlossary {

    // MARK: - Tables (extend here)

    /// NATO / ICAO spelling words. `canonical` words count as evidence that someone is spelling;
    /// the variants are common recognizer mishearings and only help inside an already spelled run.
    static let phonetic: [String: (letter: Character, canonical: Bool)] = {
        var m: [String: (Character, Bool)] = [:]
        let canonical: [(String, Character)] = [
            ("alpha", "A"), ("alfa", "A"), ("bravo", "B"), ("charlie", "C"), ("delta", "D"),
            ("echo", "E"), ("foxtrot", "F"), ("golf", "G"), ("hotel", "H"), ("india", "I"),
            ("juliet", "J"), ("juliett", "J"), ("kilo", "K"), ("lima", "L"), ("mike", "M"),
            ("november", "N"), ("oscar", "O"), ("papa", "P"), ("quebec", "Q"), ("romeo", "R"),
            ("sierra", "S"), ("tango", "T"), ("uniform", "U"), ("victor", "V"), ("whiskey", "W"),
            ("whisky", "W"), ("xray", "X"), ("yankee", "Y"), ("zulu", "Z"),
        ]
        let variants: [(String, Character)] = [
            ("alsa", "A"), ("alfa", "A"), ("eco", "E"), ("fox", "F"), ("indian", "I"),
            ("juliette", "J"), ("julia", "J"), ("julian", "J"), ("kilos", "K"), ("gilo", "K"),
            ("keelo", "K"), ("queen", "Q"), ("sierre", "S"), ("yankey", "Y"),
        ]
        for (w, c) in variants { m[w] = (c, false) }
        for (w, c) in canonical { m[w] = (c, true) }
        return m
    }()

    /// Two-word mishearings of a spelling word (checked before the single-word table).
    static let phoneticPairs: [String: Character] = [
        "in your": "I",     // "9 kilo 2 in your Charlie" = 9K2IC
        "x ray": "X",
    ]

    /// Spoken digits that may start or end a spelled run.
    static let digitWords: [String: Character] = [
        "zero": "0", "two": "2", "three": "3", "five": "5", "six": "6", "seven": "7",
        "eight": "8", "nine": "9", "niner": "9",
    ]

    /// Words the recognizer writes for a digit inside a spelling ("Juliet for Charlie" = J4C).
    /// Only used between two spelled symbols, never at the edge of a run.
    static let digitHomophones: [String: Character] = [
        "for": "4", "four": "4", "or": "4", "ford": "4", "fore": "4",
        "to": "2", "too": "2",
        "one": "1", "won": "1",
    ]

    /// Upper-case words that are never part of a callsign.
    static let notCallsignLetters: Set<String> = [
        "QSL", "QSO", "QRZ", "QTH", "QSY", "QRM", "QRN", "QRP", "QRT", "QRV", "QRX", "QSB", "QSK",
        "USA", "UK", "DMR", "PM", "AM", "CST", "EST", "PST", "UTC", "GMT", "OK", "TV", "ID", "TG",
        "BM", "DX", "CQ", "GPS", "FM", "SSB", "CW", "HF", "VHF", "UHF", "MHZ", "KHZ", "I", "A",
    ]

    /// English clean-up before translation (regex, replacement), case-insensitive.
    static let englishFixes: [(String, String)] = [
        (#"\b(?:uh|um|uhm|erm|er|ah)\b[,.]?\s*"#, ""),      // hesitation fillers
        (#"\b73 children\b"#, "73"),                          // "73" heard as "73 children"
        (#"\bQRZ dot com\b"#, "QRZ.com"),
        (#"\bI do copy\b"#, "I copy you"),                   // translated as "kopyalamıyorum" (!)
        (#"\s{2,}"#, " "),
        (#"^\s*[,.]\s*"#, ""),
    ]

    /// Tokens kept out of the translator (the Q-code pattern; callsigns are found by pattern too).
    static let protectedPatterns: [String] = [
        #"\bQ[A-Z]{2}\b"#,                                    // QSL, QSO, QRZ, QTH...
        #"\bTG ?\d+\b"#,
    ]

    /// Radio phrases the translator gets wrong (regex, replacement). Case-insensitive; the
    /// capital of the first letter is kept. Longer phrases first.
    static let turkishFixes: [(String, String)] = [
        (#"\bkopyalıyor musunuz\b"#, "duyuyor musunuz"),
        (#"\bkopyalıyor musun\b"#, "duyuyor musun"),
        (#"\bkopyalar mısınız\b"#, "duyuyor musunuz"),
        (#"\bkopyalar mısın\b"#, "duyuyor musun"),
        (#"\bkopyalayabiliyor musunuz\b"#, "duyabiliyor musunuz"),
        (#"\bkopyalayabiliyor musun\b"#, "duyabiliyor musun"),
        (#"\bkopyalarsınız\b"#, "duyuyor musunuz"),
        (#"\bkopyalarsın\b"#, "duyuyor musun"),
        (#"\bkopyalıyorum\b"#, "duyuyorum"),
        (#"\bkopyalıyoruz\b"#, "duyuyoruz"),
        (#"\bkopyalıyor\b"#, "duyuyor"),
        (#"\bkopyalamıyorum\b"#, "duyamıyorum"),
        (#"\bkopyalayamıyorum\b"#, "duyamıyorum"),
        (#"\bkopyaladım\b"#, "anladım"),
        (#"\bkopyalandı\b"#, "anlaşıldı"),
        (#"\bsana duyuyorum\b"#, "seni duyuyorum"),         // after the "kopyala" rules
        (#"\b73 çocuk(?:lar)?\b"#, "73"),
        (#"\bBu (\#(placeholderPrefix)\d+)"#, "Burası $1"),  // "This is KJ4CPA" -> "Burası KJ4CPA"
    ]

    /// Closing words at the very end of an over, replaced by their Turkish radio form.
    static let closings: [(pattern: String, turkish: String)] = [
        (#"[,.]?\s*\bover to you\b[\s.?!]*$"#, "Söz sende."),
        (#"[,.]?\s*\bback to you\b[\s.?!]*$"#, "Söz sende."),
        (#"[,.]?\s*\bover\b[\s.?!]*$"#, "Tamam."),
    ]

    static let placeholderPrefix = "ZXQ"

    /// Two or more spelling words in a row that did not collapse into a callsign
    /// ("Kilo, Juliet, George, Charlie, Papa") are kept as spoken, not translated ("Papa" -> "Baba").
    static let spelledRunPattern: String = {
        let words = phonetic.filter { $0.value.canonical }.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        return #"\b(?:"# + words + #")(?:[\s,.\-]+(?:"# + words + #"))+\b"#
    }()

    /// A callsign: 1-2 letter prefix (or digit+letter / letter+digit), a digit, 1-3 letters.
    static let callsignPattern = #"(?:[A-Z]{1,2}|[0-9][A-Z]|[A-Z][0-9])[0-9][A-Z]{1,3}"#

    // MARK: - English

    static func cleanEnglish(_ text: String) -> String {
        var s = collapseCallsigns(text)
        for (p, r) in englishFixes { s = replace(s, p, r) }
        s = s.trimmingCharacters(in: .whitespaces)
        if let f = s.first, f.isLowercase { s = f.uppercased() + s.dropFirst() }
        return s
    }

    // MARK: - Spelled callsigns

    private enum Kind { case letters, digit, homophone }

    private struct Tok {
        var range: Range<String.Index>
        var symbols: String
        var kind: Kind
        var evidence: Bool      // canonical spelling word or a spoken capital letter
    }

    /// "Kilo, Juliet, or Charlie, Papa Alsa" -> "KJ4CPA". A run of spelling words, capital
    /// letters and digits (separated only by spaces, commas, dots or dashes) is collapsed when
    /// a slice of it spells a callsign with at least 3 letters and 2 pieces of evidence (canonical
    /// spelling words or capital letters). Anything that does not fit is left as it was.
    static func collapseCallsigns(_ text: String) -> String {
        let words = wordRanges(text)
        var toks: [Tok?] = []
        var i = 0
        while i < words.count {
            let w = String(text[words[i]])
            let lw = w.lowercased()
            if i + 1 < words.count, onlySeparators(text[words[i].upperBound..<words[i + 1].lowerBound]),
               let c = phoneticPairs[lw + " " + String(text[words[i + 1]]).lowercased()] {
                toks.append(Tok(range: words[i].lowerBound..<words[i + 1].upperBound, symbols: String(c), kind: .letters, evidence: false))
                i += 2
                continue
            }
            toks.append(classify(w, words[i]))
            i += 1
        }

        // Runs of consecutive tokens with only separators between them.
        var runs: [[Tok]] = []
        var cur: [Tok] = []
        var prevEnd: String.Index? = nil
        for t in toks {
            guard let t = t else {
                if !cur.isEmpty { runs.append(cur); cur = [] }
                prevEnd = nil
                continue
            }
            if let pe = prevEnd, !onlySeparators(text[pe..<t.range.lowerBound]) {
                if !cur.isEmpty { runs.append(cur) }
                cur = []
            }
            cur.append(t)
            prevEnd = t.range.upperBound
        }
        if !cur.isEmpty { runs.append(cur) }

        // Replacements, collected as (range, callsign), applied back to front.
        var edits: [(Range<String.Index>, String)] = []
        let re = try! NSRegularExpression(pattern: "^" + callsignPattern + "$")
        for var run in runs {
            while let f = run.first, f.kind == .homophone { run.removeFirst() }
            while let l = run.last, l.kind == .homophone { run.removeLast() }
            var s = 0
            while s < run.count {
                var matched = 0
                var e = run.count
                while e > s {
                    let slice = run[s..<e]
                    let sym = slice.map { $0.symbols }.joined()
                    if slice.last?.kind != .homophone, slice.first?.kind != .homophone,
                       re.firstMatch(in: sym, range: NSRange(sym.startIndex..., in: sym)) != nil,
                       sym.filter({ $0.isLetter }).count >= 3,
                       slice.filter({ $0.evidence }).count >= 2 {
                        edits.append((slice.first!.range.lowerBound..<slice.last!.range.upperBound, sym))
                        matched = e - s
                        break
                    }
                    e -= 1
                }
                s += max(1, matched)
            }
        }
        var out = text
        for (r, cs) in edits.reversed() { out.replaceSubrange(r, with: cs) }
        return out
    }

    private static func classify(_ w: String, _ r: Range<String.Index>) -> Tok? {
        let lw = w.lowercased()
        if let p = phonetic[lw] {
            return Tok(range: r, symbols: String(p.letter), kind: .letters, evidence: p.canonical)
        }
        if w.count == 1, let c = w.first, c.isUppercase, c.isASCII, c.isLetter, w != "I", w != "A" {
            return Tok(range: r, symbols: w, kind: .letters, evidence: true)
        }
        if w == "I" || w == "A" {       // only as a spelled letter inside a run, not as evidence
            return Tok(range: r, symbols: w, kind: .letters, evidence: false)
        }
        if (2...3).contains(w.count), w.allSatisfy({ $0.isASCII && $0.isUppercase }), !notCallsignLetters.contains(w) {
            return Tok(range: r, symbols: w, kind: .letters, evidence: true)
        }
        if (1...2).contains(w.count), w.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return Tok(range: r, symbols: w, kind: .digit, evidence: false)
        }
        if let d = digitWords[lw] { return Tok(range: r, symbols: String(d), kind: .digit, evidence: false) }
        if let d = digitHomophones[lw] { return Tok(range: r, symbols: String(d), kind: .homophone, evidence: false) }
        return nil
    }

    private static func wordRanges(_ text: String) -> [Range<String.Index>] {
        let re = try! NSRegularExpression(pattern: #"[A-Za-z0-9]+"#)
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
    }

    private static func onlySeparators(_ s: Substring) -> Bool {
        s.allSatisfy { $0 == " " || $0 == "," || $0 == "." || $0 == "-" || $0 == ";" || $0 == ":" }
    }

    // MARK: - Translation

    struct Prepared {
        var text: String            // what goes to the translator
        var protected: [String]     // placeholder index -> original text
        var closing: String?        // Turkish closing to append ("Tamam.")
    }

    static func prepareForTranslation(_ english: String) -> Prepared {
        var s = english
        var closing: String? = nil
        for c in closings where matches(s, c.pattern) {
            let question = s.trimmingCharacters(in: .whitespaces).hasSuffix("?")
            s = replace(s, c.pattern, "")
            if question, !s.isEmpty { s += "?" }       // "Do you copy me, over?" stays a question
            closing = c.turkish
            break
        }
        var protected: [String] = []
        let patterns = [#"\b"# + callsignPattern + #"\b"#, spelledRunPattern] + protectedPatterns
        for p in patterns {
            let re = try! NSRegularExpression(pattern: p, options: p == spelledRunPattern ? [.caseInsensitive] : [])
            let ms = re.matches(in: s, range: NSRange(s.startIndex..., in: s))
            for m in ms.reversed() {
                guard let r = Range(m.range, in: s) else { continue }
                protected.append(String(s[r]))
                s.replaceSubrange(r, with: placeholderPrefix + String(protected.count - 1))
            }
        }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.hasSuffix(",") { s.removeLast(); s += "." }
        return Prepared(text: s, protected: protected, closing: closing)
    }

    static func finishTranslation(_ turkish: String, _ p: Prepared) -> String {
        var s = turkish
        for (pat, rep) in turkishFixes { s = replace(s, pat, rep) }
        // Restore placeholders, highest index first so ZXQ1 does not eat ZXQ10.
        for i in stride(from: p.protected.count - 1, through: 0, by: -1) {
            s = s.replacingOccurrences(of: placeholderPrefix + String(i), with: p.protected[i])
        }
        s = s.trimmingCharacters(in: .whitespaces)
        if let c = p.closing { s = s.isEmpty ? c : s + " " + c }
        return s
    }

    /// Text that is only a closing word ("Over.") translates to just the closing.
    static func isOnlyClosing(_ p: Prepared) -> Bool {
        p.text.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).isEmpty
    }

    // MARK: - Helpers

    private static func matches(_ s: String, _ pattern: String) -> Bool {
        let re = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Case-insensitive replace; when the match starts with a capital, so does the replacement.
    static func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        let re = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let ms = re.matches(in: s, range: NSRange(s.startIndex..., in: s))
        guard !ms.isEmpty else { return s }
        var out = s
        for m in ms.reversed() {
            guard let r = Range(m.range, in: out) else { continue }
            var rep = re.replacementString(for: m, in: out, offset: 0, template: template)
            if let f = out[r].first, f.isUppercase, let rf = rep.first, rf.isLowercase {
                rep = rf.uppercased() + rep.dropFirst()
            }
            out.replaceSubrange(r, with: rep)
        }
        return out
    }
}

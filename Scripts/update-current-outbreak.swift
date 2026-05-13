#!/usr/bin/env swift

import Foundation

struct OutbreakFeed: Codable {
    let confirmedCases: Int
    let dataAsOf: String
    let deaths: Int
    let diseaseName: String
    let eventName: String
    let locationSummary: String
    let methodology: String
    let inconclusiveCases: Int
    let probableCases: Int
    let publicHealthNote: String
    let riskSummary: String
    let sourceName: String
    let sourcePublishedAt: String
    let sourceURL: String
    let suspectedCases: Int
    let totalCases: Int
}

struct OutbreakHistoryPoint: Codable, Equatable {
    let dataAsOf: String
    let totalCases: Int
    let confirmedCases: Int
    let probableCases: Int
    let suspectedCases: Int
    let inconclusiveCases: Int
    let deaths: Int

    enum CodingKeys: String, CodingKey {
        case dataAsOf
        case totalCases
        case confirmedCases
        case probableCases
        case suspectedCases
        case inconclusiveCases
        case deaths
    }

    init(feed: OutbreakFeed) {
        dataAsOf = feed.dataAsOf
        totalCases = feed.totalCases
        confirmedCases = feed.confirmedCases
        probableCases = feed.probableCases
        suspectedCases = feed.suspectedCases
        inconclusiveCases = feed.inconclusiveCases
        deaths = feed.deaths
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dataAsOf = try container.decode(String.self, forKey: .dataAsOf)
        totalCases = try container.decode(Int.self, forKey: .totalCases)
        confirmedCases = try container.decode(Int.self, forKey: .confirmedCases)
        probableCases = try container.decode(Int.self, forKey: .probableCases)
        suspectedCases = try container.decode(Int.self, forKey: .suspectedCases)
        inconclusiveCases = try container.decodeIfPresent(Int.self, forKey: .inconclusiveCases) ?? 0
        deaths = try container.decode(Int.self, forKey: .deaths)
    }
}

enum UpdateError: Error, CustomStringConvertible {
    case invalidURL(String)
    case fetchFailed(URL)
    case missingValue(String)
    case invalidDate(String)

    var description: String {
        switch self {
        case .invalidURL(let value):
            return "Invalid URL: \(value)"
        case .fetchFailed(let url):
            return "Could not fetch official source: \(url.absoluteString)"
        case .missingValue(let label):
            return "Could not find \(label) on the official source page"
        case .invalidDate(let value):
            return "Could not parse source date: \(value)"
        }
    }
}

let sourceURLString = ProcessInfo.processInfo.environment["ECDC_OUTBREAK_URL"]
    ?? "https://www.ecdc.europa.eu/en/infectious-disease-topics/hantavirus-infection/surveillance-and-updates/andes-hantavirus-outbreak"

guard let sourceURL = URL(string: sourceURLString) else {
    throw UpdateError.invalidURL(sourceURLString)
}

let html: String
do {
    html = try String(contentsOf: sourceURL, encoding: .utf8)
} catch {
    throw UpdateError.fetchFailed(sourceURL)
}

let pageText = normalize(html)

let sourceDate = try parseSourceDate(from: pageText)
let confirmedCases = try number(after: "Confirmed cases", in: pageText)
let probableCases = try number(after: "Probable cases", in: pageText)
let suspectedCases = try number(after: "Suspected cases", in: pageText)
let inconclusiveCases = try number(after: "Inconclusive cases", in: pageText)
let deaths = try number(after: "Number of deaths", in: pageText)
let totalCases = try parseTotalCases(from: pageText) ?? confirmedCases + probableCases + suspectedCases + inconclusiveCases

let feed = OutbreakFeed(
    confirmedCases: confirmedCases,
    dataAsOf: sourceDate,
    deaths: deaths,
    diseaseName: "Hantavirus",
    eventName: "Andes hantavirus outbreak linked to MV Hondius",
    locationSummary: "Multi-country event linked to cruise-ship travel",
    methodology: "Counts are published from official public health sources only. Confirmed, probable, suspected, inconclusive, and non-case definitions follow the linked public health source.",
    inconclusiveCases: inconclusiveCases,
    probableCases: probableCases,
    publicHealthNote: "This independent app is informational only and is not affiliated with WHO, ECDC, CDC, or any public health agency. It is not a diagnosis, treatment, quarantine, or travel guidance tool. Follow local public health authority instructions and seek medical care for symptoms or exposure concerns.",
    riskSummary: "ECDC assesses the risk to the EU/EEA general population as very low. WHO assesses the global population risk as low.",
    sourceName: "ECDC daily outbreak update",
    sourcePublishedAt: sourceDate,
    sourceURL: sourceURL.absoluteString,
    suspectedCases: suspectedCases,
    totalCases: totalCases
)

try writeJSON(feed, to: "docs/current-outbreak.json")

let historyURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("docs/outbreak-history.json")
let currentHistoryPoint = OutbreakHistoryPoint(feed: feed)
var history = loadHistory(from: historyURL)

history.removeAll { $0.dataAsOf == currentHistoryPoint.dataAsOf }
history.append(currentHistoryPoint)
history.sort { $0.dataAsOf < $1.dataAsOf }
try writeJSON(history, to: "docs/outbreak-history.json")

print("Updated docs/current-outbreak.json")
print("Updated docs/outbreak-history.json")
print("Data as of: \(sourceDate)")
print("Total: \(totalCases), confirmed: \(confirmedCases), probable: \(probableCases), suspected: \(suspectedCases), inconclusive: \(inconclusiveCases), deaths: \(deaths)")
print("History points: \(history.count)")

func normalize(_ html: String) -> String {
    var text = html.replacingOccurrences(
        of: #"(?is)<(script|style).*?</\1>"#,
        with: " ",
        options: .regularExpression
    )
    text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "\n", options: .regularExpression)
    text = text
        .replacingOccurrences(of: "&nbsp;", with: " ")
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&#039;", with: "'")
    text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

func parseSourceDate(from text: String) throws -> String {
    let pattern = #"Andes hantavirus outbreak in cruise ship,\s+([0-9]{1,2}\s+[A-Za-z]+\s+[0-9]{4})"#
    let sourceDate = try capture(pattern, in: text, label: "source publication date")

    let inputFormatter = DateFormatter()
    inputFormatter.locale = Locale(identifier: "en_US_POSIX")
    inputFormatter.timeZone = TimeZone(secondsFromGMT: 0)
    inputFormatter.dateFormat = "d MMMM yyyy"

    guard let date = inputFormatter.date(from: sourceDate) else {
        throw UpdateError.invalidDate(sourceDate)
    }

    let outputFormatter = DateFormatter()
    outputFormatter.locale = Locale(identifier: "en_US_POSIX")
    outputFormatter.timeZone = TimeZone(secondsFromGMT: 0)
    outputFormatter.dateFormat = "yyyy-MM-dd"
    return outputFormatter.string(from: date)
}

func parseTotalCases(from text: String) throws -> Int? {
    let patterns = [
        #"As of [0-9]{1,2} [A-Za-z]+,\s+([a-zA-Z0-9]+)\s+cases have been reported in total"#,
        #"As of [0-9]{1,2} [A-Za-z]+,\s+a total of\s+([a-zA-Z0-9]+)\s+cases have been reported"#
    ]

    for pattern in patterns {
        if let value = try? capture(pattern, in: text, label: "total cases") {
            return intFromWordOrDigits(value)
        }
    }

    return nil
}

func number(after label: String, in text: String) throws -> Int {
    let pattern = NSRegularExpression.escapedPattern(for: label) + #"\*{0,4}\s+([0-9]+)"#
    let value = try capture(pattern, in: text, label: label)
    guard let number = Int(value) else {
        throw UpdateError.missingValue(label)
    }
    return number
}

func capture(_ pattern: String, in text: String, label: String) throws -> String {
    let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range),
          match.numberOfRanges > 1,
          let captureRange = Range(match.range(at: 1), in: text) else {
        throw UpdateError.missingValue(label)
    }
    return String(text[captureRange])
}

func intFromWordOrDigits(_ value: String) -> Int? {
    if let number = Int(value) {
        return number
    }

    let words: [String: Int] = [
        "zero": 0,
        "one": 1,
        "two": 2,
        "three": 3,
        "four": 4,
        "five": 5,
        "six": 6,
        "seven": 7,
        "eight": 8,
        "nine": 9,
        "ten": 10,
        "eleven": 11,
        "twelve": 12,
        "thirteen": 13,
        "fourteen": 14,
        "fifteen": 15,
        "sixteen": 16,
        "seventeen": 17,
        "eighteen": 18,
        "nineteen": 19,
        "twenty": 20
    ]
    return words[value.lowercased()]
}

func loadHistory(from url: URL) -> [OutbreakHistoryPoint] {
    guard FileManager.default.fileExists(atPath: url.path),
          let data = try? Data(contentsOf: url),
          let history = try? JSONDecoder().decode([OutbreakHistoryPoint].self, from: data) else {
        return []
    }

    return history
}

func writeJSON<T: Encodable>(_ value: T, to path: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value)
    data.append(0x0A)

    let outputURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(path)
    try data.write(to: outputURL, options: .atomic)
}

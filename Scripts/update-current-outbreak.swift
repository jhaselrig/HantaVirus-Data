#!/usr/bin/env swift

import Foundation

struct OutbreakFeed: Encodable {
    let confirmedCases: Int
    let dataAsOf: String
    let deaths: Int
    let diseaseName: String
    let eventName: String
    let locationSummary: String
    let methodology: String
    let probableCases: Int
    let publicHealthNote: String
    let riskSummary: String
    let sourceName: String
    let sourcePublishedAt: String
    let sourceURL: String
    let suspectedCases: Int
    let totalCases: Int
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
let deaths = try number(after: "Number of deaths", in: pageText)
let totalCases = try parseTotalCases(from: pageText) ?? confirmedCases + probableCases

let feed = OutbreakFeed(
    confirmedCases: confirmedCases,
    dataAsOf: sourceDate,
    deaths: deaths,
    diseaseName: "Hantavirus",
    eventName: "Andes hantavirus outbreak linked to MV Hondius",
    locationSummary: "Multi-country event linked to cruise-ship travel",
    methodology: "Counts are published from official public health sources only. Confirmed, probable, suspected, and non-case definitions follow the linked public health source.",
    probableCases: probableCases,
    publicHealthNote: "This independent app is informational only and is not affiliated with WHO, ECDC, CDC, or any public health agency. It is not a diagnosis, treatment, quarantine, or travel guidance tool. Follow local public health authority instructions and seek medical care for symptoms or exposure concerns.",
    riskSummary: "ECDC assesses the risk to the EU/EEA general population as very low. WHO assesses the global population risk as low.",
    sourceName: "ECDC daily outbreak update",
    sourcePublishedAt: sourceDate,
    sourceURL: sourceURL.absoluteString,
    suspectedCases: suspectedCases,
    totalCases: totalCases
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
var data = try encoder.encode(feed)
data.append(0x0A)
let outputURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("docs/current-outbreak.json")
try data.write(to: outputURL, options: .atomic)

print("Updated docs/current-outbreak.json")
print("Data as of: \(sourceDate)")
print("Total: \(totalCases), confirmed: \(confirmedCases), probable: \(probableCases), suspected: \(suspectedCases), deaths: \(deaths)")

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
    let pattern = #"As of [0-9]{1,2} [A-Za-z]+,\s+([a-zA-Z0-9]+)\s+cases have been reported in total"#
    guard let value = try? capture(pattern, in: text, label: "total cases") else {
        return nil
    }
    return intFromWordOrDigits(value)
}

func number(after label: String, in text: String) throws -> Int {
    let pattern = NSRegularExpression.escapedPattern(for: label) + #"\*{0,3}\s+([0-9]+)"#
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

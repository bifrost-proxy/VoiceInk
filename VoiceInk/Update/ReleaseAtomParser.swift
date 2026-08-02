import Foundation

struct ReleaseAtomEntry: Equatable {
    let tag: String
    let releaseURL: URL
}

final class ReleaseAtomParser: NSObject, XMLParserDelegate {
    private var entries: [ReleaseAtomEntry] = []
    private var currentTag: String?
    private var currentReleaseURL: URL?
    private var text = ""
    private var isInsideEntry = false
    private var parseFailure: Error?

    static func parse(_ data: Data) throws -> [ReleaseAtomEntry] {
        let delegate = ReleaseAtomParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate

        guard parser.parse(), delegate.parseFailure == nil else {
            throw delegate.parseFailure ?? parser.parserError ?? UpdateService.Failure.invalidRelease
        }
        return delegate.entries
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        text = ""
        if elementName == "entry" {
            isInsideEntry = true
            currentTag = nil
            currentReleaseURL = nil
        } else if isInsideEntry,
            elementName == "link",
            attributeDict["rel"] == "alternate",
            let value = attributeDict["href"],
            let url = URL(string: value)
        {
            currentReleaseURL = url
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard isInsideEntry else { return }
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard isInsideEntry else { return }

        switch elementName {
        case "id":
            currentTag = text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "/")
                .last
                .map(String.init)
        case "entry":
            if let currentTag, let currentReleaseURL {
                entries.append(ReleaseAtomEntry(tag: currentTag, releaseURL: currentReleaseURL))
            }
            isInsideEntry = false
        default:
            break
        }
        text = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        parseFailure = parseError
    }
}

import XCTest
@testable import GuessWhoLogging

final class WebExtensionMessageCodecTests: XCTestCase {
    func testExtractsDirectAndWrappedMessages() throws {
        let directPayload: [String: Any] = ["payload": ["name": "Ada"]]
        let payload = try XCTUnwrap(
            WebExtensionMessageCodec.extractPayload(from: directPayload) as? [String: String]
        )
        XCTAssertEqual(payload, ["name": "Ada"])

        let wrappedDiagnostic: [String: Any] = [
            "message": ["diagnostic": ["event": "ready"]]
        ]
        let diagnostic = try XCTUnwrap(
            WebExtensionMessageCodec.extractDiagnostic(from: wrappedDiagnostic) as? [String: String]
        )
        XCTAssertEqual(diagnostic, ["event": "ready"])

        let wrappedPayload: [String: Any] = [
            "message": ["payload": ["name": "Grace"]]
        ]
        XCTAssertNotNil(WebExtensionMessageCodec.extractPayload(from: wrappedPayload))

        let directDiagnostic: [String: Any] = [
            "diagnostic": ["event": "timeout"]
        ]
        XCTAssertNotNil(WebExtensionMessageCodec.extractDiagnostic(from: directDiagnostic))
        XCTAssertNil(WebExtensionMessageCodec.extractPayload(from: ["unrelated": true]))
    }

    func testDirectShapeTakesPrecedenceOverWrappedShape() throws {
        let raw: [String: Any] = [
            "payload": ["source": "direct"],
            "message": ["payload": ["source": "wrapped"]],
        ]
        let payload = try XCTUnwrap(
            WebExtensionMessageCodec.extractPayload(from: raw) as? [String: String]
        )
        XCTAssertEqual(payload["source"], "direct")
    }

    func testMessageShapeContainsKeysButNeverValues() {
        let raw: [String: Any] = [
            "payload": ["photo": "SECRET_BASE64", "name": "SECRET_NAME"],
            "transport": "SECRET_TRANSPORT_VALUE",
        ]
        let shape = WebExtensionMessageCodec.messageShape(raw)

        XCTAssertEqual(shape, "outerKeys=payload,transport innerKeys=-")
        XCTAssertFalse(shape.contains("SECRET"))

        let wrapped: [String: Any] = [
            "message": ["diagnostic": ["prose": "SECRET_PROSE"]],
            "wrapper": "SECRET_WRAPPER_VALUE",
        ]
        let wrappedShape = WebExtensionMessageCodec.messageShape(wrapped)
        XCTAssertEqual(wrappedShape, "outerKeys=message,wrapper innerKeys=diagnostic")
        XCTAssertFalse(wrappedShape.contains("SECRET"))

        XCTAssertTrue(WebExtensionMessageCodec.messageShape(nil).hasPrefix("type="))
    }

    func testDiagnosticDescriptionIsSortedCompactJSON() {
        let diagnostic: [String: Any] = ["version": 1, "event": "ready"]
        XCTAssertEqual(
            WebExtensionMessageCodec.diagnosticDescription(diagnostic),
            #"{"event":"ready","version":1}"#
        )
    }

    func testDiagnosticDescriptionRejectsInvalidObject() {
        let invalid: [String: Any] = ["date": Date()]
        XCTAssertEqual(
            WebExtensionMessageCodec.diagnosticDescription(invalid),
            "<invalid diagnostic>"
        )
    }

    func testDiagnosticDescriptionRejectsOversizedObjectBeforeSerialization() {
        let oversized: [String: Any] = [
            "value": String(
                repeating: "x",
                count: WebExtensionMessageCodec.maximumDiagnosticBytes
            )
        ]
        XCTAssertEqual(
            WebExtensionMessageCodec.diagnosticDescription(oversized),
            "<diagnostic exceeds preflight bound>"
        )
    }

    func testRepresentativeMaximumDOMFingerprintFitsBound() {
        let attribute: [String: Any] = [
            "present": true,
            "length": 160,
            "kind": "entity-collection-item",
        ]
        let ancestor: [String: Any] = [
            "depth": 7,
            "element": [
                "tag": "section",
                "id": attribute,
                "role": attribute,
                "componentKey": attribute,
                "testId": attribute,
                "viewName": attribute,
                "overflowY": "scroll",
                "clientHeight": 844,
                "scrollHeight": 9_999,
            ],
            "entityItemCount": 20,
            "paragraphCount": 100,
            "listItemCount": 20,
            "nullStateAnchors": Array(repeating: "null-state-experience", count: 8),
        ]
        let paragraph: [String: Any] = [
            "characterCount": 180,
            "lineCount": 4,
            "separatorCount": 2,
            "hasStructuredDateRange": true,
            "looksLikeBareDuration": false,
        ]
        let diagnostic: [String: Any] = [
            "version": 1,
            "probeId": "00000000-0000-0000-0000-000000000000",
            "event": "final-readiness",
            "elapsedMs": 30_000,
            "page": [
                "host": "www.linkedin.com",
                "route": "/in/<redacted>",
                "userAgent": String(repeating: "u", count: 300),
                "viewport": ["width": 390, "height": 844],
            ],
            "detail": [
                "dom": [
                    "headings": Array(
                        repeating: [
                            "tag": "h2",
                            "characterCount": 100,
                            "semanticKey": "experience",
                        ],
                        count: 40
                    ),
                    "experienceHeadingFound": true,
                    "experienceAncestors": Array(repeating: ancestor, count: 8),
                    "experienceParagraphShapes": Array(repeating: paragraph, count: 30),
                ]
            ],
        ]

        let description = WebExtensionMessageCodec.diagnosticDescription(diagnostic)
        XCTAssertTrue(description.hasPrefix("{"), description)
        XCTAssertLessThanOrEqual(
            description.utf8.count,
            WebExtensionMessageCodec.maximumDiagnosticBytes
        )
    }
}

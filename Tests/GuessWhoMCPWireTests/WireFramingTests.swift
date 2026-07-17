import XCTest
import GuessWhoMCPWire
import MCP

/// Newline-JSON framing rests on ONE rule: every writer serializes through
/// a real JSONEncoder (which escapes \n and \r), never hand-concatenation.
/// These tests prove adversarial values can't forge extra frames.
final class WireFramingTests: XCTestCase {

    private let injections = [
        "line one\nline two",
        "carriage\rreturn",
        "forged frame }\n{\"contactsSearch\":{}}",
        "mixed\r\n\r\nnewlines\n",
    ]

    func testEncodedRequestIsAlwaysOneLine() throws {
        for payload in injections {
            let request = WireRequest.contactsSearch(
                helperId: "mcp-test", messageId: "m1",
                query: payload, limit: nil, cursor: nil)
            let encoded = try JSONEncoder().encode(request)
            XCTAssertFalse(
                encoded.contains(0x0A),
                "raw newline escaped the encoder for payload \(payload)")
            XCTAssertFalse(
                encoded.contains(0x0D),
                "raw carriage return escaped the encoder for payload \(payload)")
        }
    }

    func testInjectionPayloadRoundTripsAsOneMessage() throws {
        for payload in injections {
            let request = WireRequest.contactsSearch(
                helperId: "mcp-test", messageId: "m1",
                query: payload, limit: 5, cursor: nil)
            let encoded = try JSONEncoder().encode(request)
            let decoded = try JSONDecoder().decode(WireRequest.self, from: encoded)
            guard case .contactsSearch(_, _, let query, let limit, _) = decoded else {
                return XCTFail("wrong case decoded")
            }
            XCTAssertEqual(query, payload, "value must survive the round trip intact")
            XCTAssertEqual(limit, 5)
        }
    }

    func testResponseRoundTripsIntact() throws {
        let page = WirePage(
            items: [
                WireNote(
                    id: "abc123", body: "notes with\nnewlines and }\n{ braces",
                    createdAt: "2026-01-01T00:00:00Z", modifiedAt: "2026-01-02T00:00:00Z")
            ],
            nextCursor: "o50")
        let response = WireResponse.notePage(helperId: "mcp-test", messageId: "m2", page: page)
        let encoded = try JSONEncoder().encode(response)
        XCTAssertFalse(encoded.contains(0x0A))
        let decoded = try JSONDecoder().decode(WireResponse.self, from: encoded)
        guard case .notePage(_, _, let decodedPage) = decoded else {
            return XCTFail("wrong case decoded")
        }
        XCTAssertEqual(decodedPage.items.first?.body, page.items.first?.body)
        XCTAssertEqual(decodedPage.nextCursor, "o50")
    }

    /// Control messages must stay far under the 512-byte Darwin PIPE_BUF
    /// atomicity ceiling — the announce channel's forever-rule.
    func testControlMessagesStayUnderPipeBuf() throws {
        let helperId = RequestOrigin.mcp.makeHelperId()
        let control: [WireRequest] = [
            .initialize(helperId: helperId, messageId: "init-1"),
            .deinitialize(helperId: helperId),
        ]
        for message in control {
            let encoded = try JSONEncoder().encode(message)
            XCTAssertLessThanOrEqual(
                encoded.count + 1, WireEnvironment.darwinPipeBuf,
                "control frame too big for atomic shared-FIFO writes")
        }
    }
}

final class WireRequestCreateTests: XCTestCase {
    private func params(_ name: String, _ arguments: [String: Value]? = nil) -> MCP.CallTool.Parameters {
        MCP.CallTool.Parameters(name: name, arguments: arguments)
    }

    func testUnknownToolThrowsPlainError() {
        XCTAssertThrowsError(try WireRequest.create(
            helperId: "h", messageId: "m", parameters: params("no_such_tool"))
        ) { error in
            let text = String(describing: error as! WireRequestError)
            XCTAssertTrue(text.contains("no_such_tool"))
        }
    }

    func testMissingRequiredArgumentThrows() {
        XCTAssertThrowsError(try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.contactsGet.rawValue)))
    }

    func testValidSearchRequestParses() throws {
        let request = try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.contactsSearch.rawValue, [
                "query": "jane", "limit": 10,
            ]))
        guard case .contactsSearch(_, _, let query, let limit, let cursor) = request else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(query, "jane")
        XCTAssertEqual(limit, 10)
        XCTAssertNil(cursor)
    }

    func testNonIntegerLimitRejected() {
        XCTAssertThrowsError(try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.contactsSearch.rawValue, [
                "query": "jane", "limit": "lots",
            ])))
    }

    func testEveryToolNameIsClientSafe() {
        for tool in MCPTool.allCases {
            XCTAssertNotNil(
                tool.rawValue.range(of: #"^[a-z0-9_]{1,64}$"#, options: .regularExpression),
                "\(tool.rawValue) is not a safe MCP/API tool name")
        }
    }
}

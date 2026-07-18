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

    // MARK: - contacts_update is scalars-only (Phase 7)

    private func expectUnsupported(
        _ arguments: [String: Value], message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        var args = arguments
        args["contactId"] = "some-contact-id"
        XCTAssertThrowsError(
            try WireRequest.create(
                helperId: "h", messageId: "m",
                parameters: params(MCPTool.contactsUpdate.rawValue, args)),
            file: file, line: line
        ) { error in
            guard case WireRequestError.unsupportedArgument(let text) = error else {
                return XCTFail("expected the typed rejection, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(text, message, file: file, line: line)
        }
    }

    /// Every list-shaped argument on contacts_update is rejected LOUDLY
    /// with a pointer to the dedicated single-entry tools — a silently
    /// dropped list would read as a saved bulk edit.
    func testUpdateRejectsEverySingleEntryEditableListArgument() {
        let entries: Value = .array([.object(["value": "x"])])
        for key in ["phoneNumbers", "emailAddresses", "urlAddresses", "relatedNames", "dates"] {
            expectUnsupported(
                [key: entries], message: WireErrorMessage.listArgumentNotAccepted)
        }
    }

    /// The lists with no single-entry tools yet get their own honest
    /// rejection (create-only), not the "use the one-entry tools" pointer.
    func testUpdateRejectsCreateOnlyListArguments() {
        let entries: Value = .array([.object(["street": "1 Main St"])])
        for key in ["postalAddresses", "socialProfiles", "instantMessages"] {
            expectUnsupported(
                [key: entries], message: WireErrorMessage.createOnlyListArgumentNotAccepted)
        }
    }

    func testUpdateStillRejectsNoteShapedArguments() {
        expectUnsupported(
            ["note": "sneaky"], message: WireErrorMessage.contactNoteNotAccepted)
    }

    func testUpdateParsesScalarFields() throws {
        let request = try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.contactsUpdate.rawValue, [
                "contactId": "some-contact-id",
                "jobTitle": "Director",
                "birthday": "1984-03-14",
            ]))
        guard case .contactsUpdate(_, _, let contactId, let fields, _) = request else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(contactId, "some-contact-id")
        XCTAssertEqual(fields.jobTitle, "Director")
        XCTAssertEqual(fields.birthday, "1984-03-14")
    }

    func testCreateStillAcceptsListFields() throws {
        let request = try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.contactsCreate.rawValue, [
                "givenName": "Nova",
                "phoneNumbers": .array([.object(["label": "mobile", "value": "+1 555 0111"])]),
            ]))
        guard case .contactsCreate(_, _, _, let fields, _) = request else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(fields.phoneNumbers, [WireLabeledValue(label: "mobile", value: "+1 555 0111")])
    }

    // MARK: - Single-entry list tool parsing

    func testAddPhoneParsesAndRequiresValue() throws {
        let request = try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.contactsAddPhone.rawValue, [
                "contactId": "some-contact-id",
                "value": "+1 555 0100",
                "label": "work",
            ]))
        guard case .contactsAddPhone(_, _, let contactId, let value, let label, _) = request else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(contactId, "some-contact-id")
        XCTAssertEqual(value, "+1 555 0100")
        XCTAssertEqual(label, "work")

        XCTAssertThrowsError(try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.contactsAddPhone.rawValue, [
                "contactId": "some-contact-id",
            ])))
    }

    func testEditEmailParsesAndRequiresNewValue() throws {
        let request = try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.contactsEditEmail.rawValue, [
                "contactId": "some-contact-id",
                "currentValue": "old@example.com",
                "newValue": "new@example.com",
            ]))
        guard case .contactsEditEmail(_, _, _, let current, let newValue, let newLabel, _) = request
        else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(current, "old@example.com")
        XCTAssertEqual(newValue, "new@example.com")
        XCTAssertNil(newLabel)

        XCTAssertThrowsError(try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.contactsEditEmail.rawValue, [
                "contactId": "some-contact-id",
                "currentValue": "old@example.com",
            ])))
    }

    func testRemoveDateParses() throws {
        let request = try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.contactsRemoveDate.rawValue, [
                "contactId": "some-contact-id",
                "value": "--12-25",
            ]))
        guard case .contactsRemoveDate(_, _, _, let value, _) = request else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(value, "--12-25")
    }
}

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

    func testContactsListParsesOptionalFavoritesAndGroupFilters() throws {
        let request = try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.contactsList.rawValue, [
                "kind": "person", "favoritesOnly": true, "groupId": "g-1",
            ]))
        guard case .contactsList(_, _, let kind, let favoritesOnly, let groupId, _, _) = request else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(kind, "person")
        XCTAssertEqual(favoritesOnly, true)
        XCTAssertEqual(groupId, "g-1")
    }

    /// Absent filters decode to nil (no filtering on that axis), and the
    /// string spelling some clients send for booleans is tolerated.
    func testContactsListFiltersDefaultNilAndTolerateStringBool() throws {
        let bare = try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.contactsList.rawValue))
        guard case .contactsList(_, _, let kind, let favoritesOnly, let groupId, _, _) = bare else {
            return XCTFail("wrong case")
        }
        XCTAssertNil(kind)
        XCTAssertNil(favoritesOnly)
        XCTAssertNil(groupId)

        let stringBool = try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.contactsList.rawValue, ["favoritesOnly": "true"]))
        guard case .contactsList(_, _, _, let parsed, _, _, _) = stringBool else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(parsed, true)
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

    func testToolInventoryCountAndReadWriteSplit() {
        // 34 total after change #3 folded the standalone favorites and
        // group-members reads into contacts_list filters (reads 15 → 13).
        XCTAssertEqual(MCPTool.allCases.count, 34)
        XCTAssertEqual(MCPTool.allCases.filter { !$0.isWrite }.count, 13)
        XCTAssertEqual(MCPTool.allCases.filter { $0.isWrite }.count, 21)
    }

    func testListVerbSchemasUseRealFieldEnumAndHaveNoArrayParameters() {
        let expectedFields = ["phone", "email", "url", "related_name", "date"]
        for tool in [MCPTool.contactsAddValue, .contactsDeleteValue, .contactsEditValue] {
            guard case .object(let schema) = tool.metadata.inputSchema,
                  case .object(let properties) = schema["properties"],
                  case .object(let field) = properties["field"],
                  case .array(let values) = field["enum"]
            else {
                return XCTFail("\(tool.rawValue) must expose a real field enum")
            }
            XCTAssertEqual(values.compactMap(\.stringValue), expectedFields)
            for (name, property) in properties {
                guard case .object(let propertySchema) = property else {
                    return XCTFail("\(tool.rawValue).\(name) schema is not an object")
                }
                XCTAssertNotEqual(
                    propertySchema["type"]?.stringValue, "array",
                    "\(tool.rawValue).\(name) must remain a single value")
            }
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

    func testAddValueParsesAndRequiresFieldAndValue() throws {
        let request = try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.contactsAddValue.rawValue, [
                "contactId": "some-contact-id",
                "field": "phone",
                "value": "+1 555 0100",
                "label": "work",
            ]))
        guard case .contactsAddValue(
            _, _, let contactId, let field, let value, let label, _
        ) = request else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(contactId, "some-contact-id")
        XCTAssertEqual(field, "phone")
        XCTAssertEqual(value, "+1 555 0100")
        XCTAssertEqual(label, "work")

        XCTAssertThrowsError(try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.contactsAddValue.rawValue, [
                "contactId": "some-contact-id",
                "field": "phone",
            ])))
        XCTAssertThrowsError(try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.contactsAddValue.rawValue, [
                "contactId": "some-contact-id",
                "value": "+1 555 0100",
            ])))
    }

    func testEditValueParsesAndRequiresNewValue() throws {
        let request = try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.contactsEditValue.rawValue, [
                "contactId": "some-contact-id",
                "field": "email",
                "currentValue": "old@example.com",
                "newValue": "new@example.com",
            ]))
        guard case .contactsEditValue(
            _, _, _, let field, let current, let newValue, let newLabel, _
        ) = request
        else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(field, "email")
        XCTAssertEqual(current, "old@example.com")
        XCTAssertEqual(newValue, "new@example.com")
        XCTAssertNil(newLabel)

        XCTAssertThrowsError(try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.contactsEditValue.rawValue, [
                "contactId": "some-contact-id",
                "field": "email",
                "currentValue": "old@example.com",
            ])))
    }

    func testDeleteValueParses() throws {
        let request = try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.contactsDeleteValue.rawValue, [
                "contactId": "some-contact-id",
                "field": "date",
                "value": "--12-25",
            ]))
        guard case .contactsDeleteValue(_, _, _, let field, let value, _) = request else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(field, "date")
        XCTAssertEqual(value, "--12-25")
    }

    func testInvalidListFieldNamesAllValidValues() {
        for invalidField in ["birthday", "postal", ""] {
            XCTAssertThrowsError(try WireRequest.create(
                helperId: "h", messageId: "m",
                parameters: params(MCPTool.contactsAddValue.rawValue, [
                    "contactId": "some-contact-id",
                    "field": .string(invalidField),
                    "value": "--12-25",
                ]))) { error in
                XCTAssertEqual(
                    String(describing: error),
                    WireErrorMessage.invalidContactListField)
            }
        }
    }

    // MARK: - Derived scalar-field views (keypath single-sourcing)

    /// providedFieldNames feeds audit summaries; its ORDER is a wire-visible
    /// contract, so lock the exact sequence the keypath table must emit.
    func testScalarFieldsProvidedNamesOrderIsStable() {
        var fields = WireContactScalarFields()
        fields.namePrefix = "Dr."
        fields.givenName = "Ada"
        fields.middleName = "M"
        fields.familyName = "Lovelace"
        fields.previousFamilyName = "Byron"
        fields.nameSuffix = "Jr."
        fields.nickname = "Ada"
        fields.phoneticGivenName = "AY-dah"
        fields.phoneticMiddleName = "em"
        fields.phoneticFamilyName = "LUV-lace"
        fields.organization = "Analytical Engines"
        fields.phoneticOrganization = "an-uh-LIT-i-kal"
        fields.department = "R&D"
        fields.jobTitle = "Countess"
        fields.birthday = "1815-12-10"
        XCTAssertEqual(fields.providedFieldNames, [
            "namePrefix", "givenName", "middleName", "familyName",
            "previousFamilyName", "nameSuffix", "nickname",
            "phoneticGivenName", "phoneticMiddleName", "phoneticFamilyName",
            "organization", "phoneticOrganization", "department", "jobTitle",
            "birthday",
        ])
        XCTAssertFalse(fields.isEmpty)
        XCTAssertTrue(WireContactScalarFields().isEmpty)
    }

    /// The full contacts_create field set INTERLEAVES its list fields — note
    /// that `birthday` lands AFTER the first list block, not with the other
    /// scalars. This exact order is what audit summaries render.
    func testContactFieldsProvidedNamesOrderIsStable() {
        var fields = WireContactFields()
        fields.namePrefix = "Dr."
        fields.givenName = "Ada"
        fields.middleName = "M"
        fields.familyName = "Lovelace"
        fields.previousFamilyName = "Byron"
        fields.nameSuffix = "Jr."
        fields.nickname = "Ada"
        fields.phoneticGivenName = "AY-dah"
        fields.phoneticMiddleName = "em"
        fields.phoneticFamilyName = "LUV-lace"
        fields.organization = "Analytical Engines"
        fields.phoneticOrganization = "an-uh-LIT-i-kal"
        fields.department = "R&D"
        fields.jobTitle = "Countess"
        fields.phoneNumbers = [WireLabeledValue(label: nil, value: "555")]
        fields.emailAddresses = [WireLabeledValue(label: nil, value: "a@x.example")]
        fields.postalAddresses = []
        fields.urlAddresses = [WireLabeledValue(label: nil, value: "https://x.example")]
        fields.birthday = "1815-12-10"
        fields.dates = []
        fields.socialProfiles = []
        fields.instantMessages = []
        fields.relatedNames = [WireLabeledValue(label: nil, value: "Charles Babbage")]
        XCTAssertEqual(fields.providedFieldNames, [
            "namePrefix", "givenName", "middleName", "familyName",
            "previousFamilyName", "nameSuffix", "nickname",
            "phoneticGivenName", "phoneticMiddleName", "phoneticFamilyName",
            "organization", "phoneticOrganization", "department", "jobTitle",
            "phoneNumbers", "emailAddresses", "postalAddresses", "urlAddresses",
            "birthday",
            "dates", "socialProfiles", "instantMessages", "relatedNames",
        ])
        XCTAssertFalse(fields.isEmpty)
        XCTAssertTrue(WireContactFields().isEmpty)
    }

    /// scalarFields must carry every scalar through unchanged and drop the
    /// list fields — the shared create/update apply path depends on it.
    func testContactFieldsScalarSubsetCopiesEveryScalar() {
        var fields = WireContactFields()
        fields.givenName = "Ada"
        fields.familyName = "Lovelace"
        fields.jobTitle = "Countess"
        fields.birthday = "1815-12-10"
        fields.phoneNumbers = [WireLabeledValue(label: nil, value: "555")]
        let scalars = fields.scalarFields
        XCTAssertEqual(scalars.givenName, "Ada")
        XCTAssertEqual(scalars.familyName, "Lovelace")
        XCTAssertEqual(scalars.jobTitle, "Countess")
        XCTAssertEqual(scalars.birthday, "1815-12-10")
        // The scalar subset carries no list fields, so its provided-names
        // list is exactly the scalars that were set.
        XCTAssertEqual(scalars.providedFieldNames, [
            "givenName", "familyName", "jobTitle", "birthday",
        ])
    }
}

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

    func testPlaceReadRequestsAndResponseRoundTripIntact() throws {
        let requests: [WireRequest] = [
            .guidesListForPlace(
                helperId: "mcp-test", messageId: "containing", placeId: "place-1",
                limit: 17, cursor: "o34"),
            .placesSearch(
                helperId: "mcp-test", messageId: "search", query: "Q",
                limit: 9, cursor: "o18"),
            .placesGet(
                helperId: "mcp-test", messageId: "get", placeId: "place-2"),
        ]
        let decodedRequests = try requests.map {
            try JSONDecoder().decode(WireRequest.self, from: JSONEncoder().encode($0))
        }
        guard case .guidesListForPlace(
            let containingHelper, let containingMessage, let containingPlace,
            let containingLimit, let containingCursor) = decodedRequests[0],
              case .placesSearch(
                let searchHelper, let searchMessage, let query,
                let searchLimit, let searchCursor) = decodedRequests[1],
              case .placesGet(let getHelper, let getMessage, let getPlace) = decodedRequests[2]
        else {
            return XCTFail("wrong place-read request case decoded")
        }
        XCTAssertEqual(containingHelper, "mcp-test")
        XCTAssertEqual(containingMessage, "containing")
        XCTAssertEqual(containingPlace, "place-1")
        XCTAssertEqual(containingLimit, 17)
        XCTAssertEqual(containingCursor, "o34")
        XCTAssertEqual(searchHelper, "mcp-test")
        XCTAssertEqual(searchMessage, "search")
        XCTAssertEqual(query, "Q")
        XCTAssertEqual(searchLimit, 9)
        XCTAssertEqual(searchCursor, "o18")
        XCTAssertEqual(getHelper, "mcp-test")
        XCTAssertEqual(getMessage, "get")
        XCTAssertEqual(getPlace, "place-2")

        let place = WirePlace(
            id: "place-2", guideId: "guide-1", name: "Q", address: "1 Main St",
            latitude: 41.1, longitude: -87.2, sortOrder: 3,
            createdAt: "2026-01-01T00:00:00Z", lastViewedAt: "2026-01-02T00:00:00Z",
            resolvedAt: "2026-01-03T00:00:00Z", needsResolution: false,
            isFavorite: true)
        let response = WireResponse.place(
            helperId: "mcp-test", messageId: "get", place: place)
        let decoded = try JSONDecoder().decode(
            WireResponse.self, from: JSONEncoder().encode(response))
        guard case .place(let helperId, let messageId, let decodedPlace) = decoded else {
            return XCTFail("wrong place response case")
        }
        XCTAssertEqual(helperId, "mcp-test")
        XCTAssertEqual(messageId, "get")
        XCTAssertEqual(decodedPlace.id, place.id)
        XCTAssertEqual(decodedPlace.guideId, place.guideId)
        XCTAssertEqual(decodedPlace.name, place.name)
        XCTAssertEqual(decodedPlace.address, place.address)
        XCTAssertEqual(decodedPlace.latitude, place.latitude)
        XCTAssertEqual(decodedPlace.longitude, place.longitude)
        XCTAssertEqual(decodedPlace.sortOrder, place.sortOrder)
        XCTAssertEqual(decodedPlace.createdAt, place.createdAt)
        XCTAssertEqual(decodedPlace.lastViewedAt, place.lastViewedAt)
        XCTAssertEqual(decodedPlace.resolvedAt, place.resolvedAt)
        XCTAssertEqual(decodedPlace.needsResolution, place.needsResolution)
        XCTAssertEqual(decodedPlace.isFavorite, place.isFavorite)
    }

    func testOrganizationResponsesRoundTripIntact() throws {
        let departments = WireResponse.departmentPage(
            helperId: "mcp-test", messageId: "departments",
            page: WirePage(items: ["Design", "Engineering"], nextCursor: "o2"))
        let decodedDepartments = try JSONDecoder().decode(
            WireResponse.self, from: JSONEncoder().encode(departments))
        guard case .departmentPage(_, _, let page) = decodedDepartments else {
            return XCTFail("wrong department response case")
        }
        XCTAssertEqual(page.items, ["Design", "Engineering"])
        XCTAssertEqual(page.nextCursor, "o2")

        let renamed = WireResponse.departmentRename(
            helperId: "mcp-test", messageId: "rename",
            result: WireDepartmentRenameResult(affectedCount: 7))
        let decodedRename = try JSONDecoder().decode(
            WireResponse.self, from: JSONEncoder().encode(renamed))
        guard case .departmentRename(_, _, let result) = decodedRename else {
            return XCTFail("wrong rename response case")
        }
        XCTAssertEqual(result.affectedCount, 7)
        XCTAssertTrue(renamed.asCallToolResult().content.contains { content in
            if case .text(let text, _, _) = content { return text.contains("\"affectedCount\" : 7") }
            return false
        })
    }

    func testFavoritePageRoundTripsCompositeKindAndAvailability() throws {
        let page = WirePage(items: [WireFavorite(
            kind: .group, id: "g-opaque", displayName: "Unavailable",
            addedAt: "2026-08-12T00:00:00Z", isAvailable: false)], nextCursor: nil)
        let encoded = try JSONEncoder().encode(WireResponse.favoritePage(
            helperId: "h", messageId: "m", page: page))
        let decoded = try JSONDecoder().decode(WireResponse.self, from: encoded)
        guard case .favoritePage(_, _, let decodedPage) = decoded else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(decodedPage.items.first?.kind, .group)
        XCTAssertEqual(decodedPage.items.first?.id, "g-opaque")
        XCTAssertEqual(decodedPage.items.first?.isAvailable, false)
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

    func testContactPhotoRequestsParseAndRoundTrip() throws {
        let encoded = Data([0xff, 0xd8, 0xff]).base64EncodedString()
        let set = try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.contactsSetPhoto.rawValue, [
                "contactId": "c-1", "mediaType": "image/jpeg",
                "dataBase64": .string(encoded), "idempotencyToken": "once",
            ]))
        guard case .contactsSetPhoto(_, _, let id, let type, let data, let token) = set else {
            return XCTFail("wrong set-photo case")
        }
        XCTAssertEqual(id, "c-1")
        XCTAssertEqual(type, "image/jpeg")
        XCTAssertEqual(data, encoded)
        XCTAssertEqual(token, "once")

        let roundTripped = try JSONDecoder().decode(
            WireRequest.self, from: JSONEncoder().encode(set))
        guard case .contactsSetPhoto = roundTripped else {
            return XCTFail("set-photo request did not round-trip")
        }

        let get = try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.contactsGetPhoto.rawValue, ["contactId": "c-1"]))
        guard case .contactsGetPhoto = get else { return XCTFail("wrong get-photo case") }

        let delete = try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.contactsDeletePhoto.rawValue, ["contactId": "c-1"]))
        guard case .contactsDeletePhoto = delete else { return XCTFail("wrong delete-photo case") }
    }

    func testContactsUpdateParsesOptionalKind() throws {
        let request = try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.contactsUpdate.rawValue, [
                "contactId": "c-1", "kind": "organization",
            ]))
        guard case .contactsUpdate(_, _, _, let fields, _) = request else {
            return XCTFail("wrong update case")
        }
        XCTAssertEqual(fields.kind, "organization")
        XCTAssertEqual(fields.providedFieldNames, ["kind"])
    }

    func testPlaceReadRequestsParse() throws {
        let search = try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.placesSearch.rawValue, [
                "query": "museum", "limit": 7, "cursor": "o7",
            ]))
        guard case .placesSearch(_, _, let query, let limit, let cursor) = search else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(query, "museum")
        XCTAssertEqual(limit, 7)
        XCTAssertEqual(cursor, "o7")

        let get = try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.placesGet.rawValue, ["placeId": "p1"]))
        guard case .placesGet(_, _, let placeId) = get else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(placeId, "p1")

        let containing = try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.guidesListForPlace.rawValue, ["placeId": "p1"]))
        guard case .guidesListForPlace(_, _, let containingPlaceId, _, _) = containing else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(containingPlaceId, "p1")
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

    func testOrganizationReadRequestsParse() throws {
        let members = try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.organizationsListDepartmentMembers.rawValue, [
                "organizationId": "org-1", "department": "Engineering",
                "limit": 25, "cursor": "o25",
            ]))
        guard case .organizationsListDepartmentMembers(
            _, _, let organizationID, let department, let limit, let cursor
        ) = members else { return XCTFail("wrong case") }
        XCTAssertEqual(organizationID, "org-1")
        XCTAssertEqual(department, "Engineering")
        XCTAssertEqual(limit, 25)
        XCTAssertEqual(cursor, "o25")

        XCTAssertThrowsError(try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.organizationsListMembers.rawValue)))
    }

    func testOrganizationRenameRequestParsesIdempotencyToken() throws {
        let request = try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.organizationsRenameDepartment.rawValue, [
                "organizationId": "org-1", "oldName": "Engineering",
                "newName": "Product", "idempotencyToken": "rename-1",
            ]))
        guard case .organizationsRenameDepartment(
            _, _, let organizationID, let oldName, let newName, let token
        ) = request else { return XCTFail("wrong case") }
        XCTAssertEqual(organizationID, "org-1")
        XCTAssertEqual(oldName, "Engineering")
        XCTAssertEqual(newName, "Product")
        XCTAssertEqual(token, "rename-1")
        XCTAssertEqual(request.tool, .organizationsRenameDepartment)
        XCTAssertEqual(request.idempotencyToken, "rename-1")
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
        // The 56-tool generic-favorites baseline plus one group read and
        // six group writes.
        XCTAssertEqual(MCPTool.allCases.count, 63)
        XCTAssertEqual(MCPTool.allCases.filter { !$0.isWrite }.count, 22)
        XCTAssertEqual(MCPTool.allCases.filter { $0.isWrite }.count, 41)
    }

    func testGenericFavoriteRequestsParseCompositeIdentities() throws {
        let set = try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.favoritesSet.rawValue, [
                "kind": "group", "id": "g-opaque", "favorite": true,
                "idempotencyToken": "set-1",
            ]))
        guard case .favoritesSet(_, _, let kind, let id, let favorite, let token) = set else {
            return XCTFail("wrong favorites_set case")
        }
        XCTAssertEqual(kind, .group)
        XCTAssertEqual(id, "g-opaque")
        XCTAssertTrue(favorite)
        XCTAssertEqual(token, "set-1")

        let reorder = try WireRequest.create(
            helperId: "h", messageId: "m2",
            parameters: params(MCPTool.favoritesReorder.rawValue, [
                "favorites": .array([
                    .object(["kind": "contact", "id": "contact-id"]),
                    .object(["kind": "guide", "id": "guide-id"]),
                ]),
            ]))
        guard case .favoritesReorder(_, _, let identities, _) = reorder else {
            return XCTFail("wrong favorites_reorder case")
        }
        XCTAssertEqual(identities.count, 2)
        XCTAssertEqual(identities.map(\.kind), [.contact, .guide])
    }

    func testInvalidFavoriteKindIsRejectedWithFixedMessage() {
        XCTAssertThrowsError(try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.favoritesSet.rawValue, [
                "kind": "organization", "id": "x", "favorite": true,
            ]))) { error in
            XCTAssertEqual(String(describing: error), WireErrorMessage.invalidFavoriteKindArgument)
        }
    func testGroupRequestsParseAllArguments() throws {
        let members = try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.groupsAddMembers.rawValue, [
                "groupId": "g-opaque",
                "contactIds": ["c-one", "c-two"],
                "idempotencyToken": "once",
            ]))
        guard case .groupsAddMembers(
            _, _, let groupId, let contactIds, let token
        ) = members else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(groupId, "g-opaque")
        XCTAssertEqual(contactIds, ["c-one", "c-two"])
        XCTAssertEqual(token, "once")

        let favorite = try WireRequest.create(
            helperId: "h", messageId: "m2",
            parameters: params(MCPTool.groupsSetFavorite.rawValue, [
                "groupId": "g-opaque", "favorite": "true",
            ]))
        guard case .groupsSetFavorite(_, _, let favoriteGroup, let state, _) = favorite else {
            return XCTFail("wrong favorite case")
        }
        XCTAssertEqual(favoriteGroup, "g-opaque")
        XCTAssertTrue(state)
    }

    func testGroupRequestRejectsWrongContactIdsType() {
        XCTAssertThrowsError(try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.groupsRemoveMembers.rawValue, [
                "groupId": "g-opaque", "contactIds": "c-one",
            ])))
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

    /// Structured lists keep their separate hard rejection. Their dedicated
    /// tools accept one object, never an array replacement.
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

    // MARK: - Structured single-entry tool parsing

    private var postalObject: Value {
        .object([
            "label": "home", "street": "1 Main St", "subLocality": "Downtown",
            "city": "Austin", "subAdministrativeArea": "Travis", "state": "TX",
            "postalCode": "78701", "country": "United States", "isoCountryCode": "US",
        ])
    }

    private var socialObject: Value {
        .object([
            "label": "work", "service": "LinkedIn", "username": "jane-doe",
            "url": "https://www.linkedin.com/in/jane-doe",
        ])
    }

    private var instantObject: Value {
        .object(["label": "mobile", "service": "Signal", "username": "+15550100"])
    }

    func testStructuredAddRequestsParseEveryPayloadField() throws {
        let postal = try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.contactsAddPostalAddress.rawValue, [
                "contactId": "contact", "address": postalObject,
            ]))
        guard case .contactsAddPostalAddress(_, _, _, let address, _) = postal else {
            return XCTFail("wrong postal case")
        }
        XCTAssertEqual(address, WirePostalAddress(
            label: "home", street: "1 Main St", subLocality: "Downtown",
            city: "Austin", subAdministrativeArea: "Travis", state: "TX",
            postalCode: "78701", country: "United States", isoCountryCode: "US"))

        let social = try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.contactsAddSocialProfile.rawValue, [
                "contactId": "contact", "profile": socialObject,
            ]))
        guard case .contactsAddSocialProfile(_, _, _, let profile, _) = social else {
            return XCTFail("wrong social case")
        }
        XCTAssertEqual(profile, WireSocialProfile(
            label: "work", service: "LinkedIn", username: "jane-doe",
            url: "https://www.linkedin.com/in/jane-doe"))

        let instant = try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.contactsAddInstantMessage.rawValue, [
                "contactId": "contact", "instantMessage": instantObject,
            ]))
        guard case .contactsAddInstantMessage(_, _, _, let address, _) = instant else {
            return XCTFail("wrong instant-message case")
        }
        XCTAssertEqual(address, WireInstantMessage(
            label: "mobile", service: "Signal", username: "+15550100"))
    }

    func testStructuredEditAndDeleteRequestsParseTypedObjects() throws {
        let postalEdit = try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.contactsEditPostalAddress.rawValue, [
                "contactId": "contact", "currentAddress": postalObject,
                "newAddress": postalObject,
            ]))
        guard case .contactsEditPostalAddress(_, _, _, let current, let replacement, _) = postalEdit else {
            return XCTFail("wrong postal edit case")
        }
        XCTAssertEqual(current, replacement)

        let socialDelete = try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.contactsDeleteSocialProfile.rawValue, [
                "contactId": "contact", "profile": socialObject,
            ]))
        guard case .contactsDeleteSocialProfile(_, _, _, let profile, _) = socialDelete else {
            return XCTFail("wrong social delete case")
        }
        XCTAssertEqual(profile.username, "jane-doe")

        let instantEdit = try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.contactsEditInstantMessage.rawValue, [
                "contactId": "contact", "currentInstantMessage": instantObject,
                "newInstantMessage": instantObject,
            ]))
        guard case .contactsEditInstantMessage(_, _, _, let currentIM, let newIM, _) = instantEdit else {
            return XCTFail("wrong instant-message edit case")
        }
        XCTAssertEqual(currentIM, newIM)
    }

    func testMalformedStructuredPayloadsAreRejected() {
        XCTAssertThrowsError(try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.contactsAddPostalAddress.rawValue, [
                "contactId": "contact", "address": "not-an-object",
            ])))
        XCTAssertThrowsError(try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.contactsAddPostalAddress.rawValue, [
                "contactId": "contact",
                "address": .object([
                    "street": "1 Main", "city": "Austin", "state": "TX",
                    "postalCode": 78701, "country": "US",
                ]),
            ])))
        XCTAssertThrowsError(try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.contactsAddSocialProfile.rawValue, [
                "contactId": "contact", "profile": .object(["label": "only"]),
            ])))
        XCTAssertThrowsError(try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.contactsAddInstantMessage.rawValue, [
                "contactId": "contact",
                "instantMessage": .object(["service": "Signal"]),
            ])))
        XCTAssertThrowsError(try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.contactsAddSocialProfile.rawValue, [
                "contactId": "contact",
                "profile": .object([
                    "service": "LinkedIn", "usernmae": "misspelled",
                ]),
            ])))
        XCTAssertThrowsError(try WireRequest.create(
            helperId: "h", messageId: "m",
            parameters: params(MCPTool.contactsEditSocialProfile.rawValue, [
                "contactId": "contact", "currentProfile": socialObject,
            ])))
    }

    func testStructuredToolSchemasContainObjectsAndNeverArrays() {
        let tools: [MCPTool] = [
            .contactsAddPostalAddress, .contactsEditPostalAddress,
            .contactsDeletePostalAddress, .contactsAddSocialProfile,
            .contactsEditSocialProfile, .contactsDeleteSocialProfile,
            .contactsAddInstantMessage, .contactsEditInstantMessage,
            .contactsDeleteInstantMessage,
        ]
        for tool in tools {
            guard case .object(let schema) = tool.metadata.inputSchema,
                  case .object(let properties) = schema["properties"]
            else { return XCTFail("missing schema for \(tool.rawValue)") }
            XCTAssertFalse(properties.values.contains { value in
                guard case .object(let property) = value else { return false }
                return property["type"]?.stringValue == "array"
            })
            XCTAssertTrue(properties.values.contains { value in
                guard case .object(let property) = value else { return false }
                return property["type"]?.stringValue == "object"
                    && property["additionalProperties"]?.boolValue == false
            })
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

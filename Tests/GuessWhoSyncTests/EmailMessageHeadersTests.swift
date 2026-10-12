import Foundation
import Testing
@testable import GuessWhoSync

@Suite("EmailMessageHeaders")
struct EmailMessageHeadersTests {

    // MARK: - Helpers

    /// An .eml built from header lines, a blank line, and a body.
    private func message(_ headers: [String], body: String = "Body text.", lineEnding: String = "\r\n") -> Data {
        Data((headers.joined(separator: lineEnding) + lineEnding + lineEnding + body + lineEnding).utf8)
    }

    private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        ))!
    }

    private func subject(_ value: String) -> String? {
        EmailMessageHeaders.parse(message(["Subject: \(value)"])).subject
    }

    private func from(_ value: String) -> (name: String?, address: String?) {
        let headers = EmailMessageHeaders.parse(message(["From: \(value)"]))
        return (headers.fromName, headers.fromAddress)
    }

    private func date(_ value: String) -> Date? {
        EmailMessageHeaders.parse(message(["Date: \(value)"])).date
    }

    // MARK: - Real-world header blocks

    @Test func gmailMessage() {
        let data = message([
            "Delivered-To: adam@example.com",
            "Received: by 2002:a05:7300:5b0e:b0:17c:1f4a with SMTP id k14csp1234567dyb;",
            "        Tue, 7 Oct 2025 08:14:02 -0700 (PDT)",
            "DKIM-Signature: v=1; a=rsa-sha256; c=relaxed/relaxed; d=gmail.com; s=20230601;",
            "        h=to:subject:message-id:date:from:in-reply-to:references:mime-version;",
            "        bh=47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=;",
            "MIME-Version: 1.0",
            "References: <CAJx1h3Kq0EXAMPLEPRIOR@mail.gmail.com>",
            "In-Reply-To: <CAJx1h3Kq0EXAMPLEPRIOR@mail.gmail.com>",
            "From: Jane Example <jane.example@gmail.com>",
            "Date: Tue, 7 Oct 2025 10:13:48 -0500",
            "Message-ID: <CALcTHdVwnoMkEXAMPLE+xQ2=v8Jt@mail.gmail.com>",
            "Subject: Re: Lunch next week?",
            "To: Adam <adam@example.com>",
            "Content-Type: multipart/alternative; boundary=\"000000000000a1b2c3d4e5f6\"",
        ], body: "--000000000000a1b2c3d4e5f6\r\nContent-Type: text/plain\r\n\r\nSure!")

        let headers = EmailMessageHeaders.parse(data)

        #expect(headers == EmailMessageHeaders(
            messageID: "<CALcTHdVwnoMkEXAMPLE+xQ2=v8Jt@mail.gmail.com>",
            subject: "Re: Lunch next week?",
            fromName: "Jane Example",
            fromAddress: "jane.example@gmail.com",
            date: utc(2025, 10, 7, 15, 13, 48)
        ))
    }

    @Test func outlookMessageWithBase64Words() {
        let data = message([
            "From: =?utf-8?B?SsO2cmcgTcO8bGxlcg==?= <joerg.mueller@contoso.com>",
            "To: Adam <adam@example.com>",
            "Subject: =?utf-8?B?UXVhcnRlcmx5IHJldmlldyDigJMgYWdlbmRh?=",
            "Thread-Topic: =?utf-8?B?UXVhcnRlcmx5IHJldmlldyDigJMgYWdlbmRh?=",
            "Thread-Index: AQHcN1aTnHbmk8KxQkGq0kMOsSRmWg==",
            "Date: Wed, 8 Oct 2025 14:02:11 +0000",
            "Message-ID: <AM0PR02MB1234ABCD5678EF90@AM0PR02MB1234.eurprd02.prod.outlook.com>",
            "Accept-Language: en-US",
            "Content-Language: en-US",
            "Content-Type: text/plain; charset=\"utf-8\"",
            "Content-Transfer-Encoding: base64",
            "MIME-Version: 1.0",
        ])

        let headers = EmailMessageHeaders.parse(data)

        #expect(headers == EmailMessageHeaders(
            messageID: "<AM0PR02MB1234ABCD5678EF90@AM0PR02MB1234.eurprd02.prod.outlook.com>",
            subject: "Quarterly review – agenda",
            fromName: "Jörg Müller",
            fromAddress: "joerg.mueller@contoso.com",
            date: utc(2025, 10, 8, 14, 2, 11)
        ))
    }

    @Test func appleMailMessage() {
        let data = message([
            "From: Adam Wulf <adam@example.com>",
            "Content-Type: text/plain;",
            "\tcharset=us-ascii",
            "Content-Transfer-Encoding: 7bit",
            "Mime-Version: 1.0 (Mac OS X Mail 16.0 \\(3826.400.131.1.6\\))",
            "Subject: Photos from the trip",
            "Message-Id: <8F2C1D3E-4B5A-4C6D-9E8F-0A1B2C3D4E5F@example.com>",
            "Date: Thu, 9 Oct 2025 09:41:27 -0500",
            "To: Jane Example <jane@example.com>",
            "X-Mailer: Apple Mail (2.3826.400.131.1.6)",
        ])

        let headers = EmailMessageHeaders.parse(data)

        #expect(headers == EmailMessageHeaders(
            messageID: "<8F2C1D3E-4B5A-4C6D-9E8F-0A1B2C3D4E5F@example.com>",
            subject: "Photos from the trip",
            fromName: "Adam Wulf",
            fromAddress: "adam@example.com",
            date: utc(2025, 10, 9, 14, 41, 27)
        ))
    }

    @Test func lfOnlyLineEndings() {
        let data = message([
            "From: Jane Example <jane@example.com>",
            "Subject: Plain newlines",
            " continue here",
            "Message-ID: <lf-only@example.com>",
            "Date: Fri, 10 Oct 2025 08:00:00 +0200",
        ], body: "Subject: not this one", lineEnding: "\n")

        let headers = EmailMessageHeaders.parse(data)

        #expect(headers == EmailMessageHeaders(
            messageID: "<lf-only@example.com>",
            subject: "Plain newlines continue here",
            fromName: "Jane Example",
            fromAddress: "jane@example.com",
            date: utc(2025, 10, 10, 6, 0)
        ))
    }

    // MARK: - Header block

    @Test func bodyIsNeverRead() {
        let data = message(
            ["From: jane@example.com", "Message-ID: <body@example.com>"],
            body: "Subject: this line is body text\r\nDate: Tue, 7 Oct 2025 10:13:48 -0500"
        )

        let headers = EmailMessageHeaders.parse(data)

        #expect(headers.messageID == "<body@example.com>")
        #expect(headers.subject == nil)
        #expect(headers.date == nil)
    }

    @Test func noHeadersAtAll() {
        #expect(EmailMessageHeaders.parse(Data()) == EmailMessageHeaders())
        #expect(EmailMessageHeaders.parse(Data("\r\nSubject: after the blank line\r\n".utf8)) == EmailMessageHeaders())
        // A plain-text first line is the start of a body, so nothing after it is a header.
        #expect(EmailMessageHeaders.parse(Data("Just a note, no headers.\nSubject: nope\n".utf8)) == EmailMessageHeaders())
        let garbage = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 7919 &+ 13) })
        #expect(EmailMessageHeaders.parse(garbage) == EmailMessageHeaders())
    }

    @Test func headerNamesAreCaseInsensitiveAndFirstOccurrenceWins() {
        let headers = EmailMessageHeaders.parse(message([
            "SUBJECT: First",
            "subject: Second",
            "message-id: <first@example.com>",
            "Message-ID: <second@example.com>",
        ]))

        #expect(headers.subject == "First")
        #expect(headers.messageID == "<first@example.com>")
    }

    @Test func foldedMessageIDIsUnfoldedAndTrimmed() {
        let headers = EmailMessageHeaders.parse(message(["Message-ID:", " <folded@example.com>  "]))

        #expect(headers.messageID == "<folded@example.com>")
    }

    @Test func messageIDKeepsOnlyTheFirstAngleToken() {
        func messageID(_ value: String) -> String? {
            EmailMessageHeaders.parse(message(["Message-ID: \(value)"])).messageID
        }

        #expect(messageID("<id@example.com> (sent by a gateway)") == "<id@example.com>")
        #expect(messageID("(comment) <id@example.com>") == "<id@example.com>")
        #expect(messageID("<id@example.com> <other@example.com>") == "<id@example.com>")
        #expect(messageID("bare-id@example.com") == "bare-id@example.com")
        #expect(messageID("<unclosed@example.com") == nil)
        #expect(messageID("<>") == nil)
        #expect(messageID("two words") == nil)
    }

    @Test func emptyValuesAreNil() {
        let headers = EmailMessageHeaders.parse(message(["Subject:   ", "Message-ID:", "From: ", "Date: "]))

        #expect(headers == EmailMessageHeaders())
    }

    @Test func leadingMboxEnvelopeLineIsSkipped() {
        let headers = EmailMessageHeaders.parse(message([
            "From jane@example.com Tue Oct  7 10:13:48 2025",
            "Subject: From an mbox",
        ]))

        #expect(headers.subject == "From an mbox")
    }

    @Test func headersBeyondTheScanBoundAreNotRead() {
        let filler = String(repeating: "a", count: EmailMessageHeaders.maximumHeaderBytes)
        let headers = EmailMessageHeaders.parse(message(["Message-ID: <early@example.com>", "X-Filler: \(filler)", "Subject: Too late"]))

        #expect(headers.messageID == "<early@example.com>")
        #expect(headers.subject == nil)
    }

    @Test func sliceOfLargerDataParses() {
        // A slice keeps its parent's indices; the scan must not assume zero.
        let whole = Data("ignored prefix\r\n".utf8) + message(["Subject: From a slice", "Message-ID: <slice@example.com>"])
        let slice = whole[whole.index(whole.startIndex, offsetBy: 16)...]

        let headers = EmailMessageHeaders.parse(slice)

        #expect(headers.subject == "From a slice")
        #expect(headers.messageID == "<slice@example.com>")
    }

    @Test func rawUTF8HeaderBytesDecode() {
        // RFC 6532 allows UTF-8 directly in header values.
        #expect(subject("Café 日本") == "Café 日本")
    }

    @Test func rawLatin1HeaderBytesFallBack() {
        // "Café crème" in ISO Latin 1: 0xE9 and 0xE8 alone are not valid UTF-8.
        var bytes = Array("Message-ID: <latin1@example.com>\r\nSubject: Caf".utf8)
        bytes.append(0xE9)
        bytes += Array(" cr".utf8)
        bytes.append(0xE8)
        bytes += Array("me\r\n\r\nBody".utf8)

        let headers = EmailMessageHeaders.parse(Data(bytes))

        #expect(headers.subject == "Café crème")
        #expect(headers.messageID == "<latin1@example.com>")
    }

    // MARK: - message: URLs

    private func urlMessageID(_ string: String) throws -> String? {
        EmailMessageHeaders.messageID(fromMessageURL: try #require(URL(string: string)))
    }

    @Test func messageURLGivesTheMessageID() throws {
        #expect(try urlMessageID("message:%3Cid@x%3E") == "<id@x>")
        #expect(try urlMessageID("message://%3Cid@x%3E") == "<id@x>")
        #expect(try urlMessageID("MESSAGE:%3Cid@x%3E") == "<id@x>")
        #expect(try urlMessageID("message:%3CCALcTHdVwnoMk%2BxQ2%3Dv8Jt@mail.gmail.com%3E")
            == "<CALcTHdVwnoMk+xQ2=v8Jt@mail.gmail.com>")
    }

    @Test func otherURLsGiveNoMessageID() throws {
        #expect(try urlMessageID("https://example.com") == nil)
        #expect(try urlMessageID("message:") == nil)
        #expect(try urlMessageID("message://") == nil)
        #expect(try urlMessageID("message:%3C%3E") == nil)
    }

    @Test func urlAndEmlGiveOneIdentityForOneMessage() throws {
        let fromEml = try #require(EmailMessageHeaders.parse(message([
            "Message-ID: <CALcTHdVwnoMkEXAMPLE+xQ2=v8Jt@Mail.Gmail.com> (via gateway)",
        ])).messageID)
        let fromURL = try #require(try urlMessageID("message:%3CCALcTHdVwnoMkEXAMPLE%2BxQ2%3Dv8Jt@Mail.Gmail.com%3E"))

        #expect(fromEml == fromURL)
        let normalized = try #require(MailActivity.normalizedMessageID(fromEml))
        #expect(MailActivity.normalizedMessageID(fromURL) == normalized)
        #expect(MailActivity.activityID(forMessageID: fromEml) == MailActivity.activityID(forMessageID: fromURL))
    }

    // MARK: - RFC 2047 subjects

    @Test func foldedPlainSubject() {
        let headers = EmailMessageHeaders.parse(message([
            "Subject: A very long subject line that the sending client decided to fold",
            " onto a second line",
        ]))

        #expect(headers.subject == "A very long subject line that the sending client decided to fold onto a second line")
    }

    @Test func tabFoldedSubjectReadsAsOneSpace() {
        let headers = EmailMessageHeaders.parse(message(["Subject: This subject was", "\tfolded  with\t a tab"]))

        #expect(headers.subject == "This subject was folded with a tab")
    }

    @Test func foldedEncodedSubjectDropsWhitespaceBetweenWords() {
        // Outlook folds long encoded subjects with CRLF + TAB between words.
        let headers = EmailMessageHeaders.parse(message([
            "Subject: =?utf-8?B?UsOpdW5pb24g?=",
            "\t=?utf-8?B?ZOKAmcOpcXVpcGU=?=",
        ]))

        #expect(headers.subject == "Réunion d’équipe")
    }

    @Test func adjacentEncodedWords() {
        #expect(subject("=?UTF-8?Q?Hello?= =?UTF-8?Q?_World?=") == "Hello World")
        #expect(subject("=?UTF-8?Q?Hello?=   =?UTF-8?Q?World?=") == "HelloWorld")
        // Whitespace next to plain text is kept.
        #expect(subject("Re: =?UTF-8?Q?caf=C3=A9?= time") == "Re: café time")
        // Different charsets still drop the whitespace between them.
        #expect(subject("=?ISO-8859-1?Q?caf=E9?= =?UTF-8?B?5pel5pys6Kqe44Gu5Lu25ZCN?=") == "café日本語の件名")
    }

    @Test func longEncodedWordRunDecodesInLinearTime() {
        // Called directly, past parse()'s 256 KiB bound: at that size even a
        // quadratic decoder finishes in about 0.1 s, so only a larger run
        // separates linear (about 0.6 s in debug) from quadratic (about 20 s).
        let word = "=?UTF-8?Q?a?= "
        let count = 4 * 1024 * 1024 / word.utf8.count
        let start = ContinuousClock.now

        let decoded = EmailMessageHeaders.decodeEncodedWords(String(repeating: word, count: count))

        let elapsed = ContinuousClock.now - start
        // The trailing space follows the last word, so it is kept.
        #expect(decoded == String(repeating: "a", count: count) + " ")
        #expect(elapsed < .seconds(5), "took \(elapsed)")
    }

    @Test func characterSplitAcrossTwoWordsStillDecodes() {
        #expect(subject("=?UTF-8?Q?caf=C3?= =?UTF-8?Q?=A9?=") == "café")
    }

    @Test func iso88591Charset() {
        #expect(subject("=?ISO-8859-1?Q?Caf=E9_cr=E8me?=") == "Café crème")
        #expect(subject("=?iso-8859-1?q?R=E9sum=E9?=") == "Résumé")
    }

    @Test func base64WithoutPaddingDecodes() {
        #expect(subject("=?utf-8?B?SsO2cmcgTcO8bGxlcg?=") == "Jörg Müller")
    }

    @Test func charsetLanguageSuffixIsIgnored() {
        #expect(subject("=?UTF-8*en?Q?Hello?=") == "Hello")
    }

    @Test func undecodableWordsStayRaw() {
        #expect(subject("=?x-unknown-charset?Q?abc?=") == "=?x-unknown-charset?Q?abc?=")
        #expect(subject("Bad =?UTF-8?Q?=ZZ?= escape") == "Bad =?UTF-8?Q?=ZZ?= escape")
        #expect(subject("=?UTF-8?B?!!!!?=") == "=?UTF-8?B?!!!!?=")
        #expect(subject("=?UTF-8?Q?=FF?=") == "=?UTF-8?Q?=FF?=")
        // Not encoded-word syntax at all.
        #expect(subject("What =? is this ?= thing") == "What =? is this ?= thing")
        #expect(subject("=?UTF-8?X?abc?=") == "=?UTF-8?X?abc?=")
    }

    // MARK: - From

    @Test func nameAndAngleAddress() {
        let mailbox = from("Jane Example <jane@example.com>")
        #expect(mailbox.name == "Jane Example")
        #expect(mailbox.address == "jane@example.com")
    }

    @Test func quotedDisplayNameWithComma() {
        let mailbox = from("\"Doe, Jane\" <jane.doe@example.com>")
        #expect(mailbox.name == "Doe, Jane")
        #expect(mailbox.address == "jane.doe@example.com")

        let escaped = from("\"Jane \\\"JD\\\" Doe\" <jd@example.com>")
        #expect(escaped.name == "Jane \"JD\" Doe")
        #expect(escaped.address == "jd@example.com")
    }

    @Test func unquotedCommaStaysInTheDisplayName() {
        let plain = from("Doe, Jane <jane@example.com>")
        #expect(plain.name == "Doe, Jane")
        #expect(plain.address == "jane@example.com")

        let encoded = from("=?UTF-8?Q?Doe,_Jane?= <jane@example.com>")
        #expect(encoded.name == "Doe, Jane")
        #expect(encoded.address == "jane@example.com")
    }

    @Test func addressBeforeACommaEndsTheEntry() {
        let list = from("jane@example.com, bob@example.com")
        #expect(list.name == nil)
        #expect(list.address == "jane@example.com")

        let legacy = from("jane@example.com (Jane Example), bob@example.com (Bob)")
        #expect(legacy.name == "Jane Example")
        #expect(legacy.address == "jane@example.com")
    }

    @Test(arguments: [" ,", "a,"])
    func longCommaRunParsesInLinearTime(unit: String) {
        // Each repeat is 2 bytes; the whole header stays inside the scan bound.
        let value = String(repeating: unit, count: (EmailMessageHeaders.maximumHeaderBytes - 64) / 2)
        let start = ContinuousClock.now

        let headers = EmailMessageHeaders.parse(message(["From: \(value)"]))

        let elapsed = ContinuousClock.now - start
        #expect(headers.fromName == nil)
        #expect(headers.fromAddress == nil)
        // Linear parsing takes well under a second even in a debug build; a
        // rescan of the entry at each comma took tens of seconds in release.
        #expect(elapsed < .seconds(5), "took \(elapsed)")
    }

    @Test func phraseWithoutAnAddressIsNotAnAddress() {
        let mailbox = from("Jane Example")
        #expect(mailbox.name == nil)
        #expect(mailbox.address == nil)

        #expect(from("MAILER-DAEMON").address == nil)
        #expect(from("Jane <>").address == nil)
        #expect(from("Jane <jane @example.com>").address == nil)
        #expect(from("Jane <jane@@example.com>").address == nil)
    }

    @Test func quotedLocalPartAndSourceRouteAreKept() {
        #expect(from("\"jane doe\"@example.com").address == "\"jane doe\"@example.com")
        #expect(from("<@relay.example.net:jane@example.com>").address == "jane@example.com")
    }

    @Test func qEncodedNameWithUnderscore() {
        let mailbox = from("=?iso-8859-1?Q?Andr=E9_Fran=E7ois?= <andre@example.fr>")
        #expect(mailbox.name == "André François")
        #expect(mailbox.address == "andre@example.fr")
    }

    @Test func encodedWordInsideQuotesDecodes() {
        // Not RFC 2047-compliant, but common from real senders.
        let mailbox = from("\"=?utf-8?B?SsO2cmcgTcO8bGxlcg==?=\" <joerg@example.com>")
        #expect(mailbox.name == "Jörg Müller")
        #expect(mailbox.address == "joerg@example.com")
    }

    @Test func bareAddress() {
        let mailbox = from("jane@example.com")
        #expect(mailbox.name == nil)
        #expect(mailbox.address == "jane@example.com")
    }

    @Test func addressWithComment() {
        let mailbox = from("jane@example.com (Jane Example)")
        #expect(mailbox.name == "Jane Example")
        #expect(mailbox.address == "jane@example.com")
    }

    @Test func angleAddressOnly() {
        let mailbox = from("<jane@example.com>")
        #expect(mailbox.name == nil)
        #expect(mailbox.address == "jane@example.com")
    }

    @Test func listTakesTheFirstMailbox() {
        let mailbox = from("\"Doe, Jane\" <jane@example.com>, Bob <bob@example.com>")
        #expect(mailbox.name == "Doe, Jane")
        #expect(mailbox.address == "jane@example.com")
    }

    @Test func groupTakesItsFirstMember() {
        let mailbox = from("Project Team: Jane <jane@example.com>, bob@example.com;")
        #expect(mailbox.name == "Jane")
        #expect(mailbox.address == "jane@example.com")

        let afterEmptyGroup = from("undisclosed-recipients:;, bob@example.com")
        #expect(afterEmptyGroup.name == nil)
        #expect(afterEmptyGroup.address == "bob@example.com")
    }

    @Test func foldedFromHeader() {
        let headers = EmailMessageHeaders.parse(message(["From: \"Example, Jane\"", "\t<jane@example.com>"]))
        #expect(headers.fromName == "Example, Jane")
        #expect(headers.fromAddress == "jane@example.com")
    }

    // MARK: - Date

    @Test func dateWithWeekdayAndSeconds() {
        #expect(date("Tue, 7 Oct 2025 10:13:48 -0500") == utc(2025, 10, 7, 15, 13, 48))
    }

    @Test func dateWithoutWeekdayOrSeconds() {
        #expect(date("7 Oct 2025 10:13 -0500") == utc(2025, 10, 7, 15, 13))
        #expect(date("07 Oct 2025 10:13:48 +0130") == utc(2025, 10, 7, 8, 43, 48))
    }

    @Test(arguments: [
        ("UT", 0), ("GMT", 0),
        ("EST", -5), ("EDT", -4),
        ("CST", -6), ("CDT", -5),
        ("MST", -7), ("MDT", -6),
        ("PST", -8), ("PDT", -7),
    ])
    func dateWithObsoleteZone(zone: String, offsetHours: Int) {
        let expected = utc(2025, 10, 7, 10, 0).addingTimeInterval(TimeInterval(-offsetHours * 3_600))
        #expect(date("Tue, 7 Oct 2025 10:00:00 \(zone)") == expected)
    }

    @Test func dateWithTrailingComment() {
        #expect(date("Tue, 7 Oct 2025 10:13:48 -0500 (CDT)") == utc(2025, 10, 7, 15, 13, 48))
        #expect(date("Tue, 7 Oct 2025 10:13:48 +0000 (UTC)") == utc(2025, 10, 7, 10, 13, 48))
    }

    @Test func dateObsoleteSpellings() {
        // Two-digit year, weekday without its comma, lowercase month.
        #expect(date("Tue 7 oct 25 10:13:48 -0500") == utc(2025, 10, 7, 15, 13, 48))
        #expect(date("1 Jan 99 00:00:00 +0000") == utc(1999, 1, 1, 0, 0))
        // An unknown alphabetic zone means UTC (RFC 5322 §4.3).
        #expect(date("7 Oct 2025 10:13:48 Z") == utc(2025, 10, 7, 10, 13, 48))
    }

    @Test func unparseableDatesAreNil() {
        #expect(date("yesterday") == nil)
        #expect(date("Tue, 7 Oct 2025") == nil)
        #expect(date("Tue, 7 Oct 2025 10:13:48") == nil)
        #expect(date("Tue, 7 Foo 2025 10:13:48 -0500") == nil)
        #expect(date("Tue, 7 Oct 2025 25:13:48 -0500") == nil)
        #expect(date("Tue, 7 Oct 2025 10:13:48 +05") == nil)
        #expect(date("2025-10-07T10:13:48Z") == nil)
    }
}

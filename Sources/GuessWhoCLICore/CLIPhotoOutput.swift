import Foundation
import GuessWhoMCPWire

/// The `contacts get-photo` output side, as pure helpers so `swift test` can
/// exercise the integrity checks and the stdout-vs-file split with no live
/// app. The wire response carries base64; this decodes it, verifies it, and
/// writes the raw bytes. Moved from the retired inline logic in
/// `ContactsGetPhoto.run` (App/guesswho-cli/ContactsCommand.swift).
public enum CLIPhotoOutput {
    /// A get-photo payload that can't be turned into bytes to write.
    public enum Failure: Error, Equatable {
        /// The contact has no photo — a successful response, but bytes were
        /// requested, so it is an error for this command (§4).
        case notPresent
        /// The base64 was missing/undecodable, empty, or its length disagreed
        /// with the response's declared `byteCount`.
        case invalidData

        /// The plain stderr message for this failure.
        public var message: String {
            switch self {
            case .notPresent: return "That contact does not have a photo."
            case .invalidData: return "GuessWho returned invalid photo data."
            }
        }
    }

    /// Decode + integrity-check a photo response into raw bytes. Verifies the
    /// photo is present, the base64 decodes to non-empty data, and the decoded
    /// length equals the declared `byteCount`.
    public static func decode(_ photo: WireContactPhoto) throws -> Data {
        guard photo.present else { throw Failure.notPresent }
        guard let encoded = photo.dataBase64,
              let data = Data(base64Encoded: encoded),
              !data.isEmpty,
              data.count == photo.byteCount
        else {
            throw Failure.invalidData
        }
        return data
    }

    /// Write bytes to `path` (a file) or, when `path` is `nil` or `"-"`, to the
    /// sink's stdout. Throws `CLIUsageError` if the file can't be written (a
    /// bad output path is user input).
    public static func write(_ data: Data, toPath path: String?, sink: any CLIOutput) throws {
        if let path, path != "-" {
            let expandedPath = (path as NSString).expandingTildeInPath
            do {
                try data.write(to: URL(fileURLWithPath: expandedPath), options: .atomic)
            } catch {
                throw CLIUsageError(
                    "Could not write photo to \(expandedPath): \(error.localizedDescription)")
            }
        } else {
            sink.writeData(data)
        }
    }
}

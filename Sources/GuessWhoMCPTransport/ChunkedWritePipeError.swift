/// Errors specific to `ChunkedWritePipe` that the inherited `WritePipeError`
/// (declared in the pinned `EasyMacMCP` dependency, and therefore not
/// extensible here) does not cover.
public enum ChunkedWritePipeError: Error {
    /// `open()` was called on an instance that was already `close()`d. A
    /// `ChunkedWritePipe` is one-shot: every production caller builds a fresh
    /// pipe on reconnect, and rejecting reopen closes the close/reopen
    /// generation race (a stale parked writer could otherwise suspend a newly
    /// installed source and write old bytes into a new connection).
    case pipeClosed
}

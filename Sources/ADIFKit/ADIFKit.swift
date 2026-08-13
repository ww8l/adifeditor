/// ADIFKit — parsing and serialization for ADIF `.adi` log files.
///
/// This module is pure Swift. It must not import AppKit, and it must be usable from a
/// command-line test harness (DESIGN.md §7). Its I/O surface is `Data` in, `Data` out;
/// it does not touch the filesystem.
///
/// The governing invariant is that an unedited file written back out is byte-identical
/// to what came in. See CLAUDE.md §6.2a.
public enum ADIFKit {
    /// The ADIF specification version this implementation targets (DESIGN.md §8).
    public static let targetSpecVersion = "3.1.6"
}

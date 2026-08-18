import Foundation

/// Where the POTA outputs are allowed to land.
///
/// The operator edits the proposed filenames before anything is written (§10.2), so by
/// the time this runs the names are arbitrary typed text rather than anything
/// `POTAFilename` produced. Three of the ways that text can go wrong lose data *quietly*,
/// which is the reason this is a refusal rather than a best effort:
///
/// * A name matching the open document overwrites the log that came off the radio, which
///   is the one thing §6.1 forbids outright. The collision is not exotic — it is the
///   app's own naming convention colliding with itself when a log the app produced is
///   re-opened, corrected and stamped back into the same folder.
/// * Two names resolving to one file write both outputs to it in order. The second wins
///   and the Finder opens on one file where the sheet promised two, so for an activation
///   an upload silently never happens.
/// * An emptied name resolves to the folder itself.
///
/// It lives in POTAKit rather than beside the sheet that raises it because it is a rule
/// about what may be written, not about how to ask — the same reason `ADIFEditing` owns
/// what an edit means. Here that is sharper than usual: §6.1's enforcement point is
/// otherwise a comparison buried in a completion handler, where no test can reach it.
public enum POTATargets {

    /// Why a set of names was refused. The wording lives in the app layer; this says only
    /// what went wrong and which name it was.
    public enum Problem: Error, Equatable {
        /// A name that is empty once trimmed, given 1-based for the sheet's Nth row.
        case emptyName(line: Int)
        /// Two names that resolve to the same file.
        case duplicateName(String)
        /// The document the operator has open.
        case sourceFile(String)
    }

    /// Resolves the typed names against the chosen folder, or refuses the first problem
    /// found.
    ///
    /// `source` is the open document's URL, or `nil` for a log that has never been saved —
    /// which cannot be overwritten because there is nothing on disk to overwrite.
    public static func resolve(names: [String],
                               in folder: URL,
                               source: URL?) -> Result<[URL], Problem> {
        let sourceKey = source.map(identity(of:))
        var seen: Set<String> = []
        var targets: [URL] = []

        for (index, typed) in names.enumerated() {
            let name = POTAFilename.sanitized(
                typed.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !name.isEmpty else { return .failure(.emptyName(line: index + 1)) }

            let target = folder.appendingPathComponent(name)
            let key = identity(of: target)

            if key == sourceKey { return .failure(.sourceFile(name)) }
            guard seen.insert(key).inserted else { return .failure(.duplicateName(name)) }

            targets.append(target)
        }

        return .success(targets)
    }

    /// What "the same file" means on this platform, for two paths that need not exist.
    ///
    /// Not string equality: the folder may be reached through a symlink or a `..`, and a
    /// Mac's boot volume is case-insensitive and normalization-insensitive, so `LOG.adi`
    /// and a decomposed `é` name both open the file spelled the other way. Erring towards
    /// calling two paths the same is the safe direction — the cost is a message the
    /// operator can dismiss, and the cost of the other mistake is a log written over.
    private static func identity(of url: URL) -> String {
        url.resolvingSymlinksInPath()
            .standardizedFileURL
            .path
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }
}

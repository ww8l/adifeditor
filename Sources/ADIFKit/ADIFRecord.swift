import Foundation

/// A single QSO: an ordered list of fields, terminated in the file by `<EOR>`.
///
/// Ordered, not a dictionary. §9 calls a record "an ordered map of field name to string
/// value", and the order is per-record: `varying-field-order.adi` holds three records
/// that disagree about field order, and all three must come back out as they went in.
public struct ADIFRecord: Equatable, Sendable {
    public var fields: [ADIFField]

    /// How the file spelled the record terminator — `<EOR>`, `<eor>`, or `<Eor>`.
    public var terminatorSpelling: String

    /// Text after `<EOR>` and before the next record's first `<`. Usually a newline.
    public var trailingText: String

    /// True when the file ended before this record's `<EOR>`. Kept rather than
    /// discarded (decision 7); the writer supplies a terminator on the way out.
    public var isTruncated: Bool

    public init(
        fields: [ADIFField] = [],
        terminatorSpelling: String = "EOR",
        trailingText: String = "\n",
        isTruncated: Bool = false
    ) {
        self.fields = fields
        self.terminatorSpelling = terminatorSpelling
        self.trailingText = trailingText
        self.isTruncated = isTruncated
    }

    /// The value for a field name, case-insensitively. `nil` when the field is absent.
    ///
    /// Note the distinction §9 blurs and decision 2 restores: an absent field returns
    /// `nil`, while a present-but-empty `<COMMENT:0>` returns `""`. The grid renders
    /// both as an empty cell, but only one of them writes bytes.
    public subscript(name: String) -> String? {
        get {
            let key = ADIFField.normalize(name)
            return fields.first { $0.name == key }?.value
        }
        set {
            let key = ADIFField.normalize(name)
            if let index = fields.firstIndex(where: { $0.name == key }) {
                if let newValue {
                    fields[index].value = newValue
                } else {
                    fields.remove(at: index)
                }
            } else if let newValue {
                appendField(named: name, value: newValue)
            }
        }
    }

    /// True when the field is present, whatever its value.
    public func hasField(_ name: String) -> Bool {
        let key = ADIFField.normalize(name)
        return fields.contains { $0.name == key }
    }

    /// True when the field is absent or present with an empty value — that is, when the
    /// grid would show an empty cell. This is the test §6.3 means by "fills empty
    /// cells": the POTA stamp writes here and nowhere else.
    public func isEmpty(_ name: String) -> Bool {
        guard let value = self[name] else { return true }
        return value.isEmpty
    }

    /// Appends a field, matching the separator style the record already uses so an
    /// added field doesn't look foreign among the existing ones.
    ///
    /// A stamped FT8CN record has to read `... <my_gridsquare:4>DN70 <MY_SIG_INFO:7>US-1234 <eor>`,
    /// keeping the single space; without this, the new field would butt against `<eor>`.
    public mutating func appendField(named name: String, value: String) {
        insertField(named: name, value: value, at: fields.count)
    }

    /// Inserts a field at a given position, matching the record's separator style.
    ///
    /// Position matters beyond tidiness. A field put back at the end of a record is the
    /// last field of the first record that carries it, and the grid derives its column
    /// order from exactly that — so a value retyped into a cleared cell would send its
    /// whole column to the far right of the spreadsheet.
    public mutating func insertField(named name: String, value: String, at index: Int) {
        let position = min(max(index, 0), fields.count)

        // The separator that trails a field is the text before the *next* one, so the
        // style to copy belongs to the field this one is being placed after — or, when
        // it goes first, to the field it displaces.
        let separator = position > 0
            ? fields[position - 1].trailingText
            : fields.first?.trailingText ?? ""

        fields.insert(
            ADIFField(spelling: name, value: value, trailingText: separator),
            at: position
        )
    }
}

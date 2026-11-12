import Foundation

// Naming v2 (Android CallLabelPolicy.kt and NameTextRules.kt; PROTOCOL "Naming v2 / Label timing and audience" and its
// "Text rules"). No new bytes: BNL1, the LABELS container, end-to-end hello bit 5 and the receiver checks are unchanged.
// This file decides only WHEN a sender queues a label, which person names are reserved, and how a generated name is
// shown. Pure: no UI state, no storage.

/// "Who sees my name" (Android `NamesAudience`). It decides whether the kind 1 name is sent at all. The raw value is
/// Android's stored value.
public enum NamesAudience: String, CaseIterable {
    case everyone, verified, nobody

    /// Android `names_audience_everyone` / `_verified` / `_nobody`.
    public var title: String {
        switch self {
        case .everyone: return "People I call or who call me"
        case .verified: return "Only my contacts"
        case .nobody: return "Nobody"
        }
    }

    /// A stored value; nil or anything unknown is the default, as Android `NamesAudience.fromPref`.
    public static func stored(_ value: String?) -> NamesAudience { value.flatMap(NamesAudience.init(rawValue:)) ?? .everyone }
}

/// When one label is queued (Android `LabelSendMoment`).
public enum LabelSendMoment: Equatable {
    /// Never sent in this call.
    case never
    /// Immediately: before Invite (caller) or as soon as the session allows.
    case now
    /// After a relayed callee proved it owns the offer by its OPENING.
    case afterOpening
    /// After the callee's REVEAL is verified (the Design F rule).
    case afterReveal
    /// After the peer's REVEAL is verified AND it is a verified contact; otherwise never.
    case afterRevealIfVerified
    /// Callee: with Ringing (the caller is already known to be a verified contact).
    case atRinging
    /// Callee: with Accept.
    case atAccept
}

public struct CallerLabelPlan: Equatable {
    public let name: LabelSendMoment
    public init(name: LabelSendMoment) { self.name = name }
}

public struct CallerLabelContext {
    /// Both endpoint hellos carry bit 5.
    public var labelsNegotiated: Bool
    public var hasName: Bool
    public var audience: NamesAudience
    /// "Show my name before they answer".
    public var nameBeforeAnswer: Bool
    /// The callee presented a throwaway key and its reveal is still awaited.
    public var calleeAwaitsReveal: Bool
    /// A relayed callee that is proven only by its OPENING, which follows the Invite.
    public var relayedAwaitsOpening: Bool
    /// The callee's real key is known now and equals a verified contact's.
    public var calleeIsVerifiedContact: Bool
    public init(labelsNegotiated: Bool, hasName: Bool, audience: NamesAudience, nameBeforeAnswer: Bool,
                calleeAwaitsReveal: Bool, relayedAwaitsOpening: Bool, calleeIsVerifiedContact: Bool) {
        self.labelsNegotiated = labelsNegotiated; self.hasName = hasName; self.audience = audience
        self.nameBeforeAnswer = nameBeforeAnswer; self.calleeAwaitsReveal = calleeAwaitsReveal
        self.relayedAwaitsOpening = relayedAwaitsOpening; self.calleeIsVerifiedContact = calleeIsVerifiedContact
    }
}

public struct CalleeLabelContext {
    public var labelsNegotiated: Bool
    public var hasName: Bool
    public var audience: NamesAudience
    /// This phone presented a throwaway key: the caller's identity is unknown until its reveal.
    public var ownPseudonymous: Bool
    /// The caller's real key is known now and equals a verified contact's (a real-key session).
    public var callerIsVerifiedContact: Bool
    /// The caller presented a throwaway key: an "Everyone" name to a stranger waits for its reveal when the hold is on.
    public var callerPseudonymous: Bool
    /// The promoted switch `calleeNameAfterReveal`: hold an "Everyone" name for a pseudonymous stranger until the reveal.
    public var holdUntilReveal: Bool
    public init(labelsNegotiated: Bool, hasName: Bool, audience: NamesAudience, ownPseudonymous: Bool, callerIsVerifiedContact: Bool,
                callerPseudonymous: Bool = false, holdUntilReveal: Bool = false) {
        self.labelsNegotiated = labelsNegotiated; self.hasName = hasName; self.audience = audience
        self.ownPseudonymous = ownPseudonymous; self.callerIsVerifiedContact = callerIsVerifiedContact
        self.callerPseudonymous = callerPseudonymous; self.holdUntilReveal = holdUntilReveal
    }
}

/// The single decision of when a name is sent in a call (Android `CallLabelPolicy`, adapted for Apple's own decision
/// of 2026-11-05: a call subject is never sent). Declining or letting it ring reveals no callee name to a stranger: the
/// only callee moment before Accept is atRinging, which needs a verified contact.
public enum CallLabelPolicy {
    public static func callerPlan(_ c: CallerLabelContext) -> CallerLabelPlan {
        if !c.labelsNegotiated { return CallerLabelPlan(name: .never) }
        let name: LabelSendMoment
        if !c.hasName || c.audience == .nobody { name = .never }
        else if c.audience == .verified {
            if c.calleeAwaitsReveal { name = .afterRevealIfVerified }
            else if !c.calleeIsVerifiedContact { name = .never }
            else if c.relayedAwaitsOpening { name = .afterOpening }
            else { name = .now }
        }
        else if c.calleeAwaitsReveal { name = c.nameBeforeAnswer ? .now : .afterReveal }
        else if c.relayedAwaitsOpening { name = .afterOpening }
        else { name = .now }
        return CallerLabelPlan(name: name)
    }

    public static func calleeMoment(_ c: CalleeLabelContext) -> LabelSendMoment {
        if !c.labelsNegotiated || !c.hasName { return .never }
        switch c.audience {
        case .nobody: return .never
        case .everyone:
            if c.callerIsVerifiedContact { return .atRinging }
            if c.holdUntilReveal && c.ownPseudonymous && c.callerPseudonymous { return .afterReveal }
            return .atAccept
        case .verified:
            if c.callerIsVerifiedContact { return .atRinging }
            return c.ownPseudonymous ? .afterRevealIfVerified : .never
        }
    }
}

/// The caller's name in one call (Android `CallerNameRelease`; PROTOCOL "Naming v2 / Label timing and audience").
/// `CallEngine` makes the plan with `plan` before the Invite, gives it to `start`, and then only reports what happened:
/// a relayed callee's OPENING passed (`onOpeningVerified`), the callee's REVEAL verified (`onRevealVerified`), the person
/// turned out to be blocked (`onPeerBlocked`), a new connection began (`reset`). Only this class asks for the caller's
/// one LABELS container (`send`), so a test drives the same sequence the engine does. Pure: no UI, no storage.
///
/// Decision 2026-11-06 ("A caller's name waits for the reveal"): a stranger (a callee behind a throwaway key) gets
/// the name only after its REVEAL verified and the revealed person is not on the block list; the newest "Who sees my
/// name" is applied again at that moment. A callee that presented its real key is checked against the block list before
/// the name goes. An unreadable block list blocks nobody, so the name then goes as to anyone unblocked. The
/// Experimental arm `namesBeforeAnswer` (off; DEBUG launch argument only) still sends a stranger's name at `start`. No
/// byte on the wire changes: only the moment the existing container is queued.
public final class CallerNameRelease {
    /// Why a held name was dropped (a log word, never an identity).
    public enum Withheld: String, Equatable {
        case blocked, audience
        case notVerified = "not_verified"
        case unknownPeer = "unknown_peer"
    }

    /// The moment the name still waits for; `.never` when nothing is held.
    public private(set) var held: LabelSendMoment = .never
    /// Why the held name was dropped in this call, or nil.
    public private(set) var withheld: Withheld?
    /// The callee's real key when its endpoint handshake showed it (no reveal coming), else nil.
    private var realPeer: IdentityFingerprint?
    private let send: () -> Void
    private let isBlocked: (IdentityFingerprint) -> Bool

    /// `send` signs and queues this call's one name container (the engine's queue, which re-reads the name and the
    /// audience). `isBlocked` reads the block list at that moment and fails open (an unreadable list blocks nobody).
    public init(send: @escaping () -> Void, isBlocked: @escaping (IdentityFingerprint) -> Bool) {
        self.send = send
        self.isBlocked = isBlocked
    }

    /// A new connection on this endpoint: nothing is held.
    public func reset() {
        held = .never
        realPeer = nil
        withheld = nil
    }

    /// The plan of this call, before the Invite is queued. `realPeer` is the callee's full fingerprint when its endpoint
    /// handshake showed its real key, nil for a throwaway. `.now` sends at once unless that key is blocked.
    public func start(plan: CallerLabelPlan, realPeer: IdentityFingerprint?) {
        self.realPeer = realPeer
        held = plan.name
        guard plan.name == .now else { return }
        held = .never
        // A throwaway (nil) reaches .now only in the Experimental arm `namesBeforeAnswer`, which accepts that exposure.
        if let realPeer, isBlocked(realPeer) {
            withheld = .blocked
            return
        }
        send()
    }

    /// A relayed real-key callee proved it owns the offer by its OPENING. Checked again: block list, newest audience.
    public func onOpeningVerified(audienceNow: NamesAudience, verifiedContactNow: Bool) {
        guard held == .afterOpening else { return }
        held = .never
        guard let peer = realPeer else {
            withheld = .unknownPeer
            return
        }
        if isBlocked(peer) {
            withheld = .blocked
        } else if !Self.allows(audienceNow, verifiedContact: verifiedContactNow) {
            withheld = .audience
        } else {
            send()
        }
    }

    /// The callee's REVEAL verified; `revealed` is its real, full fingerprint. The name goes only now, only if `revealed`
    /// is not blocked, and only to a verified contact when the plan or the newest audience asks for one.
    public func onRevealVerified(_ revealed: IdentityFingerprint, revealedVerifiedContact: Bool, audienceNow: NamesAudience) {
        let moment = held
        guard moment == .afterReveal || moment == .afterRevealIfVerified else { return }
        held = .never
        if isBlocked(revealed) {
            withheld = .blocked
        } else if moment == .afterRevealIfVerified && !revealedVerifiedContact {
            withheld = .notVerified
        } else if !Self.allows(audienceNow, verifiedContact: revealedVerifiedContact) {
            withheld = .audience
        } else {
            send()
        }
    }

    /// The person of this call is blocked: a held name never goes in this call (also not on a repeated REVEAL).
    public func onPeerBlocked() {
        if held != .never { withheld = .blocked }
        held = .never
    }

    static func allows(_ audience: NamesAudience, verifiedContact: Bool) -> Bool {
        switch audience {
        case .nobody: return false
        case .verified: return verifiedContact
        case .everyone: return true
        }
    }

    /// The engine's inputs to `CallLabelPolicy.callerPlan`. A callee still behind a throwaway key counts as awaiting its
    /// reveal whether or not a selected offer waits for the binding (`awaitedReveal`), so a throwaway never gets the name
    /// before its reveal unless the Experimental arm is on (`nameBeforeAnswer`).
    public static func plan(labelsNegotiated: Bool, hasName: Bool, audience: NamesAudience, nameBeforeAnswer: Bool,
                            awaitedReveal: Bool, peerIsPseudonym: Bool, relayedAwaitsOpening: Bool,
                            calleeIsVerifiedContact: Bool) -> CallerLabelPlan {
        CallLabelPolicy.callerPlan(CallerLabelContext(
            labelsNegotiated: labelsNegotiated, hasName: hasName, audience: audience, nameBeforeAnswer: nameBeforeAnswer,
            calleeAwaitsReveal: awaitedReveal || peerIsPseudonym, relayedAwaitsOpening: relayedAwaitsOpening,
            calleeIsVerifiedContact: calleeIsVerifiedContact))
    }
}

/// Reserved forms for a person name (Android `NameTextRules`; PROTOCOL "Naming v2 / Text rules"). The older rules skip
/// the Common script, which holds `~` and its look-alikes, so these are explicit:
/// 1. no `~`, U+223C, U+FF5E, U+02DC, U+2053 or U+301C at the start or the end (the mark screens draw for a claimed name);
/// 2. no `~` anywhere, no shield U+1F6E1 or lock U+1F512, U+1F513, U+1F510, U+1F50F, no " - ", and no comma or middle
///    dot (U+00B7 or a look-alike: U+0387, U+2027, U+2219, U+22C5, U+30FB, U+FF65) followed by "seen" (the separators
///    screens use to join name parts; the middle dot is decision 2026-11-06, P12F/P14-P16 (a));
/// 3. the reduced skeleton (look-alikes mapped, case folded, spaces and punctuation removed) may not be that of a
///    generated name, so "BlueOtter", "Blue 0tter" and "blue otter" are refused, not only "Blue Otter".
/// Rule 3 needs the generated-name words, which the app installs at start; without them only rules 1 and 2 apply.
/// Apple has no bundled UTS #39 table: the skeleton uses Android's documented minimal table (`ConfusableTable.MINIMAL`).
public enum NameTextRules {
    static let tildes: Set<UInt32> = [0x007E, 0x223C, 0xFF5E, 0x02DC, 0x2053, 0x301C]
    static let symbols: Set<UInt32> = [0x1F6E1, 0x1F512, 0x1F513, 0x1F510, 0x1F50F]

    /// The generated-name words, reduced once.
    public struct GeneratedWords {
        let adjectives: [String]
        let nouns: Set<String>
        public init(adjectives: [String], nouns: [String]) {
            self.adjectives = adjectives.map { NameTextRules.reducedSkeleton($0) }.filter { !$0.isEmpty }
            self.nouns = Set(nouns.map { NameTextRules.reducedSkeleton($0) }.filter { !$0.isEmpty })
        }
    }

    private static let lock = NSLock()
    private static var installedWords: GeneratedWords?

    /// The words of the installed generated-name lists (names-v2), or nil.
    public static var installed: GeneratedWords? { lock.lock(); defer { lock.unlock() }; return installedWords }

    /// Called once by the app when its generated-name lists load. This is process-wide global state: any test that
    /// constructs `DesktopNearbyNames` installs rule 3 for every later test (harmless while only `shared` constructs one).
    public static func install(adjectives: [String], nouns: [String]) {
        let words = GeneratedWords(adjectives: adjectives, nouns: nouns)
        lock.lock(); installedWords = words; lock.unlock()
    }

    /// A short reason (never the text), or nil when `text` (already canonical) is not reserved.
    public static func reason(_ text: String, words: GeneratedWords? = NameTextRules.installed) -> String? {
        let scalars = Array(text.unicodeScalars)
        guard let first = scalars.first, let last = scalars.last else { return nil }
        if tildes.contains(first.value) || tildes.contains(last.value) { return "tilde at an end" }
        if scalars.contains(where: { $0.value == 0x007E || symbols.contains($0.value) }) { return "mark character" }
        if text.contains(" - ")
            || text.range(of: "[,\u{00B7}\u{0387}\u{2027}\u{2219}\u{22C5}\u{30FB}\u{FF65}]\\s*seen", options: [.regularExpression, .caseInsensitive]) != nil {
            return "separator"
        }
        if let words, looksLikeGeneratedName(text, words: words) { return "generated name" }
        return nil
    }

    /// Rule 3 alone: a reduced reading equals adjective + noun of the generated-name lists.
    public static func looksLikeGeneratedName(_ text: String, words: GeneratedWords) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let readings = [reducedSkeleton(trimmed), reducedSkeleton(trimmed.lowercased())]
        return readings.contains { reduced in
            !reduced.isEmpty && words.adjectives.contains { adjective in
                reduced.count > adjective.count && reduced.hasPrefix(adjective) && words.nouns.contains(String(reduced.dropFirst(adjective.count)))
            }
        }
    }

    /// The skeleton with spaces and punctuation removed and case folded (Android `reducedSkeleton`).
    public static func reducedSkeleton(_ text: String) -> String {
        let skeleton = minimalSkeleton(text.trimmingCharacters(in: .whitespacesAndNewlines)).lowercased()
        var out = String.UnicodeScalarView()
        for s in skeleton.precomposedStringWithCanonicalMapping.unicodeScalars {
            if LabelText.isSpace(s) { continue }
            switch s.properties.generalCategory {
            case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
                 .finalPunctuation, .otherPunctuation, .mathSymbol, .modifierSymbol:
                continue
            default: out.append(s)
            }
        }
        return String(out)
    }

    /// UTS #39 skeleton with the minimal table: NFD, drop default-ignorable format characters and variation selectors,
    /// map each code point once, NFD again.
    public static func minimalSkeleton(_ text: String) -> String {
        var mapped = String.UnicodeScalarView()
        for s in text.decomposedStringWithCanonicalMapping.unicodeScalars {
            let v = s.value
            if s.properties.generalCategory == .format || (0xFE00...0xFE0F).contains(v) || (0xE0100...0xE01EF).contains(v) || v == 0x034F { continue }
            if let target = minimalTable[v], let scalar = Unicode.Scalar(target) { mapped.append(scalar) } else { mapped.append(s) }
        }
        return String(mapped).decomposedStringWithCanonicalMapping
    }

    /// Android `ConfusableTable.MINIMAL` (each entry a line of Unicode's confusables.txt, MA): Cyrillic and Greek letters
    /// that look like Latin letters, and the I / l / 1 / | / 0 family.
    static let minimalTable: [UInt32: UInt32] = {
        let pairs: [(UInt32, Character)] = [
            // Cyrillic lower case -> Latin
            (0x0430, "a"), (0x0435, "e"), (0x043E, "o"), (0x0440, "p"), (0x0441, "c"), (0x0443, "y"),
            (0x0445, "x"), (0x0456, "i"), (0x0458, "j"), (0x0455, "s"), (0x0501, "d"), (0x051B, "q"),
            (0x051D, "w"), (0x04BB, "h"), (0x04CF, "l"),
            // Cyrillic upper case -> Latin
            (0x0410, "A"), (0x0412, "B"), (0x0415, "E"), (0x041A, "K"), (0x041C, "M"), (0x041D, "H"),
            (0x041E, "O"), (0x0420, "P"), (0x0421, "C"), (0x0422, "T"), (0x0425, "X"), (0x0406, "I"),
            (0x0408, "J"), (0x0405, "S"),
            // Greek -> Latin
            (0x03BF, "o"), (0x03BD, "v"), (0x03B9, "i"), (0x0391, "A"), (0x0392, "B"), (0x0395, "E"),
            (0x0396, "Z"), (0x0397, "H"), (0x0399, "I"), (0x039A, "K"), (0x039C, "M"), (0x039D, "N"),
            (0x039F, "O"), (0x03A1, "P"), (0x03A4, "T"), (0x03A5, "Y"), (0x03A7, "X"),
            // MA maps capital I, digit 1 and the vertical bar to lower-case l, and 0 to capital O.
            (0x0049, "l"), (0x0031, "l"), (0x007C, "l"), (0x0030, "O"),
        ]
        var table: [UInt32: UInt32] = [:]
        for (source, latin) in pairs { table[source] = latin.unicodeScalars.first!.value }
        return table
    }()
}

/// How a generated name is shown (display only; stored and compared names stay lower case, as Android stores them).
public enum GeneratedNameText {
    /// "mild bream 42-7a7d" -> "Mild Bream 42-7a7d": the first letter of each word made only of a-z is upper-cased;
    /// the two digits and the ID tail stay as they are.
    public static func display(_ name: String) -> String {
        name.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            guard let first = word.first, word.allSatisfy({ ("a"..."z").contains($0) }) else { return String(word) }
            return first.uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }
}

/// Android `NameTextRules.readings`/`sameReading` (minimal table): case- and look-alike-insensitive sameness.
public enum NameReading {
    public static func readings(_ text: String) -> Set<String> {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return [NameTextRules.minimalSkeleton(t).lowercased(), NameTextRules.minimalSkeleton(t.lowercased()).lowercased()]
    }
    public static func same(_ a: String, _ b: String) -> Bool {
        let ta = a.trimmingCharacters(in: .whitespacesAndNewlines), tb = b.trimmingCharacters(in: .whitespacesAndNewlines)
        return !ta.isEmpty && !tb.isEmpty && !readings(ta).isDisjoint(with: readings(tb))
    }
}

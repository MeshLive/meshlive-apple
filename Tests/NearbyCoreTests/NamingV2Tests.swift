import XCTest
@testable import NearbyCore

/// When a name is sent (Android CallLabelPolicyTest, adapted for Apple's decision of 2026-11-05: no call subject),
/// the reserved name forms and the generated-name display.
final class NamingV2Tests: XCTestCase {
    private func caller(audience: NamesAudience = .everyone, negotiated: Bool = true, name: Bool = true,
                        beforeAnswer: Bool = true, awaitsReveal: Bool = false, relayed: Bool = false,
                        verifiedContact: Bool = false) -> CallerLabelPlan {
        CallLabelPolicy.callerPlan(CallerLabelContext(labelsNegotiated: negotiated, hasName: name, audience: audience,
                                                      nameBeforeAnswer: beforeAnswer, calleeAwaitsReveal: awaitsReveal,
                                                      relayedAwaitsOpening: relayed, calleeIsVerifiedContact: verifiedContact))
    }

    private func callee(_ audience: NamesAudience = .everyone, negotiated: Bool = true, name: Bool = true,
                        ownPseudonymous: Bool = false, callerVerified: Bool = false) -> LabelSendMoment {
        CallLabelPolicy.calleeMoment(CalleeLabelContext(labelsNegotiated: negotiated, hasName: name, audience: audience,
                                                        ownPseudonymous: ownPseudonymous, callerIsVerifiedContact: callerVerified))
    }

    // Caller

    func testAPeerWithoutBit5GetsNothingFromEitherSide() {
        XCTAssertEqual(caller(negotiated: false), CallerLabelPlan(name: .never))
        XCTAssertEqual(callee(negotiated: false), .never)
    }

    func testAStrangerSessionSendsTheNameNow() {
        XCTAssertEqual(caller(beforeAnswer: true, awaitsReveal: true), CallerLabelPlan(name: .now))
    }

    func testTheControlArmHoldsTheNameUntilTheReveal() {
        XCTAssertEqual(caller(beforeAnswer: false, awaitsReveal: true), CallerLabelPlan(name: .afterReveal))
    }

    func testARealKeySessionSendsTheNameNowAndARelayedCalleeWaitsForItsOpening() {
        XCTAssertEqual(caller(), CallerLabelPlan(name: .now))
        XCTAssertEqual(caller(relayed: true), CallerLabelPlan(name: .afterOpening))
    }

    func testNothingIsSentWhenThereIsNothingToSend() {
        XCTAssertEqual(caller(name: false), CallerLabelPlan(name: .never))
    }

    func testNobodySendsNoName() {
        XCTAssertEqual(caller(audience: .nobody), CallerLabelPlan(name: .never))
        XCTAssertEqual(caller(audience: .nobody, awaitsReveal: true).name, .never)
    }

    func testOnlyMyContactsGivesTheNameToAVerifiedContactAndToNoStranger() {
        XCTAssertEqual(caller(audience: .verified, verifiedContact: true).name, .now)
        XCTAssertEqual(caller(audience: .verified, verifiedContact: false).name, .never)
        XCTAssertEqual(caller(audience: .verified, awaitsReveal: true).name, .afterRevealIfVerified,
                       "a pseudonymous callee may be a contact whose lease expired: decided after its verified reveal")
        XCTAssertEqual(caller(audience: .verified, relayed: true, verifiedContact: true).name, .afterOpening)
    }

    func testNameBeforeAnswerChangesNothingForARealKeyCall() {
        for before in [true, false] {
            XCTAssertEqual(caller(beforeAnswer: before).name, .now)
            XCTAssertEqual(caller(audience: .verified, beforeAnswer: before, verifiedContact: true).name, .now)
        }
    }

    // Callee

    func testTheCalleeRuleForPeopleICallOrWhoCallMe() {
        XCTAssertEqual(callee(callerVerified: true), .atRinging)
        XCTAssertEqual(callee(callerVerified: false), .atAccept)
        XCTAssertEqual(callee(ownPseudonymous: true), .atAccept)
    }

    func testOnlyMyContactsCalleeWaitsForTheCallersRevealOrSendsNothing() {
        XCTAssertEqual(callee(.verified, callerVerified: false), .never)
        XCTAssertEqual(callee(.verified, callerVerified: true), .atRinging)
        XCTAssertEqual(callee(.verified, ownPseudonymous: true, callerVerified: false), .afterRevealIfVerified)
    }

    func testTheCalleeSendsNothingForNobodyOrWithoutAName() {
        XCTAssertEqual(callee(.nobody, callerVerified: true), .never)
        XCTAssertEqual(callee(name: false, callerVerified: true), .never)
    }

    func testDecliningOrLettingItRingRevealsNoCalleeNameToAStranger() {
        for audience in NamesAudience.allCases {
            for pseudonymous in [true, false] {
                XCTAssertNotEqual(callee(audience, ownPseudonymous: pseudonymous, callerVerified: false), .atRinging)
            }
        }
    }

    func testTheStoredAudienceDefaultsToPeopleICallOrWhoCallMe() {
        XCTAssertEqual(NamesAudience.stored(nil), .everyone)
        XCTAssertEqual(NamesAudience.stored("garbage"), .everyone)
        for audience in NamesAudience.allCases { XCTAssertEqual(NamesAudience.stored(audience.rawValue), audience) }
    }

    // Reserved forms

    func testTheClaimMarkAndTheAppsSeparatorsCannotBePartOfAName() {
        for name in ["~Rahul", "Rahul~", "Ra~hul", "\u{223C}Rahul", "Rahul\u{FF5E}", "Asha \u{1F6E1}", "Asha \u{1F512}",
                     "Asha - Blue", "Asha, seen nearby", "Asha,seen"] {
            XCTAssertNotNil(NameTextRules.reason(name, words: nil), name)
            XCTAssertThrowsError(try LabelText.normalize(.personName, name).get(), name)
        }
        for name in ["Rahul", "Asha K", "Mary-Jane", "Dr. Rao"] {
            XCTAssertNil(NameTextRules.reason(name, words: nil), name)
        }
    }

    /// Decision 2026-11-06 (P12F/P14-P16 (a)): the middle-dot separator the screens use ("Mum · seen nearby ·
    /// unconfirmed") cannot be part of a name either, with or without spaces, in any case, nor with a look-alike dot.
    func testTheMiddleDotSeenSeparatorCannotBePartOfAName() {
        for name in ["Asha \u{00B7} seen nearby", "Asha\u{00B7}seen", "Asha \u{00B7} SEEN", "Asha \u{30FB} seen", "Asha \u{22C5} seen",
                     "Asha \u{2027} seen", "Asha \u{2219} seen", "Asha \u{FF65} seen", "Asha \u{0387} seen"] {
            XCTAssertNotNil(NameTextRules.reason(name, words: nil), name)
            XCTAssertThrowsError(try LabelText.normalize(.personName, name).get(), name)
        }
        for name in ["Asha \u{00B7} Ravi", "Seen Asha", "Asha seen"] {
            XCTAssertNil(NameTextRules.reason(name, words: nil), name)
        }
    }

    func testAGeneratedNameAndItsLookAlikesAreRefusedOnlyWithTheListsInstalled() {
        let words = NameTextRules.GeneratedWords(adjectives: ["blue", "mild"], nouns: ["otter", "bream"])
        for name in ["Blue Otter", "blue otter", "BlueOtter", "Blue 0tter", "Blue \u{041E}tter", "MILD bream"] {
            XCTAssertEqual(NameTextRules.reason(name, words: words), "generated name", name)
        }
        for name in ["Blue", "Otter Blue", "Blue Otters", "Brave Tiger"] {
            XCTAssertNil(NameTextRules.reason(name, words: words), name)
        }
        XCTAssertNil(NameTextRules.reason("Blue Otter", words: nil), "rule 3 needs the lists")
    }

    func testAStreamTitleMayStillUseTheTilde() {
        XCTAssertNoThrow(try LabelText.normalize(.streamTitle, "~ Live music ~").get())
    }

    // Display

    func testGeneratedNamesAreShownTitleCasedWithTheirSuffixKept() {
        XCTAssertEqual(GeneratedNameText.display("mild bream"), "Mild Bream")
        XCTAssertEqual(GeneratedNameText.display("mild bream 42"), "Mild Bream 42")
        XCTAssertEqual(GeneratedNameText.display("mild bream 42-7a7d"), "Mild Bream 42-7a7d")
    }

    // Minimal-table sameness (Android NameTextRules.readings/sameReading)

    func testNamesThatReadTheSameAreEqualAndDifferentNamesAreNot() {
        for name in ["mum", "\u{041C}um", "MUM"] { XCTAssertTrue(NameReading.same("Mum", name), name) }
        XCTAssertFalse(NameReading.same("Rahul", "Ravi"))
    }
}

/// Decision 2026-11-06 ("A caller's name waits for the reveal"), driven through `CallerNameRelease` in the order
/// `CallEngine` calls it (Android CallerNameReleaseTest): the plan before the Invite, then the OPENING, the REVEAL or the
/// block. What the test collects is exactly what the engine would queue, signed by the attempt's throwaway key, and the
/// callee side reads it with the receiver's own `LabelInbox`.
final class CallerNameReleaseTests: XCTestCase {
    /// The caller's attempt throwaway: the key its endpoint handshake presented to a stranger, so it signs the name.
    private let throwaway = SoftwareSigningIdentity()
    private let callId = UUID(uuidString: "0A0B0C0D-0102-0304-0506-0708090A0B0C")!
    /// The callee's real identity, as its REVEAL shows it.
    private let callee = SoftwareSigningIdentity().fingerprint
    private let someoneElse = SoftwareSigningIdentity().fingerprint
    private var queued: [Data] = []
    /// The caller's name as the app re-reads it when queuing (not `name`: XCTestCase has one).
    private var localName: String? = "Rahul"
    private var blocked: Set<IdentityFingerprint> = []
    private var release: CallerNameRelease!

    override func setUp() {
        super.setUp()
        queued = []
        localName = "Rahul"
        blocked = []
        release = CallerNameRelease(
            send: { [unowned self] in
                guard let name = self.localName,
                      let label = try? SignedLabelCodec.sign(identity: self.throwaway, kind: .personName, binding: .call(self.callId), text: name),
                      let container = try? SignedLabelCodec.encodeContainer([label]) else { return }
                self.queued.append(container)
            },
            isBlocked: { [unowned self] fingerprint in self.blocked.contains(fingerprint) })
    }

    /// The plan exactly as the engine makes it for a callee behind a throwaway key (a stranger).
    private func strangerPlan(nameBeforeAnswer: Bool = false, audience: NamesAudience = .everyone,
                              awaitedReveal: Bool = true) -> CallerLabelPlan {
        CallerNameRelease.plan(labelsNegotiated: true, hasName: true, audience: audience, nameBeforeAnswer: nameBeforeAnswer,
                               awaitedReveal: awaitedReveal, peerIsPseudonym: true, relayedAwaitsOpening: false,
                               calleeIsVerifiedContact: false)
    }

    /// The plan for a callee whose endpoint handshake showed its real key.
    private func realKeyPlan(relayed: Bool = false) -> CallerLabelPlan {
        CallerNameRelease.plan(labelsNegotiated: true, hasName: true, audience: .everyone, nameBeforeAnswer: false,
                               awaitedReveal: false, peerIsPseudonym: false, relayedAwaitsOpening: relayed,
                               calleeIsVerifiedContact: false)
    }

    /// What the callee's device shows from everything queued so far, after the receiver's own checks (signer, call ID).
    private func calleeSees() -> String? {
        var now: TimeInterval = 0
        let inbox = LabelInbox(now: { now += 10; return now })
        for container in queued { _ = inbox.accept(container, expectedSigner: throwaway.nodeId, expectedBinding: .call(callId)) }
        return inbox.text(.personName)
    }

    func testAStrangerCalleeSeesNoNameWhileItRingsAndTheNameOnlyAfterItsVerifiedReveal() {
        let plan = strangerPlan()
        XCTAssertEqual(plan.name, .afterReveal)
        release.start(plan: plan, realPeer: nil)
        XCTAssertTrue(queued.isEmpty, "nothing is queued before the Invite or while it rings")
        XCTAssertNil(calleeSees())
        release.onOpeningVerified(audienceNow: .everyone, verifiedContactNow: false)
        XCTAssertTrue(queued.isEmpty, "an OPENING is not a stranger's moment")
        release.onRevealVerified(callee, revealedVerifiedContact: false, audienceNow: .everyone)
        XCTAssertEqual(calleeSees(), "Rahul")
        // The same reveal again: the name does not go twice.
        release.onRevealVerified(callee, revealedVerifiedContact: false, audienceNow: .everyone)
        XCTAssertEqual(queued.count, 1)
    }

    func testACalleeRevealedAsSomeoneIBlockedNeverGetsTheName() {
        blocked = [callee]
        release.start(plan: strangerPlan(), realPeer: nil)
        // The engine checks the block first and tells the release; a later (repeated) reveal releases nothing.
        release.onPeerBlocked()
        release.onRevealVerified(callee, revealedVerifiedContact: false, audienceNow: .everyone)
        XCTAssertTrue(queued.isEmpty)
        XCTAssertNil(calleeSees())
        XCTAssertEqual(release.withheld, .blocked)
    }

    func testTheReleaseChecksTheBlockListItselfEvenIfTheCallSiteDidNot() {
        blocked = [callee]
        release.start(plan: strangerPlan(), realPeer: nil)
        release.onRevealVerified(callee, revealedVerifiedContact: false, audienceNow: .everyone)
        XCTAssertTrue(queued.isEmpty)
        // The block keys on the full fingerprint: someone else who reveals in the next call gets the name.
        release.reset()
        release.start(plan: strangerPlan(), realPeer: nil)
        release.onRevealVerified(someoneElse, revealedVerifiedContact: false, audienceNow: .everyone)
        XCTAssertEqual(calleeSees(), "Rahul")
    }

    func testAPersonBlockedWhileThePhoneRingsNeverGetsTheName() {
        release.start(plan: strangerPlan(), realPeer: nil)
        blocked = [callee]
        release.onRevealVerified(callee, revealedVerifiedContact: false, audienceNow: .everyone)
        XCTAssertTrue(queued.isEmpty)
    }

    func testTheHeldNameFollowsTheNewestWhoSeesMyName() {
        release.start(plan: strangerPlan(), realPeer: nil)
        release.onRevealVerified(callee, revealedVerifiedContact: false, audienceNow: .nobody)
        XCTAssertTrue(queued.isEmpty, "Nobody chosen while it rang")
        release.reset()
        release.start(plan: strangerPlan(), realPeer: nil)
        release.onRevealVerified(callee, revealedVerifiedContact: false, audienceNow: .verified)
        XCTAssertTrue(queued.isEmpty, "Only my contacts chosen while it rang, and the stranger is no contact")
        release.reset()
        release.start(plan: strangerPlan(), realPeer: nil)
        release.onRevealVerified(callee, revealedVerifiedContact: true, audienceNow: .verified)
        XCTAssertEqual(calleeSees(), "Rahul")
    }

    func testWithOnlyMyContactsAStrangerWhoRevealsAsNoContactGetsNothing() {
        let plan = strangerPlan(audience: .verified)
        XCTAssertEqual(plan.name, .afterRevealIfVerified)
        release.start(plan: plan, realPeer: nil)
        release.onRevealVerified(callee, revealedVerifiedContact: false, audienceNow: .verified)
        XCTAssertTrue(queued.isEmpty)
    }

    func testAThrowawayCalleeWithoutASelectedOfferStillWaitsForItsReveal() {
        let plan = strangerPlan(awaitedReveal: false)
        XCTAssertEqual(plan.name, .afterReveal)
        release.start(plan: plan, realPeer: nil)
        XCTAssertTrue(queued.isEmpty)
        release.onRevealVerified(callee, revealedVerifiedContact: false, audienceNow: .everyone)
        XCTAssertEqual(calleeSees(), "Rahul")
    }

    func testANameRemovedWhileItRangIsNotSent() {
        release.start(plan: strangerPlan(), realPeer: nil)
        localName = nil
        release.onRevealVerified(callee, revealedVerifiedContact: false, audienceNow: .everyone)
        XCTAssertTrue(queued.isEmpty)
    }

    func testOnlyTheExperimentalArmSendsAStrangersNameBeforeTheInvite() {
        // Without the arm the name is held (the other tests); the Experimental arm (DEBUG `-namesBeforeAnswer YES`) queues
        // it at start, before the Invite, to a throwaway nobody can check against the block list.
        let plan = strangerPlan(nameBeforeAnswer: true)
        XCTAssertEqual(plan.name, .now)
        release.start(plan: plan, realPeer: nil)
        XCTAssertEqual(calleeSees(), "Rahul")
    }

    func testARealKeyCalleeGetsTheNameBeforeTheInviteUnlessItIsBlocked() {
        let plan = realKeyPlan()
        XCTAssertEqual(plan.name, .now)
        blocked = [callee]
        release.start(plan: plan, realPeer: callee)
        XCTAssertTrue(queued.isEmpty)
        XCTAssertEqual(release.withheld, .blocked)
        release.reset()
        release.start(plan: plan, realPeer: someoneElse)
        XCTAssertEqual(calleeSees(), "Rahul")
    }

    func testARelayedRealKeyCalleeGetsTheNameOnlyAfterItsOpeningAndOnlyIfStillAllowed() {
        let plan = realKeyPlan(relayed: true)
        XCTAssertEqual(plan.name, .afterOpening)
        release.start(plan: plan, realPeer: callee)
        XCTAssertTrue(queued.isEmpty, "nothing before the OPENING")
        blocked = [callee]
        release.onOpeningVerified(audienceNow: .everyone, verifiedContactNow: false)
        XCTAssertTrue(queued.isEmpty, "blocked before its OPENING arrived")
        blocked = []
        release.reset()
        release.start(plan: plan, realPeer: callee)
        release.onOpeningVerified(audienceNow: .nobody, verifiedContactNow: false)
        XCTAssertTrue(queued.isEmpty, "Nobody chosen before its OPENING arrived")
        release.reset()
        release.start(plan: plan, realPeer: callee)
        release.onOpeningVerified(audienceNow: .everyone, verifiedContactNow: false)
        XCTAssertEqual(calleeSees(), "Rahul")
    }

    func testAnUnreadableBlockListBlocksNobodySoTheNameGoesAfterTheRevealAsForAnyoneElse() {
        // Decision 2026-11-06: fail open. The app's check reads the holder's list, which is nil while damaged.
        var holder = BlockListHolder(save: { _ in true })
        holder.reloadIfNeeded { .damaged }
        let failOpen = CallerNameRelease(send: { [unowned self] in
            guard let label = try? SignedLabelCodec.sign(identity: self.throwaway, kind: .personName, binding: .call(self.callId), text: "Rahul"),
                  let container = try? SignedLabelCodec.encodeContainer([label]) else { return }
            self.queued.append(container)
        }, isBlocked: { fingerprint in holder.list?.contains(fingerprint) ?? false })
        failOpen.start(plan: strangerPlan(), realPeer: nil)
        failOpen.onRevealVerified(callee, revealedVerifiedContact: false, audienceNow: .everyone)
        XCTAssertEqual(calleeSees(), "Rahul")
    }
}

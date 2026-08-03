import Foundation
import CryptoKit

/// Redeem codes that grant Tween Pro without a purchase — for friends, testers,
/// press, and support make-goods.
///
/// HONEST LIMITATION: Tween has no server (constraint 8), so validation happens
/// entirely on-device and any client-side scheme is ultimately defeatable.
/// Storing SHA-256 digests instead of the literal strings stops the codes from
/// falling out of `strings Tween.app/Tween` — that's real, and it's all it is. A
/// determined attacker can still patch the binary or brute-force a short code.
/// These are convenience codes for people you WANT to have Pro, not a licence
/// enforcement mechanism. Treat a leaked code as public and rotate it.
///
/// Codes are stored separately from the StoreKit verdict on purpose: see
/// `ProEntitlement.refresh()`, which recomputes the purchase flag on every
/// launch and would otherwise stamp a redeemed unlock back to false.
enum ProCode {
    /// SHA-256 of each valid code, uppercased with separators stripped.
    /// To add one: `printf '%s' 'YOURCODE' | shasum -a 256`.
    /// To revoke one: delete its digest and ship an update — already-redeemed
    /// devices keep Pro, since redemption is recorded locally.
    private static let validDigests: Set<String> = [
        // HALFWAY2026
        "bff0e00553e9323615aa6640a2f5655250355f3ee70067e16d7acf9a4274d6eb",
        // TWEENFOUNDER
        "fdf77a9f035d27e9b93cd65f53d80d6f5fe708d02d462ec57616ddc82c3a2692",
    ]

    /// True once any valid code has been redeemed on this device. Survives
    /// `ProEntitlement.refresh()` because it lives under its own key. The flag
    /// itself lives in `ProEntitlement` (Shared) so that the extension can read
    /// the gate without linking CryptoKit for this file's digest checking.
    static var hasRedeemed: Bool { ProEntitlement.isRedeemed }

    /// Case-, space-, and dash-insensitive so "halfway 2026" and
    /// "HALFWAY-2026" both work — people retype these from a text message.
    static func normalize(_ raw: String) -> String {
        raw.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    static func isValid(_ raw: String) -> Bool {
        let normalized = normalize(raw)
        guard !normalized.isEmpty else { return false }
        let digest = SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return validDigests.contains(digest)
    }

    /// Records a valid code and lights up Pro. Returns false and changes
    /// nothing when the code doesn't match.
    @discardableResult
    static func redeem(_ raw: String) -> Bool {
        guard isValid(raw) else { return false }
        // setRedeemed recomputes the gate; post AFTER, so the other process
        // never wakes to a stale value.
        ProEntitlement.setRedeemed(true)
        MeetupSync.post()
        return true
    }

    /// Test/support hook — clears the redemption on this device.
    static func clearRedemption() {
        ProEntitlement.setRedeemed(false)
        MeetupSync.post()
    }
}

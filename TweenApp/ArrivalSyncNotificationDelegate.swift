import Foundation
import UIKit
import UserNotifications

/// Routes a tapped Arrival Sync notification into the meetup it is about.
///
/// The only reason this exists: without a `UNUserNotificationCenterDelegate`,
/// tapping "Time to go" opens Tween on whatever screen it was last on, which
/// for a lock-screen tap is usually nothing useful. The notification carries a
/// `tween://meetup` deep link in `userInfo`, and this hands it to the same
/// `onOpenURL` router every other Tween link already goes through — so there
/// is one navigation path, not a second one invented for notifications.
///
/// Also opts into showing a notification while Tween is FOREGROUND. "Time to
/// go" is time-critical and the app being open is not evidence the user is
/// looking at the meetup — they may be searching for somewhere else entirely.
final class ArrivalSyncNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    /// Held by the app so the notification centre's weak delegate reference
    /// does not drop it. Registered once, at launch.
    static let shared = ArrivalSyncNotificationDelegate()

    func register() {
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification)
    async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let raw = info[ArrivalSyncNotifier.deepLinkKey] as? String,
              let url = URL(string: raw),
              // Only Tween's own scheme, and only from our own content: a
              // notification's userInfo is data, and handing an arbitrary URL
              // to `UIApplication.open` from here would be a way to make the
              // app open anything.
              url.scheme == "tween"
        else { return }
        await MainActor.run {
            // Through the app's own URL router (`handleIncomingURL` via
            // `onOpenURL`) rather than touching view state directly — the
            // routing rules for a meetup link live in exactly one place.
            UIApplication.shared.open(url)
        }
    }
}

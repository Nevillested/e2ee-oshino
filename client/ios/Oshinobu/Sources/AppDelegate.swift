import OshinobuCore
import PushKit
import UIKit
import UserNotifications

/**
 * Пуши iOS. Сервер шлёт три вида (без содержимого — только «подключись»):
 * VoIP о звонке (PushKit → CallKit сразу), обычный о сообщении (текст из строк
 * приложения, система показывает сама) и фоновый call_cancel. По пушу приложение
 * может запуститься без окна — поэтому модель живёт здесь, а не в сцене.
 */
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, PKPushRegistryDelegate {
    static private(set) weak var shared: AppDelegate?
    let model = AppModel()
    private var voip: PKPushRegistry?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Self.shared = self
        UNUserNotificationCenter.current().delegate = self
        _ = model.callController // CallKit — до первого VoIP-пуша
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        voip = registry
        application.registerForRemoteNotifications()
        return true
    }

    // MARK: APNs (сообщения, отмена звонка)

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        model.core.setPushToken(deviceToken.hex, voip: false)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        model.core.logger.log("Push: APNs registration failed: \(error)")
    }

    /// Фоновый пуш (и пуш о сообщении с content-available): подключиться и забрать очередь.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        if userInfo["type"] as? String == "call_cancel", let callId = userInfo["call_id"] as? String {
            model.callController.cancelPushedCall(callId: callId)
            return .noData
        }
        await model.launch()
        // несколько секунд на приём: очередь сервер отдаёт сразу после подключения
        try? await Task.sleep(for: .seconds(8))
        return .newData
    }

    // MARK: PushKit (звонки)

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        let hex = pushCredentials.token.hex
        MainActor.assumeIsolated { model.core.setPushToken(hex, voip: true) }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType,
                                  completion: @escaping () -> Void) {
        let data = payload.dictionaryPayload
        let callId = data["call_id"] as? String ?? UUID().uuidString
        let caller = data["caller_device_id"] as? String ?? ""
        // очередь реестра — главная: CallKit сообщаем синхронно, как требует iOS
        MainActor.assumeIsolated {
            model.callController.reportPushedCall(callId: callId, callerDeviceId: caller, completion: completion)
        }
    }

    // MARK: уведомления

    /// Приложение на экране — сообщение уже пришло по WebSocket, баннер не нужен.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

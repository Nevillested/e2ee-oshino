package com.oshinobu.core

import com.oshinobu.core.net.ApiClient
import com.oshinobu.core.net.ApiConfig
import com.oshinobu.core.net.WebSocketClient
import com.oshinobu.core.service.AckRegistry
import com.oshinobu.core.service.Avatars
import com.oshinobu.core.service.CallManager
import com.oshinobu.core.service.ChatActions
import com.oshinobu.core.service.ChatService
import com.oshinobu.core.service.CrashReporter
import com.oshinobu.core.service.DeviceSetup
import com.oshinobu.core.service.FileLogger
import com.oshinobu.core.service.KeyedMutex
import com.oshinobu.core.service.MediaDownloadManager
import com.oshinobu.core.service.MediaUploader
import com.oshinobu.core.service.MessageCleanup
import com.oshinobu.core.service.MessageRouter
import com.oshinobu.core.service.MyAccount
import com.oshinobu.core.service.PeerMessenger
import com.oshinobu.core.service.PeerProfiles
import com.oshinobu.core.service.PendingSendRetrier
import com.oshinobu.core.service.RouterHost
import com.oshinobu.core.service.RtcEngine
import com.oshinobu.core.service.SendQueueProcessor
import com.oshinobu.core.service.UploadCancellations
import com.oshinobu.core.storage.AppDirs
import com.oshinobu.core.storage.AppLockStore
import com.oshinobu.core.storage.ChatStore
import com.oshinobu.core.storage.ChunkedUploadSessionStore
import com.oshinobu.core.storage.DownloadQueueStore
import com.oshinobu.core.storage.KeyStore
import com.oshinobu.core.storage.MediaFiles
import com.oshinobu.core.storage.PeerAccountStore
import com.oshinobu.core.storage.PeerIdentityStore
import com.oshinobu.core.storage.PendingEmailVerification
import com.oshinobu.core.storage.PendingSendStore
import com.oshinobu.core.storage.Prefs
import com.oshinobu.core.storage.SecureStore
import com.oshinobu.core.storage.SendQueueStore
import com.oshinobu.core.storage.Session
import com.oshinobu.core.storage.SessionStore
import com.oshinobu.core.storage.UiSettings
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Всё ядро клиента, собранное и связанное: хранилища, сеть, сервисы.
 * Платформа (Android) даёт только хранилища, каталоги и побочные эффекты
 * ([RouterHost]); жизненный цикл — [startSession] после входа и
 * [WebSocketClient.disconnect] при выходе.
 */
class OshinobuCore(
    secure: SecureStore,
    val prefs: Prefs,
    val dirs: AppDirs,
    routerHost: RouterHost,
    /** WebRTC платформы (на Android — org.webrtc). */
    rtcEngine: RtcEngine,
    config: ApiConfig = ApiConfig(),
    val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
) {
    val logger = FileLogger(dirs, scope)
    val api = ApiClient(config)
    val ws = WebSocketClient(api, scope, log = logger::log)

    // хранилища
    val session = Session(prefs)
    val keys = KeyStore(secure)
    val sessions = SessionStore(secure)
    val chats = ChatStore(secure)
    val peerAccounts = PeerAccountStore(secure)
    val peerIdentities = PeerIdentityStore(secure)
    val sendQueueStore = SendQueueStore(secure)
    val pendingSends = PendingSendStore(secure, dirs)
    val chunkedSessions = ChunkedUploadSessionStore(secure)
    val downloadQueue = DownloadQueueStore(secure)
    val media = MediaFiles(dirs)
    val appLock = AppLockStore(secure)
    val settings = UiSettings(secure, prefs)
    val pendingEmail = PendingEmailVerification(prefs)

    // сервисы
    private val sendLock = KeyedMutex()
    val acks = AckRegistry(ws, scope)
    val uploads = UploadCancellations()
    val sendQueue = SendQueueProcessor(sendQueueStore, ws, acks, chats, scope, logger)
    val cleanup = MessageCleanup(chats, media, dirs, chunkedSessions, pendingSends, sendQueueStore, acks, uploads::cancel)
    val messenger = PeerMessenger(api, session, keys, sessions, peerAccounts, peerIdentities, chats, sendQueue, sendLock, logger)
    val router = MessageRouter(
        ws, api, session, keys, sessions, peerAccounts, peerIdentities, chats, prefs, sendQueue, cleanup, sendLock, routerHost, scope, logger,
    )
    val deviceSetup = DeviceSetup(api, keys, logger)
    val uploader = MediaUploader(api, chats, dirs, chunkedSessions, media, logger)
    val pendingSender = PendingSendRetrier(
        pendingSends, chats, session, peerAccounts, chunkedSessions, uploader, messenger, cleanup, uploads, scope, logger,
    )
    val downloads = MediaDownloadManager(api, session, media, downloadQueue, scope, logger)
    val peerProfiles = PeerProfiles(api, session, dirs, scope, logger)
    val avatars = Avatars(api, session, dirs, scope, logger)
    val myAccount = MyAccount(api, session, dirs, logger)
    val crashReporter = CrashReporter(logger, api, session, prefs, scope)
    val chatActions = ChatActions(api, session, chats, messenger, router, cleanup)
    val chatService = ChatService(chats, messenger, router, cleanup, pendingSends, pendingSender, logger)
    val calls = CallManager(ws, messenger, router, api, session, chats, rtcEngine, scope, logger)

    init {
        crashReporter.install()
    }

    /**
     * Запуск после входа (или при старте приложения с сохранённой сессией):
     * регистрация устройства при первом входе, соединение, очереди, роутер,
     * подготовка списка чатов. Повторный вызов безопасен.
     */
    suspend fun startSession() {
        val token = session.token ?: return
        deviceSetup.ensureDeviceRegistered(token)
        val deviceId = keys.deviceId() ?: return
        router.start()
        calls.start()
        sendQueue.start()
        pendingSender.start()
        downloads.init()
        media.pruneStalePartials()
        chats.backfillLastMessageMeta()
        startServerSync(token)
        ws.connect(token, deviceId)
        _sessionActive.value = true
        deviceSetup.ensurePrekeysTopped(token, deviceId)
    }

    private val _sessionActive = MutableStateFlow(false)

    /** Сессия запущена ([startSession]) и не завершена — можно регистрировать пуш-токен и т.п. */
    val sessionActive: StateFlow<Boolean> = _sessionActive.asStateFlow()

    /** Токен пушей (FCM) этого устройства — серверу, чтобы будить при новых сообщениях и звонках. */
    suspend fun registerPushToken(fcmToken: String): Boolean {
        val token = session.token ?: return false
        val deviceId = keys.deviceId() ?: return false
        return api.registerPushToken(token, deviceId, fcmToken)
    }

    private val serverSyncStarted = AtomicBoolean(false)

    /**
     * Состояние, которое живёт на сервере: мьюты и блокировки (сейчас и по
     * событию block_status_changed), профили/аватары собеседников (сброс по
     * profile_updated), свой профиль.
     */
    private fun startServerSync(token: String) {
        if (!serverSyncStarted.compareAndSet(false, true)) return
        scope.launch { syncMutedChats(token) }
        scope.launch { syncBlockedContacts(token) }
        scope.launch { myAccount.load() }
        scope.launch { ws.blockStatusEvents.collect { syncBlockedContacts(token) } }
        scope.launch {
            ws.profileChanges.collect { change ->
                if (change.field == "avatar") avatars.invalidate(change.accountId) else peerProfiles.invalidate(change.accountId)
            }
        }
    }

    private suspend fun syncMutedChats(token: String) = chats.syncMutedFromServer(api.getMutedChats(token).toSet())

    private suspend fun syncBlockedContacts(token: String) {
        val blocked = api.getBlockedContacts(token) ?: return
        chats.syncBlockedFromServer(blocked.blockedByMe.toSet(), blocked.blockingMe.toSet())
    }

    /** "Выйти": отозвать пуш-токен этого устройства и стереть всё локальное. */
    suspend fun logout() {
        val token = session.token
        val deviceId = keys.deviceId()
        if (token != null && deviceId != null) api.unregisterPushToken(token, deviceId)
        signOutLocally()
    }

    /**
     * Сессия больше не действует (вошли с другого устройства / выход):
     * отключиться и стереть ВСЁ локальное — ключи, сессии, переписку, как во
     * Flutter-клиенте (KeyStore.clearAll удаляет всё secure storage).
     */
    suspend fun signOutLocally() {
        _sessionActive.value = false
        ws.disconnect()
        session.token = null
        session.login = null
        session.accountId = null
        keys.clearAll()
        myAccount.reset()
    }
}

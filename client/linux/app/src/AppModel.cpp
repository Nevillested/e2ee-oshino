#include "AppModel.h"

#include "Desktop.h"
#ifdef OSHINOBU_HAVE_GSTREAMER
#include "media/GstRtcEngine.h"
#endif
#include "VideoView.h"
#ifdef OSHINOBU_HAVE_GSTREAMER
#include "media/GstRecorder.h"
#endif
#include "support/Json.h"
#include "support/Log.h"

#include <QBuffer>
#include <QClipboard>
#include <QDateTime>
#include <QDesktopServices>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QIcon>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QLocale>
#include <QMimeDatabase>
#include <QSettings>
#include <QStandardPaths>
#include <QUrlQuery>
#include <QUuid>

using namespace osh;

namespace {

struct Palette {
    const char *id;
    const char *title;
    const char *primary, *onPrimary, *background, *surface, *textPrimary, *textMuted, *chatBackground, *bubbleMine, *onBubbleMine, *sentTick,
        *linkOnMine;
    bool dark;
};

// те же 5 тем, что на Android (ui/theme/Theme.kt)
const Palette palettes[] = {
    {"dark", "theme_navy", "#2AABEE", "#FFFFFF", "#17212B", "#242F3D", "#FFFFFF", "#8E99A4", "#17212B", "#2AABEE", "#FFFFFF", "#40C4FF", "#FFD54F", true},
    {"light", "theme_white", "#2AABEE", "#FFFFFF", "#EEF2F7", "#FFFFFF", "#17212B", "#6B7A88", "#DCE6EF", "#2AABEE", "#FFFFFF", "#D6F1FF", "#FFE082", false},
    {"black", "theme_black", "#0A84FF", "#FFFFFF", "#000000", "#1C1C1E", "#FFFFFF", "#8E8E93", "#000000", "#0A84FF", "#FFFFFF", "#B8DAFF", "#FFE082", true},
    {"yellow", "theme_yellow", "#FFD60A", "#141414", "#0E0E0C", "#1F1E1A", "#F5F2E7", "#A6A28E", "#0A0A08", "#FFD60A", "#141414", "#6B5A00", "#0B57D0", true},
    {"green", "theme_green", "#3DDC97", "#062A1C", "#0F1D18", "#1A2E26", "#E7F5EE", "#8DB3A3", "#0B1712", "#1E7A54", "#FFFFFF", "#9EF0C8", "#FFE082", true},
};

const Palette &paletteById(const QString &id) {
    for (const auto &p : palettes) {
        if (id == QLatin1String(p.id)) return p;
    }
    return palettes[0];
}

QVariantMap toMap(const Palette &p) {
    return {{"id", p.id},           {"title", p.title},         {"primary", p.primary},       {"onPrimary", p.onPrimary},
            {"background", p.background}, {"surface", p.surface}, {"textPrimary", p.textPrimary}, {"textMuted", p.textMuted},
            {"chatBackground", p.chatBackground}, {"bubbleMine", p.bubbleMine}, {"onBubbleMine", p.onBubbleMine},
            {"sentTick", p.sentTick}, {"linkOnMine", p.linkOnMine}, {"isDark", p.dark}};
}

QHash<QString, QString> loadJson(const QString &path) {
    QFile f(path);
    QHash<QString, QString> out;
    if (!f.open(QIODevice::ReadOnly)) return out;
    const QJsonObject o = QJsonDocument::fromJson(f.readAll()).object();
    for (auto it = o.begin(); it != o.end(); ++it) out.insert(it.key(), it.value().toString());
    return out;
}

/// Длинная сторона обоев — как на Android.
constexpr int WallpaperMaxSide = 1920;

/// Картинка → JPEG не больше [maxSide] и [maxBytes] (фото профиля: сервер больше 2 МБ не примет).
QByteArray toJpeg(const QString &path, int maxSide, int maxBytes) {
    QImage img(path);
    if (img.isNull()) return {};
    if (std::max(img.width(), img.height()) > maxSide) img = img.scaled(maxSide, maxSide, Qt::KeepAspectRatio, Qt::SmoothTransformation);
    for (int q = 90; q >= 40; q -= 10) {
        QByteArray out;
        QBuffer buf(&out);
        buf.open(QIODevice::WriteOnly);
        img.save(&buf, "JPEG", q);
        if (out.size() <= maxBytes) return out;
    }
    return {};
}

} // namespace

AppModel::AppModel(QObject *parent) : QObject(parent) {
#ifdef OSHINOBU_HAVE_RLOTTIE
    tgsSupported_ = true;
#endif
    const AppDirs dirs = AppDirs::standard();
    auto prefs = std::make_unique<Prefs>(std::make_unique<QSettings>());
    themeId_ = prefs->getString("ui_theme").value_or("dark");
    lang_ = prefs->getString("ui_locale").value_or(QLocale::system().language() == QLocale::Russian ? "ru" : "en");
    std::unique_ptr<RtcEngine> engine;
#ifdef OSHINOBU_HAVE_GSTREAMER
    {
        auto gst = std::make_unique<GstRtcEngine>();
        gst->setCallDebugLog(dirs.data + "/gst-call.log"); // разбор звонков: только локально
        engine = std::move(gst);
    }
#endif
    core_ = std::make_unique<Core>(dirs, std::make_unique<EncryptedFileSecureStore>(dirs.data), std::move(prefs), *this, std::move(engine));
    chats_ = std::make_unique<ChatListModel>(*core_, *this);
    messages_ = std::make_unique<MessageModel>(*core_, *this);
#ifdef OSHINOBU_HAVE_GSTREAMER
    recorder_ = std::make_unique<GstRecorder>();
#endif
    recTempDir_ = dirs.temp;
    loadStrings();
    sound_.setAudioOutput(&soundOut_);
    soundOut_.setVolume(0.6f);
    sound_.setSource(QUrl("qrc:/qt/qml/Oshinobu/sounds/msg_sound.mp3"));

    connect(&core_->chats, &ChatStore::changed, this, [this](const QString &peer) {
        chats_->reload();
        if (peer.isEmpty() || peer == openChat_) {
            messages_->reload();
            Q_EMIT openChatInfoChanged();
        }
        if (tray_) tray_->setToolTip(QStringLiteral("Oshinobu") + (chats_->totalUnread() ? QStringLiteral(" (%1)").arg(chats_->totalUnread()) : ""));
        // открытый чат на экране — новое прочитано сразу
        if (!openChat_.isEmpty() && peer == openChat_ && windowActive_) {
            if (const auto c = current(); c && c->unreadCount > 0) spawn(core_->sendReadReceipts(core_->peerOf(*c)));
        }
    });
    connect(&core_->ws, &WebSocketClient::statusChanged, this, [this](ConnectionStatus) { Q_EMIT connectionChanged(); });
    connect(&core_->ws, &WebSocketClient::presenceEvent, this, [this](const QJsonObject &frame) {
        const auto c = current();
        if (!c || frame.value("FromDeviceId").toString() != c->lastKnownDeviceId) return;
        if (frame.value("Type").toString() == "typing") {
            presence_ = t("presence_typing");
            Q_EMIT presenceChanged();
            QTimer::singleShot(4000, this, [this] {
                if (presence_ == t("presence_typing")) presence_.clear(), Q_EMIT presenceChanged();
            });
            return;
        }
        const bool online = frame.value("Online").toBool();
        const qint64 lastSeen = frame.value("LastSeenMs").toInteger();
        if (online) presence_ = t("presence_online");
        else if (lastSeen > 0) presence_ = lastSeenText(lastSeen);
        else presence_.clear();
        Q_EMIT presenceChanged();
    });
    connect(&core_->downloads, &MediaDownloadManager::progressChanged, this, [this](const QString &id, double) { messages_->refreshMedia(id); });
    connect(&core_->downloads, &MediaDownloadManager::finished, this, [this](const QString &id, const QString &) { messages_->refreshMedia(id); });
    connect(&core_->downloads, &MediaDownloadManager::queuesChanged, this, &AppModel::transfersChanged);
    connect(core_.get(), &Core::uploadProgressChanged, this, [this](const QString &id, double) {
        messages_->refreshMessage(id);
        Q_EMIT transfersChanged();
    });
    connect(&core_->stickers, &Stickers::changed, this, [this] {
        ++stickerRevision_;
        Q_EMIT stickerRevisionChanged();
        if (const QVariantList packs = stickerPacks(); packs != shownPacks_) {
            shownPacks_ = packs;
            Q_EMIT stickersChanged();
        }
        if (const QVariantList recent = recentStickers(); recent != shownRecent_) {
            shownRecent_ = recent;
            Q_EMIT recentStickersChanged();
        }
    });
    connect(&core_->avatars, &Avatars::changed, this, [this](const QString &) {
        ++avatarRevision_;
        Q_EMIT avatarsChanged();
        chats_->reload();
    });
    connect(&core_->wallpapers, &Wallpapers::changed, this, &AppModel::openChatInfoChanged);
    connect(core_.get(), &Core::myAccountChanged, this, &AppModel::accountChanged);
    connect(core_.get(), &Core::signedOut, this, [this] {
        openChat_.clear();
        messages_->setPeer({});
        chats_->reload();
        Q_EMIT openChatChanged();
        setPhase("signedOut");
    });
    recTicker_.setInterval(200);
    connect(&recTicker_, &QTimer::timeout, this, [this] {
        Q_EMIT recElapsedChanged();
        // кружок — не длиннее 5 минут (как на Android): дальше отправляется сам
        if (recKind_ == "video" && recElapsed() >= MaxVideoNoteMs) finishRecording(true);
    });
    ring_.setAudioOutput(&ringOut_);
    ring_.setLoops(QMediaPlayer::Infinite);
    connect(&core_->calls, &CallManager::changed, this, [this, lastState = CallState::Idle]() mutable {
        const CallState s = core_->calls.state();
        if (s != lastState) {
            // камеру ищем один раз на звонок: опрос устройств — заметные доли секунды
            if (lastState == CallState::Idle && core_->rtcEngine) cameraAvailable_ = core_->rtcEngine->hasCamera();
            if (s == CallState::Idle) VideoFrames::instance().clear();
            lastState = s;
        }
        updateRinging();
        Q_EMIT callChanged();
    });
    lockTimer_.setSingleShot(true);
    connect(&lockTimer_, &QTimer::timeout, this, &AppModel::lockNow);
    connect(&core_->calls, &CallManager::videoFrame, this, [](bool local, const VideoFrame &f) {
        const QImage img(reinterpret_cast<const uchar *>(f.rgba.constData()), f.width, f.height, f.width * 4, QImage::Format_RGBA8888);
        VideoFrames::instance().set(local, img.copy());
    });
    // выбранные раньше микрофон и вывод — для звонков с первого же
    if (core_->rtcEngine) {
        core_->rtcEngine->setPreferredAudioDevice(true, core_->prefs->getString("call_audio_in").value_or(QString()));
        core_->rtcEngine->setPreferredAudioDevice(false, core_->prefs->getString("call_audio_out").value_or(QString()));
    }
    connect(&core_->calls, &CallManager::incomingCall, this, [this](const QString &, const QString &login) {
        Q_EMIT raiseRequested();
        notifier_->show("call", login.isEmpty() ? t("call_otherParty") : login, t("call_incoming"));
    });
#ifdef OSHINOBU_HAVE_GSTREAMER
    connect(recorder_.get(), &GstRecorder::failed, this, [this](const QString &reason) {
        Q_EMIT error(reason);
        setRecState("idle");
    });
    connect(recorder_.get(), &GstRecorder::previewFrame, this, [](const VideoFrame &f) {
        const QImage img(reinterpret_cast<const uchar *>(f.rgba.constData()), f.width, f.height, f.width * 4, QImage::Format_RGBA8888);
        VideoFrames::instance().set(true, img.copy());
    });
    connect(recorder_.get(), &GstRecorder::finished, this, [this](const QString &file, qint64 duration, const VideoFrame &first) {
        const bool video = file.endsWith(".mp4");
        const auto c = recPeer_.isEmpty() ? std::nullopt : core_->chats.peer(recPeer_);
        // случайное касание (короче 0,7 с, как на Android) не отправляем
        if (!c || duration < MinRecordingMs || !QFile::exists(file) || QFileInfo(file).size() == 0) {
            QFile::remove(file);
            return;
        }
        QString preview;
        if (video && !first.rgba.isEmpty()) {
            preview = file.left(file.size() - 4) + "_preview.jpg";
            QImage(reinterpret_cast<const uchar *>(first.rgba.constData()), first.width, first.height, first.width * 4, QImage::Format_RGBA8888)
                .save(preview, "JPEG", 85);
        }
        spawn(core_->sendRecorded(core_->peerOf(*c), file, duration, video, preview));
    });
#endif

    notifier_ = new Notifier(this);
    connect(notifier_, &Notifier::activated, this, [this](const QString &peer) {
        Q_EMIT raiseRequested();
        if (core_->chats.peer(peer)) openChatWith(peer);
    });
    if (QSystemTrayIcon::isSystemTrayAvailable()) {
        tray_ = new QSystemTrayIcon(QIcon(":/qt/qml/Oshinobu/icons/oshinobu.png"), this);
        tray_->setToolTip("Oshinobu");
        connect(tray_, &QSystemTrayIcon::activated, this, [this] { Q_EMIT raiseRequested(); });
        tray_->show();
    }
}

AppModel::~AppModel() = default;

void AppModel::loadStrings() {
    // строки Android + свои строки Linux-клиента (их нет в strings.xml)
    strings_ = loadJson(QStringLiteral(":/qt/qml/Oshinobu/i18n/%1.json").arg(lang_));
    strings_.insert(loadJson(QStringLiteral(":/qt/qml/Oshinobu/i18n/linux_%1.json").arg(lang_)));
    fallback_ = loadJson(QStringLiteral(":/qt/qml/Oshinobu/i18n/en.json"));
    fallback_.insert(loadJson(QStringLiteral(":/qt/qml/Oshinobu/i18n/linux_en.json")));
}

// ---------------- свойства ----------------

QString AppModel::connection() const {
    switch (core_->ws.status()) {
    case ConnectionStatus::Connected: return "connected";
    case ConnectionStatus::Connecting: return "connecting";
    case ConnectionStatus::Reconnecting: return "reconnecting";
    case ConnectionStatus::WaitingForNetwork: return "waitingForNetwork";
    }
    return {};
}

QVariantMap AppModel::theme() const { return toMap(paletteById(themeId_)); }
QStringList AppModel::themeIds() const {
    QStringList ids;
    for (const auto &p : palettes) ids << p.id;
    return ids;
}
QVariantMap AppModel::themeColors(const QString &id) const { return toMap(paletteById(id)); }

QString AppModel::myLogin() const { return core_->session.login().value_or(QString()); }
QString AppModel::myAccountId() const { return core_->session.accountId().value_or(QString()); }

QVariantMap AppModel::myAccount() const {
    const auto me = core_->myAccount();
    if (!me) return {{"login", myLogin()}};
    return {{"login", me->login},
            {"displayName", me->displayName.value_or(QString())},
            {"status", me->status.value_or(QString())},
            {"birthday", me->birthday.value_or(QString())},
            {"email", me->email.value_or(QString())},
            {"findByLogin", me->findByLoginVisibility},
            {"avatarVisibility", me->avatarVisibility},
            {"birthdayVisibility", me->birthdayVisibility},
            {"statusVisibility", me->statusVisibility}};
}

QString AppModel::myAvatar() { return avatarFor(myAccountId()); }

QString AppModel::avatarFor(const QString &accountId) {
    if (accountId.isEmpty()) return {};
    const QString path = core_->avatars.pathFor(accountId);
    return path.isEmpty() ? QString() : QUrl::fromLocalFile(path).toString() + "?r=" + QString::number(avatarRevision_);
}

QString AppModel::stickerUrl(const QString &stickerId, int revision) {
    Q_UNUSED(revision)
    if (const auto f = core_->stickers.cachedFile(stickerId)) return QUrl::fromLocalFile(*f).toString();
    if (!stickerLoading_.contains(stickerId)) {
        stickerLoading_.insert(stickerId);
        spawn([](AppModel *self, QString id) -> Task<void> {
            co_await self->core_->stickers.resolve(id);
            self->stickerLoading_.remove(id);
        }(this, stickerId));
    }
    return {};
}

std::optional<ChatSummary> AppModel::current() const { return openChat_.isEmpty() ? std::nullopt : core_->chats.peer(openChat_); }

QVariantMap AppModel::openChatInfo() const {
    const auto c = current();
    if (!c) return {};
    QVariantMap pinned;
    if (c->pinnedMessageId) {
        if (const auto m = core_->chats.message(c->peerLogin, *c->pinnedMessageId)) {
            pinned = {{"id", m->messageId}, {"text", m->text.isEmpty() ? decodePreview(ChatStore::previewMarker(*m)) : m->text}};
        }
    }
    return {{"login", c->peerLogin},     {"accountId", c->lastKnownAccountId.value_or(QString())},
            {"muted", c->muted},         {"blockedByMe", c->blockedByMe},
            {"blockingMe", c->blockingMe}, {"deleted", c->isDeleted},
            {"pinned", pinned},          {"chatPinned", c->chatPinnedAt.has_value()},
            {"hasDevice", c->lastKnownDeviceId.has_value()}};
}

QString AppModel::wallpaper() const {
    const auto c = current();
    if (!c || !c->lastKnownAccountId || !core_->wallpapers.has(*c->lastKnownAccountId)) return {};
    // ?r= — время изменения файла, а не «сейчас»: иначе каждое сообщение в чате давало новый адрес,
    // фон перезагружался и всё окно моргало (например, на отправку стикера)
    const QString file = core_->wallpapers.file(*c->lastKnownAccountId);
    return QUrl::fromLocalFile(file).toString() + "?r=" + QString::number(QFileInfo(file).lastModified().toMSecsSinceEpoch());
}

QVariantList AppModel::stickerPacks() const {
    QVariantList out;
    for (const auto &p : core_->stickers.installed()) {
        QVariantList stickers;
        for (const auto &s : p.stickers) stickers << QVariantMap{{"id", s.id}, {"format", s.format}, {"packId", s.packId}};
        out << QVariantMap{{"id", p.id}, {"title", p.title}, {"owner", p.isOwner}, {"stickers", stickers}};
    }
    return out;
}

QVariantList AppModel::recentStickers() const {
    QVariantList out;
    for (const auto &s : core_->stickers.recent()) out << QVariantMap{{"id", s.id}, {"format", s.format}, {"packId", s.packId}};
    return out;
}

int AppModel::recElapsed() const {
#ifdef OSHINOBU_HAVE_GSTREAMER
    if (recorder_) return int(recorder_->elapsedMs());
#endif
    return 0;
}

QVariantMap AppModel::appLock() const {
    const AppLockSettings s = core_->appLock.load();
    return {{"enabled", s.enabled}, {"timeout", s.timeoutSeconds}, {"hasPin", s.hasPin}, {"pinLength", s.pinLength}};
}

QVariantList AppModel::transfers() const {
    QVariantList out;
    for (const auto &[login, m] : core_->chats.sendingMessages()) {
        out << QVariantMap{{"kind", "upload"},
                           {"id", m.messageId},
                           {"peer", login},
                           {"label", m.isMedia ? m.fileName.value_or(t(m.isVoice ? "media_voiceNote" : "media_file")) : t("transfers_textMessage")},
                           {"progress", core_->uploadProgress(m.messageId).value_or(-1)}};
    }
    for (const auto &spec : core_->downloads.manualQueue() + core_->downloads.autoQueue()) {
        out << QVariantMap{{"kind", "download"},
                           {"id", spec.mediaId},
                           {"peer", spec.peerLogin},
                           {"label", spec.fileName.value_or(t("transfers_download"))},
                           {"progress", core_->downloads.progress(spec.mediaId).value_or(-1)}};
    }
    return out;
}

// ---------------- строки ----------------

QString AppModel::t(const QString &key, const QVariantList &args) const {
    QString s = strings_.value(key);
    if (s.isEmpty()) s = fallback_.value(key, key);
    for (int i = 0; i < args.size(); ++i) s.replace(QStringLiteral("%%1").arg(i + 1), args[i].toString());
    return s;
}

QString AppModel::errorText(const QString &key) const { return t(QString(key).replace('.', '_')); }

QString AppModel::decodePreview(const QString &raw) const {
    return ChatStore::decodePreview(raw, [this](const QString &k) { return t(QString(k).replace('.', '_')); });
}

QString AppModel::formatSize(qint64 bytes) const {
    if (bytes < 1024) return QStringLiteral("%1 %2").arg(bytes).arg(t("unit_bytes"));
    if (bytes < 1024 * 1024) return QStringLiteral("%1 %2").arg(bytes / 1024.0, 0, 'f', 1).arg(t("unit_kb"));
    if (bytes < 1024LL * 1024 * 1024) return QStringLiteral("%1 %2").arg(bytes / 1048576.0, 0, 'f', 1).arg(t("unit_mb"));
    return QStringLiteral("%1 %2").arg(bytes / 1073741824.0, 0, 'f', 2).arg(t("unit_gb"));
}

QString AppModel::formatTime(qint64 ms) const { return QDateTime::fromMSecsSinceEpoch(ms).toString("HH:mm"); }

QString AppModel::formatDay(qint64 ms) const {
    const QDateTime t = QDateTime::fromMSecsSinceEpoch(ms);
    const QDate today = QDate::currentDate();
    if (t.date() == today) return formatTime(ms);
    const QLocale loc(lang_ == "ru" ? QLocale::Russian : QLocale::English);
    if (t.date().year() == today.year()) return loc.toString(t.date(), "d MMM");
    return loc.toString(t.date(), "dd.MM.yyyy");
}

QString AppModel::lastSeenText(qint64 ms) const {
    const qint64 ago = QDateTime::currentMSecsSinceEpoch() - ms;
    if (ago < 60000) return t("presence_justNow");
    if (ago < 3600000) return QString::number(ago / 60000) + " " + t("presence_minutesAgoSuffix");
    const QDate day = QDateTime::fromMSecsSinceEpoch(ms).date();
    if (day == QDate::currentDate()) return formatTime(ms);
    if (day == QDate::currentDate().addDays(-1)) return t("presence_yesterdayAt") + " " + formatTime(ms);
    return formatDay(ms) + " " + formatTime(ms);
}

// ---------------- общая обвязка ----------------

void AppModel::setPhase(const QString &p) {
    if (phase_ == p) return;
    phase_ = p;
    Q_EMIT phaseChanged();
    Q_EMIT accountChanged();
}

void AppModel::setBusy(bool b) {
    if (busy_ == b) return;
    busy_ = b;
    Q_EMIT busyChanged();
}

void AppModel::fail(std::exception_ptr e) {
    try {
        std::rethrow_exception(e);
    } catch (const ApiError &err) {
        Q_EMIT error(errorText(err.key));
    } catch (const StickerUploadError &err) {
        // "archive.tooLarge" → sticker_err_archiveTooLarge (как StickerDialogs.kt)
        const QStringList parts = err.code.split('.');
        QString key = parts.value(0);
        for (int i = 1; i < parts.size(); ++i) key += parts[i].left(1).toUpper() + parts[i].mid(1);
        const QString limit = err.limit ? QString::number(*err.limit) : QStringLiteral("50");
        QString text = t("sticker_err_" + key, {limit});
        if (text.startsWith("sticker_err_")) text = t("sticker_err_server");
        Q_EMIT error(err.fileName ? *err.fileName + ": " + text : text);
    } catch (const std::exception &err) {
        logError(QStringLiteral("UI operation failed: %1").arg(QString::fromUtf8(err.what())));
        Q_EMIT error(t("error_network"));
    }
}

void AppModel::runOp(Task<void> task, std::function<void()> onDone) {
    setBusy(true);
    spawn([](AppModel *self, Task<void> t, std::function<void()> done) -> Task<void> {
        std::exception_ptr err;
        try {
            co_await t;
        } catch (...) {
            err = std::current_exception();
        }
        self->setBusy(false);
        if (err) self->fail(err);
        else if (done) done();
    }(this, std::move(task), std::move(onDone)));
}

void AppModel::playMessageSound() {
    sound_.setPosition(0);
    sound_.play();
}

void AppModel::showMessageNotification(const QString &peerLogin, const QString &preview) {
    // как на Android: без текста сообщения — только от кого
    Q_UNUSED(preview)
    notifier_->show(peerLogin, peerLogin, t("push_newMessageBody"));
}

// ---------------- вход ----------------

void AppModel::launch() {
    // сохранённая сессия есть — чаты сразу (история локальная), проверка сессии — в фоне;
    // сервер её не признал — тогда экран входа
    const bool saved = core_->session.token() && core_->keys.deviceId();
    const AppLockSettings lock = core_->appLock.load();
    if (saved) {
        chats_->reload();
        if (lock.enabled && lock.hasPin) {
            locked_ = true;
            Q_EMIT lockedChanged();
        }
        setPhase("signedIn");
    }
    spawn([](AppModel *self) -> Task<void> {
        const bool resumed = co_await self->core_->resumeSession();
        self->chats_->reload();
        self->setPhase(resumed ? "signedIn" : "signedOut");
    }(this));
}

void AppModel::login(const QString &login, const QString &password, const QString &totp) {
    runOp(core_->login(login.trimmed(), password, totp.trimmed()), [this] {
        chats_->reload();
        setPhase("signedIn");
    });
}

void AppModel::registerAccount(const QString &login, const QString &password, const QString &invite) {
    setBusy(true);
    spawn([](AppModel *self, QString l, QString p, QString i) -> Task<void> {
        try {
            const QString url = co_await self->core_->registerAccount(l, p, i);
            self->setBusy(false);
            Q_EMIT self->totpReady(url, QUrlQuery(QUrl(url).query()).queryItemValue("secret"));
        } catch (...) {
            self->setBusy(false);
            self->fail(std::current_exception());
        }
    }(this, login.trimmed(), password, invite.trimmed()));
}

void AppModel::confirmTotp(const QString &login, const QString &password, const QString &code) {
    // сброс аутентификатора по коду из письма: пароль не меняли — только подтвердить новый ключ и войти обычным путём
    if (password.isEmpty()) {
        runOp(core_->api.verifyTotp(login.trimmed(), code.trimmed()), [this] {
            Q_EMIT info(t("recovery_success"));
            Q_EMIT totpVerified();
        });
        return;
    }
    runOp([](Core &core, QString l, QString p, QString c) -> Task<void> {
        co_await core.api.verifyTotp(l, c);
        co_await core.login(l, p, c);
    }(*core_, login.trimmed(), password, code.trimmed()),
          [this] {
              chats_->reload();
              setPhase("signedIn");
          });
}

void AppModel::requestRecovery(const QString &login) {
    runOp(core_->api.requestPasswordRecovery(login.trimmed()), [this] { Q_EMIT recoveryCodeSent(); });
}

void AppModel::resetPassword(const QString &login, const QString &code, const QString &newPassword) {
    runOp(core_->api.resetPasswordWithRecoveryCode(login.trimmed(), code.trimmed(), newPassword), [this] { Q_EMIT recoveryDone({}); });
}

void AppModel::resetTotp(const QString &login, const QString &code) {
    setBusy(true);
    spawn([](AppModel *self, QString l, QString c) -> Task<void> {
        try {
            const QString url = co_await self->core_->api.resetTotpWithRecoveryCode(l, c);
            self->setBusy(false);
            Q_EMIT self->recoveryDone(url);
            Q_EMIT self->totpReady(url, QUrlQuery(QUrl(url).query()).queryItemValue("secret"));
        } catch (...) {
            self->setBusy(false);
            self->fail(std::current_exception());
        }
    }(this, login.trimmed(), code.trimmed()));
}

void AppModel::logout() { runOp(core_->logout()); }

void AppModel::quit() { QCoreApplication::quit(); }

void AppModel::deleteAccount() {
    spawn([](AppModel *self) -> Task<void> {
        if (!(co_await self->core_->deleteAccount())) Q_EMIT self->error(self->t("account_deleteOfflineError"));
    }(this));
}

// ---------------- настройки ----------------

void AppModel::setTheme(const QString &id) {
    themeId_ = paletteById(id).id;
    core_->prefs->setString("ui_theme", themeId_);
    Q_EMIT themeChanged();
}

void AppModel::setLanguage(const QString &lang) {
    lang_ = lang == "ru" ? "ru" : "en";
    core_->prefs->setString("ui_locale", lang_);
    loadStrings();
    Q_EMIT langChanged();
    chats_->reload();
    messages_->reload();
    if (const auto token = core_->session.token()) spawn(core_->api.updateLanguage(*token, lang_), [](std::exception_ptr) {});
}

void AppModel::lockNow() {
    lockTimer_.stop();
    if (locked_) return;
    locked_ = true;
    Q_EMIT lockedChanged();
}

void AppModel::setWindowActive(bool active) {
    if (windowActive_ == active) return;
    windowActive_ = active;
    core_->ws.sendForegroundState(active);
    const AppLockSettings lock = core_->appLock.load();
    if (active) {
        lockTimer_.stop();
        // запасная проверка: таймер мог не сработать, пока система спала
        if (lock.enabled && lock.hasPin && hiddenAt_ > 0 && QDateTime::currentMSecsSinceEpoch() - hiddenAt_ > lock.timeoutSeconds * 1000LL) lockNow();
        if (const auto c = current()) spawn(core_->sendReadReceipts(core_->peerOf(*c)));
    } else {
        hiddenAt_ = QDateTime::currentMSecsSinceEpoch();
        if (lock.enabled && lock.hasPin && !locked_) lockTimer_.start(std::chrono::seconds(lock.timeoutSeconds));
    }
}

void AppModel::updateDisplayName(const QString &name) {
    runOp([](Core &c, QString n) -> Task<void> {
        co_await c.api.updateDisplayName(c.session.token().value_or(QString()), n);
        co_await c.reloadMyAccount();
    }(*core_, name.trimmed()));
}

void AppModel::updateStatus(const QString &status) {
    runOp([](Core &c, QString s) -> Task<void> {
        co_await c.api.updateStatus(c.session.token().value_or(QString()), s);
        co_await c.reloadMyAccount();
    }(*core_, status.trimmed()));
}

void AppModel::updateBirthday(const QString &birthday) {
    runOp([](Core &c, QString b) -> Task<void> {
        const std::optional<QString> birthday = b.isEmpty() ? std::nullopt : std::optional(b);
        co_await c.api.updateBirthday(c.session.token().value_or(QString()), birthday);
        co_await c.reloadMyAccount();
    }(*core_, birthday));
}

void AppModel::updatePrivacy(int findByLogin, int avatar, int birthday, int status) {
    runOp([](Core &c, PrivacySettings p) -> Task<void> {
        co_await c.api.updatePrivacy(c.session.token().value_or(QString()), p);
        co_await c.reloadMyAccount();
    }(*core_, PrivacySettings{findByLogin, avatar, birthday, status}),
          [this] { Q_EMIT info(t("privacy_saved")); });
}

void AppModel::changePassword(const QString &password) {
    runOp(core_->api.changePassword(core_->session.token().value_or(QString()), password), [this] { Q_EMIT info(t("changePassword_success")); });
}

void AppModel::requestEmailCode(const QString &email) {
    runOp(core_->api.requestEmailVerification(core_->session.token().value_or(QString()), email.trimmed()), [this] { Q_EMIT emailCodeSent(); });
}

void AppModel::confirmEmailCode(const QString &code) {
    runOp([](Core &c, QString code) -> Task<void> {
        co_await c.api.confirmEmailVerification(c.session.token().value_or(QString()), code);
        co_await c.reloadMyAccount();
    }(*core_, code.trimmed()),
          [this] { Q_EMIT info(t("email_saved")); });
}

void AppModel::setAvatar(const QUrl &file) {
    const QByteArray jpeg = toJpeg(file.toLocalFile(), 1024, 2 * 1024 * 1024);
    if (jpeg.isEmpty()) {
        Q_EMIT error(t("settings_avatarUploadFailed"));
        return;
    }
    runOp(core_->avatars.uploadMine(jpeg));
}

void AppModel::removeAvatar() { runOp(core_->avatars.deleteMine()); }

void AppModel::clearCache() {
    const qint64 freed = core_->media.cacheSize();
    core_->media.clearCache();
    core_->stickers.clearCache();
    Q_EMIT info(freed > 0 ? t("settings_cacheCleared", {formatSize(freed)}) : t("settings_cacheEmpty"));
}

void AppModel::setPin(const QString &pin) {
    core_->appLock.setPin(pin);
    core_->appLock.setEnabled(true);
    Q_EMIT appLockChanged();
}

void AppModel::removePin() {
    core_->appLock.removePin();
    Q_EMIT appLockChanged();
}

void AppModel::setLockEnabled(bool on) {
    core_->appLock.setEnabled(on);
    Q_EMIT appLockChanged();
}

void AppModel::setLockTimeout(int seconds) {
    core_->appLock.setTimeoutSeconds(seconds);
    Q_EMIT appLockChanged();
}

bool AppModel::unlock(const QString &pin) {
    if (!core_->appLock.verifyPin(pin)) return false;
    locked_ = false;
    Q_EMIT lockedChanged();
    return true;
}

// ---------------- чаты ----------------

void AppModel::subscribeToChat() {
    if (!subscribedDevice_.isEmpty()) core_->ws.unsubscribePresence(subscribedDevice_);
    subscribedDevice_.clear();
    presence_.clear();
    Q_EMIT presenceChanged();
    if (const auto c = current(); c && c->lastKnownDeviceId) {
        subscribedDevice_ = *c->lastKnownDeviceId;
        core_->ws.subscribePresence(subscribedDevice_);
    }
}

void AppModel::openChatWith(const QString &login) {
    openChat_ = login;
    messages_->setPeer(login);
    Q_EMIT openChatChanged();
    Q_EMIT openChatInfoChanged();
    subscribeToChat();
    spawn([](AppModel *self, QString l) -> Task<void> {
        co_await self->core_->refreshPeer(l);
        if (self->openChat_ != l) co_return;
        self->subscribeToChat();
        if (const auto c = self->current()) co_await self->core_->sendReadReceipts(self->core_->peerOf(*c));
    }(this, login));
}

void AppModel::findAndOpen(const QString &login) {
    setBusy(true);
    spawn([](AppModel *self, QString l) -> Task<void> {
        try {
            const ChatSummary c = co_await self->core_->openChat(l);
            self->setBusy(false);
            self->chats_->reload();
            self->openChatWith(c.peerLogin);
        } catch (...) {
            self->setBusy(false);
            self->fail(std::current_exception());
        }
    }(this, login.trimmed()));
}

void AppModel::lookupLogin(const QString &login) {
    const QString q = login.trimmed();
    if (q.isEmpty()) return;
    spawn([](AppModel *self, QString query) -> Task<void> {
        try {
            const AccountDevices d = co_await self->core_->api.getDevicesByLogin(self->core_->session.token().value_or(QString()), query);
            Q_EMIT self->searchResult(query, !d.devices.isEmpty(), query, d.accountId);
        } catch (const ApiError &e) {
            // нет связи — не говорим «не найден»
            if (e.key == "error.userNotFound") Q_EMIT self->searchResult(query, false, query, {});
        } catch (const std::exception &) {
        }
    }(this, q));
}

QVariantList AppModel::emojiCategories() const {
    static const QVariantList cached = [] {
        QFile f(":/qt/qml/Oshinobu/emoji.json");
        return f.open(QIODevice::ReadOnly) ? QJsonDocument::fromJson(f.readAll()).array().toVariantList() : QVariantList();
    }();
    return cached;
}

void AppModel::closeChat() {
    if (!subscribedDevice_.isEmpty()) core_->ws.unsubscribePresence(subscribedDevice_);
    subscribedDevice_.clear();
    openChat_.clear();
    messages_->setPeer({});
    Q_EMIT openChatChanged();
}

void AppModel::sendText(const QString &text, const QString &replyToId) {
    const auto c = current();
    if (!c || text.trimmed().isEmpty()) return;
    spawn(core_->sendText(core_->peerOf(*c), text.trimmed(), replyToId.isEmpty() ? std::nullopt : messages_->find(replyToId)));
}

void AppModel::sendFiles(const QList<QUrl> &files, const QString &caption) {
    const auto c = current();
    if (!c || files.isEmpty()) return;
    QMimeDatabase mime;
    QList<OutgoingFile> list;
    for (const QUrl &u : files) {
        const QString path = u.toLocalFile();
        const QString type = mime.mimeTypeForFile(path).name();
        const bool image = type.startsWith("image/") && !type.contains("svg") && !type.contains("gif");
        const bool video = type == "video/mp4";
        list << OutgoingFile{path, !image && !video, video, QFileInfo(path).fileName()};
    }
    spawn([](AppModel *self, ChatPeer peer, QList<OutgoingFile> l, QString cap) -> Task<void> {
        const QList<OutgoingFile> rejected = co_await self->core_->sendMedia(peer, l, cap);
        if (!rejected.isEmpty()) Q_EMIT self->error(self->t("chat_fileTooLarge"));
    }(this, core_->peerOf(*c), list, caption));
}

void AppModel::sendSticker(const QString &stickerId, const QString &packId, const QString &format) {
    const auto c = current();
    if (!c) return;
    spawn(core_->sendSticker(core_->peerOf(*c), StickerInfo{stickerId, format, packId}));
}

void AppModel::retry(const QString &messageId) {
    const auto c = current();
    const auto m = messages_->find(messageId);
    if (c && m) spawn(core_->retry(core_->peerOf(*c), *m));
}

void AppModel::cancelSend(const QString &messageId) {
    if (!openChat_.isEmpty()) core_->cancelOutgoing(openChat_, {messageId});
}

void AppModel::editMessage(const QString &messageId, const QString &text) {
    if (const auto c = current(); c && !text.trimmed().isEmpty()) spawn(core_->editText(core_->peerOf(*c), messageId, text.trimmed()));
}

void AppModel::react(const QString &messageId, const QString &emoji) {
    const auto c = current();
    const auto m = messages_->find(messageId);
    if (!c || !m) return;
    // та же реакция ещё раз — снять
    const std::optional<QString> next = m->myReaction == emoji ? std::nullopt : std::optional(emoji);
    spawn(core_->react(core_->peerOf(*c), messageId, next));
}

void AppModel::pinMessage(const QString &messageId, bool pinned) {
    if (const auto c = current()) spawn(core_->setPinned(core_->peerOf(*c), messageId, pinned));
}

void AppModel::deleteMessages(const QStringList &ids, bool forPeer) {
    if (const auto c = current()) spawn(core_->deleteMessages(core_->peerOf(*c), ids, forPeer));
}

void AppModel::forwardText(const QString &text, const QString &toLogin) {
    if (const auto c = core_->chats.peer(toLogin)) spawn(core_->forwardText(core_->peerOf(*c), text));
}

void AppModel::copyText(const QString &text) {
    QGuiApplication::clipboard()->setText(text);
    Q_EMIT info(t("common_copied"));
}

void AppModel::clearHistory(bool forPeer) {
    if (const auto c = current()) spawn(core_->clearOrDelete(*c, false, forPeer));
}

void AppModel::deleteChat(const QString &login, bool forPeer) {
    const auto c = core_->chats.peer(login);
    if (!c) return;
    if (openChat_ == login) closeChat();
    spawn(core_->clearOrDelete(*c, true, forPeer));
}

void AppModel::setMuted(const QString &login, bool muted) {
    if (const auto c = core_->chats.peer(login)) spawn(core_->setMuted(*c, muted));
}

void AppModel::setBlocked(const QString &login, bool blocked) {
    if (const auto c = core_->chats.peer(login)) runOp(core_->setBlocked(*c, blocked));
}

void AppModel::setChatPinned(const QString &login, bool pinned) { core_->chats.setChatPinned(login, pinned); }

void AppModel::resetSession() {
    if (const auto c = current()) runOp(core_->resetSession(core_->peerOf(*c)), [this] { Q_EMIT info(t("chat_resetSessionDone")); });
}

void AppModel::typing() {
    const auto c = current();
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (!c || !c->lastKnownDeviceId || now - lastTypingSent_ < 3000) return;
    lastTypingSent_ = now;
    core_->ws.sendTyping(*c->lastKnownDeviceId);
}

void AppModel::downloadMedia(const QString &messageId) {
    const auto m = messages_->find(messageId);
    if (!m) return;
    if (const auto spec = DownloadSpec::of(*m, openChat_)) {
        if (spec->plaintextSize < MediaDownloadManager::AutoDownloadLimitBytes && !m->isFile) core_->downloads.requestAutoDownload(*spec);
        else core_->downloads.requestUserDownload(*spec);
    }
}

void AppModel::openMedia(const QString &messageId) {
    const auto m = messages_->find(messageId);
    if (!m) return;
    if (m->localSourcePath && QFile::exists(*m->localSourcePath)) {
        QDesktopServices::openUrl(QUrl::fromLocalFile(*m->localSourcePath));
        return;
    }
    const auto spec = DownloadSpec::of(*m, openChat_);
    if (!spec) return;
    spawn([](AppModel *self, DownloadSpec s, std::optional<QString> name) -> Task<void> {
        try {
            const QString path = co_await self->core_->downloads.ensureDownloaded(s);
            // системное приложение узнаёт тип по расширению — копия с настоящим именем во временной папке
            QString open = path;
            if (name && !name->isEmpty()) {
                open = self->core_->dirs.temp + "/" + QFileInfo(*name).fileName();
                QFile::remove(open);
                QFile::copy(path, open);
            }
            QDesktopServices::openUrl(QUrl::fromLocalFile(open));
        } catch (...) {
            self->fail(std::current_exception());
        }
    }(this, *spec, m->fileName));
}

void AppModel::saveMedia(const QString &messageId, const QUrl &target) {
    const auto m = messages_->find(messageId);
    if (!m) return;
    const auto spec = DownloadSpec::of(*m, openChat_);
    if (!spec) return;
    spawn([](AppModel *self, DownloadSpec s, QString to) -> Task<void> {
        try {
            const QString path = co_await self->core_->downloads.ensureDownloaded(s);
            QFile::remove(to);
            if (!QFile::copy(path, to)) throw std::runtime_error("copy failed");
            Q_EMIT self->info(self->t("chat_savedToDevice"));
        } catch (...) {
            Q_EMIT self->error(self->t("chat_saveToDeviceFailed"));
        }
    }(this, *spec, target.toLocalFile()));
}

void AppModel::setWallpaper(const QUrl &file, bool forPeer, qreal x, qreal y, qreal w, qreal h) {
    const auto c = current();
    if (!c || !c->lastKnownAccountId) {
        Q_EMIT wallpaperDone(false);
        return;
    }
    spawn([](AppModel *self, QString peer, QString path, bool both, QRectF crop) -> Task<void> {
        // обрезка и JPEG — в пуле потоков: большая картинка декодируется заметное время
        auto encode = [path, crop]() -> QByteArray {
            QImage img(path);
            if (img.isNull()) return {};
            const QRect r = QRectF(crop.x() * img.width(), crop.y() * img.height(), crop.width() * img.width(), crop.height() * img.height())
                                .toAlignedRect()
                                .intersected(img.rect());
            if (!r.isEmpty()) img = img.copy(r);
            if (std::max(img.width(), img.height()) > WallpaperMaxSide) {
                img = img.scaled(WallpaperMaxSide, WallpaperMaxSide, Qt::KeepAspectRatio, Qt::SmoothTransformation);
            }
            QByteArray out;
            QBuffer buf(&out);
            buf.open(QIODevice::WriteOnly);
            img.save(&buf, "JPEG", 85); // как на Android: 1920 по длинной стороне, качество 85 — сотни КБ
            return out;
        };
        const QByteArray jpeg = co_await runInThread(std::move(encode));
        if (jpeg.isEmpty()) {
            Q_EMIT self->error(self->t("error_wallpaperFailed"));
            Q_EMIT self->wallpaperDone(false);
            co_return;
        }
        bool ok = true;
        try {
            co_await self->core_->wallpapers.set(peer, jpeg, both);
        } catch (const std::exception &e) {
            logError(QStringLiteral("Wallpaper: set failed: %1").arg(QString::fromUtf8(e.what())));
            ok = false;
        }
        if (!ok) Q_EMIT self->error(self->t("error_wallpaperFailed"));
        Q_EMIT self->wallpaperDone(ok);
    }(this, *c->lastKnownAccountId, file.toLocalFile(), forPeer, QRectF(x, y, w, h)));
}

void AppModel::removeWallpaper() {
    if (const auto c = current(); c && c->lastKnownAccountId) runOp(core_->wallpapers.remove(*c->lastKnownAccountId));
}

QVariantMap AppModel::profileOf(const QString &login) { return profiles_.value(login); }

void AppModel::loadProfile(const QString &login) {
    spawn([](AppModel *self, QString l) -> Task<void> {
        try {
            const auto p = co_await self->core_->api.getAccountProfile(self->core_->session.token().value_or(QString()), l);
            if (!p) co_return;
            self->profiles_[l] = QVariantMap{{"login", p->login},
                                             {"displayName", p->displayName},
                                             {"status", p->status.value_or(QString())},
                                             {"birthday", p->birthday.value_or(QString())},
                                             {"accountId", p->accountId}};
            Q_EMIT self->profileLoaded(l);
        } catch (const std::exception &) {
        }
    }(this, login));
}

void AppModel::setRecState(const QString &state) {
    if (recState_ == state) return;
    recState_ = state;
    if (state == "idle") {
        recTicker_.stop();
        recKind_.clear();
        VideoFrames::instance().set(true, {});
    }
    Q_EMIT recordingChanged();
    Q_EMIT recElapsedChanged();
}

void AppModel::toggleRecordMode() {
    if (recState_ != "idle") return;
    recordMode_ = recordMode_ == "voice" ? QStringLiteral("video") : QStringLiteral("voice");
    Q_EMIT recordingChanged();
}

void AppModel::beginRecording() {
#ifdef OSHINOBU_HAVE_GSTREAMER
    if (!recorder_ || recState_ != "idle" || openChat_.isEmpty() || core_->calls.state() != CallState::Idle) return;
    const bool video = recordMode_ == "video";
    const QString file = recTempDir_ + "/rec_" + QUuid::createUuid().toString(QUuid::WithoutBraces) + (video ? ".mp4" : ".m4a");
    QDir().mkpath(recTempDir_);
    const QString mic = core_->prefs->getString("call_audio_in").value_or(QString());
    if (!recorder_->start(video ? GstRecorder::Kind::VideoNote : GstRecorder::Kind::Voice, file, mic,
                          qEnvironmentVariableIntValue("OSHINOBU_TEST_VIDEO") == 1)) {
        return;
    }
    recPeer_ = openChat_;
    recKind_ = video ? QStringLiteral("video") : QStringLiteral("voice");
    recTicker_.start();
    setRecState("holding");
#endif
}

void AppModel::lockRecording() {
    if (recState_ == "holding") setRecState("locked");
}

void AppModel::finishRecording(bool send) {
#ifdef OSHINOBU_HAVE_GSTREAMER
    if (recState_ == "idle" || !recorder_) return;
    recorder_->stop(send);
#else
    Q_UNUSED(send)
#endif
    setRecState("idle");
}

void AppModel::showStickerPack(const QString &stickerId) {
    auto shown = [this](const StickerPackInfo &pack) {
        QVariantList stickers;
        for (const StickerInfo &s : pack.stickers) stickers << QVariantMap{{"id", s.id}, {"format", s.format}, {"packId", pack.id}};
        const auto &mine = core_->stickers.installed();
        const bool installed = std::any_of(mine.begin(), mine.end(), [&](const StickerPackInfo &p) { return p.id == pack.id; });
        return QVariantMap{{"id", pack.id}, {"title", pack.title}, {"installed", installed}, {"deleted", pack.deleted}, {"stickers", stickers}};
    };
    // пак уже известен (стикеры скачаны) — сразу, без сети и без индикатора загрузки
    if (const auto cached = core_->stickers.cachedPackOf(stickerId)) {
        Q_EMIT stickerPackShown(shown(*cached));
        return;
    }
    spawn([](AppModel *self, QString id, std::function<QVariantMap(const StickerPackInfo &)> toMap) -> Task<void> {
        std::optional<StickerPackInfo> pack;
        try {
            pack = co_await self->core_->stickers.fetchPackOf(id);
        } catch (const std::exception &e) {
            logError(QStringLiteral("Stickers: pack of %1 failed: %2").arg(id, QString::fromUtf8(e.what())));
        }
        Q_EMIT self->stickerPackShown(pack ? toMap(*pack) : QVariantMap());
    }(this, stickerId, shown));
}

void AppModel::installStickerPack(const QString &packId) {
    runOp([](Core &c, QString id) -> Task<void> {
        const auto pack = co_await c.api.getStickerPack(c.session.token().value_or(QString()), id);
        if (pack) co_await c.stickers.install(*pack);
    }(*core_, packId));
}

void AppModel::removeStickerPack(const QString &packId) { runOp(core_->stickers.uninstall(packId)); }

void AppModel::uploadStickerPack(const QString &title, const QUrl &zip) {
    runOp([](AppModel *self, QString t, QString path) -> Task<void> {
        const ProgressFn onProgress = [self](double pct) {
            Q_EMIT self->stickerUploadProgress(self->t("sticker_uploadSending") + QStringLiteral(" %1%").arg(int(pct)));
        };
        const std::function<void(const StickerUploadEvent &)> onEvent = [self](const StickerUploadEvent &e) {
            const QString stage = "sticker_stage" + e.stage.left(1).toUpper() + e.stage.mid(1);
            Q_EMIT self->stickerUploadProgress(self->t(stage));
        };
        co_await self->core_->stickers.upload(t, path, onProgress, onEvent);
    }(this, title.trimmed(), zip.toLocalFile()),
          [this] { Q_EMIT stickerUploadDone(); });
}

QVariantMap AppModel::call() const {
    const CallManager &c = core_->calls;
    const char *state = c.state() == CallState::Idle ? "idle" : c.state() == CallState::OutgoingRinging ? "outgoing"
                      : c.state() == CallState::IncomingRinging ? "incoming" : "connected";
    const auto peer = c.peer();
    return {{"state", state},
            {"status", c.status().isEmpty() ? QString() : t(QString(c.status()).replace('.', '_'))},
            {"peer", peer ? (peer->login.isEmpty() ? t("call_otherParty") : peer->login) : QString()},
            {"accountId", peer ? peer->accountId : QString()},
            {"connectedAt", c.connectedAt().value_or(0)},
            {"mic", c.micEnabled()},
            {"video", c.videoEnabled()},
            {"remoteVideo", c.remoteVideoEnabled()},
            {"hasCamera", cameraAvailable_}};
}

/// Рингтон на входящий, гудки на исходящий — пока не ответили.
void AppModel::updateRinging() {
    const CallState s = core_->calls.state();
    const QUrl want = s == CallState::IncomingRinging ? QUrl("qrc:/qt/qml/Oshinobu/sounds/ringtone.mp3")
                    : s == CallState::OutgoingRinging ? QUrl("qrc:/qt/qml/Oshinobu/sounds/ringback.mp3")
                                                      : QUrl();
    if (want.isEmpty()) {
        ring_.stop();
        return;
    }
    if (ring_.source() != want) ring_.setSource(want);
    if (ring_.playbackState() != QMediaPlayer::PlayingState) ring_.play();
}

void AppModel::startCall() {
    const auto c = current();
    if (!c || !c->lastKnownDeviceId) return;
    spawn(core_->calls.startCall(CallPeer{*c->lastKnownDeviceId, c->peerLogin, c->lastKnownAccountId.value_or(QString())}));
}

void AppModel::acceptCall() { spawn(core_->calls.acceptCall()); }
void AppModel::declineCall() { spawn(core_->calls.declineCall()); }
void AppModel::hangUp() { spawn(core_->calls.hangUp()); }
void AppModel::toggleMic() { spawn(core_->calls.toggleMic()); }
void AppModel::toggleVideo() { spawn(core_->calls.toggleVideo()); }

QVariantList AppModel::audioDevices(bool input) {
    QVariantList out;
    if (!core_->rtcEngine) return out;
    const QString chosen = core_->prefs->getString(input ? "call_audio_in" : "call_audio_out").value_or(QString());
    const auto devices = core_->rtcEngine->audioDevices(input);
    // выбранное раньше устройство отключено — текущим считается системное по умолчанию
    const bool chosenPresent = std::any_of(devices.begin(), devices.end(), [&](const AudioDevice &d) { return d.id == chosen; });
    for (const AudioDevice &d : devices) {
        out << QVariantMap{{"id", d.id}, {"name", d.name}, {"current", chosenPresent ? d.id == chosen : d.isDefault}};
    }
    return out;
}

void AppModel::selectAudioDevice(bool input, const QString &id) {
    core_->prefs->setString(input ? "call_audio_in" : "call_audio_out", id);
    core_->calls.setAudioDevice(input, id);
}

void AppModel::cancelTransfer(const QString &kind, const QString &id) {
    if (kind == "download") {
        core_->downloads.cancel(id);
        return;
    }
    for (const auto &[login, m] : core_->chats.sendingMessages()) {
        if (m.messageId == id) core_->cancelOutgoing(login, {id});
    }
    Q_EMIT transfersChanged();
}

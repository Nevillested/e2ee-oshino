#pragma once

// Состояние приложения поверх ядра для QML (как AppModel на iOS / ViewModel на
// Android): фаза входа, тема, язык, статус соединения, открытый чат и все
// действия. Асинхронные операции сообщают об ошибке сигналом error(текст).

#include "Core.h"
#include "Models.h"

#include <QJsonObject>
#include <QObject>
#include <QAudioOutput>
#include <QMediaPlayer>
#include <QSoundEffect>
#include <QSystemTrayIcon>

class QAction;
class QMenu;
#include <QTimer>
#include <QVariantMap>
#include <memory>

namespace osh { class GstRecorder; }
class Notifier;

class AppModel : public QObject, public osh::RouterHost {
    Q_OBJECT
    Q_PROPERTY(QString phase READ phase NOTIFY phaseChanged)
    Q_PROPERTY(QString connection READ connection NOTIFY connectionChanged)
    Q_PROPERTY(QVariantMap theme READ theme NOTIFY themeChanged)
    Q_PROPERTY(QString themeId READ themeId NOTIFY themeChanged)
    Q_PROPERTY(QString lang READ lang NOTIFY langChanged)
    Q_PROPERTY(QString myLogin READ myLogin NOTIFY accountChanged)
    Q_PROPERTY(QString myAccountId READ myAccountId NOTIFY accountChanged)
    Q_PROPERTY(QVariantMap myAccount READ myAccount NOTIFY accountChanged)
    Q_PROPERTY(QString myAvatar READ myAvatar NOTIFY avatarsChanged)
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)
    Q_PROPERTY(QString openChat READ openChat NOTIFY openChatChanged)
    Q_PROPERTY(QVariantMap openChatInfo READ openChatInfo NOTIFY openChatInfoChanged)
    Q_PROPERTY(QString wallpaper READ wallpaper NOTIFY openChatInfoChanged)
    Q_PROPERTY(QObject *chats READ chats CONSTANT)
    Q_PROPERTY(QObject *messages READ messages CONSTANT)
    Q_PROPERTY(QVariantList stickerPacks READ stickerPacks NOTIFY stickersChanged)
    Q_PROPERTY(QVariantList recentStickers READ recentStickers NOTIFY recentStickersChanged)
    Q_PROPERTY(int avatarRevision READ avatarRevision NOTIFY avatarsChanged)
    Q_PROPERTY(int stickerRevision READ stickerRevision NOTIFY stickerRevisionChanged)
    /// Стикер в крупном превью (долгое нажатие), пустой — превью нет.
    Q_PROPERTY(QString previewSticker MEMBER previewSticker_ NOTIFY previewStickerChanged)
    Q_PROPERTY(bool recording READ recording NOTIFY recordingChanged)
    /// Кнопка записи как на Android: тап — «voice» ⇄ «video» (кружок); удержание — запись
    /// (recState «holding»), вверх на замок — «locked» (кнопку можно отпустить).
    Q_PROPERTY(QString recordMode READ recordMode NOTIFY recordingChanged)
    Q_PROPERTY(QString recState READ recState NOTIFY recordingChanged)
    Q_PROPERTY(QString recKind READ recKind NOTIFY recordingChanged)
    Q_PROPERTY(int recElapsed READ recElapsed NOTIFY recElapsedChanged)
    Q_PROPERTY(bool canRecord READ canRecord CONSTANT)
    Q_PROPERTY(QString presence READ presence NOTIFY presenceChanged)
    Q_PROPERTY(QVariantMap appLock READ appLock NOTIFY appLockChanged)
    Q_PROPERTY(bool locked READ locked NOTIFY lockedChanged)
    Q_PROPERTY(QVariantList transfers READ transfers NOTIFY transfersChanged)
    Q_PROPERTY(QVariantMap call READ call NOTIFY callChanged)
    Q_PROPERTY(bool tgsSupported MEMBER tgsSupported_ CONSTANT)
    /// Что делает крестик: «tray» — свернуть в трей, «quit» — закрыть приложение, пусто — ещё не
    /// решено (спросить один раз и запомнить).
    Q_PROPERTY(QString closeAction READ closeAction WRITE setCloseAction NOTIFY closeActionChanged)
    /// Уведомления о сообщениях (всплывающие и звук) выключены из меню трея; звонки звонят всегда.
    Q_PROPERTY(bool notificationsMuted READ notificationsMuted WRITE setNotificationsMuted NOTIFY notificationsMutedChanged)
    Q_PROPERTY(bool trayAvailable READ trayAvailable CONSTANT)
    Q_PROPERTY(QVariantList emojiCategories READ emojiCategories CONSTANT)

public:
    explicit AppModel(QObject *parent = nullptr);
    ~AppModel() override;

    osh::Core &core() { return *core_; }

    // RouterHost
    QString openChatPeerLogin() const override { return windowActive_ ? openChat_ : QString(); }
    bool isAppInForeground() const override { return windowActive_; }
    void playMessageSound() override;
    void showMessageNotification(const QString &peerLogin, const QString &preview) override;

    QString phase() const { return phase_; }
    QString connection() const;
    QVariantMap theme() const;
    QString themeId() const { return themeId_; }
    QString lang() const { return lang_; }
    QString myLogin() const;
    QString myAccountId() const;
    QVariantMap myAccount() const;
    QString myAvatar();
    bool busy() const { return busy_; }
    QString openChat() const { return openChat_; }
    QVariantMap openChatInfo() const;
    QString wallpaper() const;
    QObject *chats() { return chats_.get(); }
    QObject *messages() { return messages_.get(); }
    QVariantList stickerPacks() const;
    QVariantList recentStickers() const;
    int avatarRevision() const { return avatarRevision_; }
    int stickerRevision() const { return stickerRevision_; }
    bool recording() const { return recState_ != "idle"; }
    QString recordMode() const { return recordMode_; }
    QString recState() const { return recState_; }
    QString recKind() const { return recKind_; }
    int recElapsed() const;
    bool canRecord() const { return recorder_ != nullptr; }
    QString presence() const { return presence_; }
    QVariantMap appLock() const;
    bool locked() const { return locked_; }
    QVariantList transfers() const;
    QVariantMap call() const;
    QVariantList emojiCategories() const;

    // строки и форматирование
    Q_INVOKABLE QString t(const QString &key, const QVariantList &args = {}) const;
    Q_INVOKABLE QString errorText(const QString &key) const;
    Q_INVOKABLE QString decodePreview(const QString &raw) const;
    Q_INVOKABLE QString formatSize(qint64 bytes) const;
    Q_INVOKABLE QString formatTime(qint64 ms) const;
    Q_INVOKABLE QString formatDay(qint64 ms) const;
    QString lastSeenText(qint64 ms) const;
    Q_INVOKABLE QString avatarFor(const QString &accountId);
    /// Файл стикера (нет в кэше — ядро скачает пак, stickerRevision изменится); [revision] — для пересчёта привязки.
    Q_INVOKABLE QString stickerUrl(const QString &stickerId, int revision);
    Q_INVOKABLE QStringList themeIds() const;
    Q_INVOKABLE QVariantMap themeColors(const QString &id) const;

    // вход
    Q_INVOKABLE void launch();
    Q_INVOKABLE void login(const QString &login, const QString &password, const QString &totp);
    Q_INVOKABLE void registerAccount(const QString &login, const QString &password, const QString &invite);
    Q_INVOKABLE void confirmTotp(const QString &login, const QString &password, const QString &code);
    Q_INVOKABLE void requestRecovery(const QString &login);
    Q_INVOKABLE void resetPassword(const QString &login, const QString &code, const QString &newPassword);
    Q_INVOKABLE void resetTotp(const QString &login, const QString &code);
    Q_INVOKABLE void logout();
    Q_INVOKABLE void quit();
    QString closeAction() const { return closeAction_; }
    void setCloseAction(const QString &action);
    bool notificationsMuted() const { return notificationsMuted_; }
    void setNotificationsMuted(bool muted);
    bool trayAvailable() const { return tray_ != nullptr; }
    Q_INVOKABLE void deleteAccount();

    // настройки
    Q_INVOKABLE void setTheme(const QString &id);
    Q_INVOKABLE void setLanguage(const QString &lang);
    Q_INVOKABLE void setWindowActive(bool active);
    void lockNow();
    Q_INVOKABLE void updateDisplayName(const QString &name);
    Q_INVOKABLE void updateStatus(const QString &status);
    Q_INVOKABLE void updateBirthday(const QString &birthday);
    Q_INVOKABLE void updatePrivacy(int findByLogin, int avatar, int birthday, int status);
    Q_INVOKABLE void changePassword(const QString &password);
    Q_INVOKABLE void requestEmailCode(const QString &email);
    Q_INVOKABLE void confirmEmailCode(const QString &code);
    Q_INVOKABLE void setAvatar(const QUrl &file);
    Q_INVOKABLE void removeAvatar();
    Q_INVOKABLE void clearCache();
    Q_INVOKABLE void setPin(const QString &pin);
    Q_INVOKABLE void removePin();
    Q_INVOKABLE void setLockEnabled(bool on);
    Q_INVOKABLE void setLockTimeout(int seconds);
    Q_INVOKABLE bool unlock(const QString &pin);

    // чаты
    Q_INVOKABLE void openChatWith(const QString &login);
    Q_INVOKABLE void findAndOpen(const QString &login);
    /// Поиск пользователя для выпадающего списка: ответ — сигнал searchResult.
    Q_INVOKABLE void lookupLogin(const QString &login);
    Q_INVOKABLE void closeChat();
    Q_INVOKABLE void sendText(const QString &text, const QString &replyToId);
    Q_INVOKABLE void sendFiles(const QList<QUrl> &files, const QString &caption);
    Q_INVOKABLE void sendSticker(const QString &stickerId, const QString &packId, const QString &format);
    Q_INVOKABLE void retry(const QString &messageId);
    Q_INVOKABLE void cancelSend(const QString &messageId);
    Q_INVOKABLE void editMessage(const QString &messageId, const QString &text);
    Q_INVOKABLE void react(const QString &messageId, const QString &emoji);
    Q_INVOKABLE void pinMessage(const QString &messageId, bool pinned);
    Q_INVOKABLE void deleteMessages(const QStringList &ids, bool forPeer);
    /// Переслать сообщения открытого чата (в порядке ленты) в чат [toLogin].
    Q_INVOKABLE void forwardMessages(const QStringList &ids, const QString &toLogin);
    Q_INVOKABLE void copyText(const QString &text);
    Q_INVOKABLE void clearHistory(const QString &login, bool forPeer);
    Q_INVOKABLE void deleteChat(const QString &login, bool forPeer);
    Q_INVOKABLE void setMuted(const QString &login, bool muted);
    Q_INVOKABLE void setBlocked(const QString &login, bool blocked);
    Q_INVOKABLE void setChatPinned(const QString &login, bool pinned);
    Q_INVOKABLE void resetSession();
    Q_INVOKABLE void typing();
    Q_INVOKABLE void downloadMedia(const QString &messageId);
    Q_INVOKABLE void openMedia(const QString &messageId);
    Q_INVOKABLE void saveMedia(const QString &messageId, const QUrl &target);
    /// [x, y, w, h] — видимая в превью часть картинки, доли её сторон.
    Q_INVOKABLE void setWallpaper(const QUrl &file, bool forPeer, qreal x, qreal y, qreal w, qreal h);
    Q_INVOKABLE void removeWallpaper();
    Q_INVOKABLE QVariantMap profileOf(const QString &login);
    Q_INVOKABLE void loadProfile(const QString &login);
    Q_INVOKABLE void toggleRecordMode();
    Q_INVOKABLE void beginRecording();
    Q_INVOKABLE void lockRecording();
    Q_INVOKABLE void finishRecording(bool send);
    /// Пак стикера из переписки — ответ в stickerPackShown (добавить / убрать, как на Android).
    Q_INVOKABLE void showStickerPack(const QString &stickerId);
    Q_INVOKABLE void installStickerPack(const QString &packId);
    Q_INVOKABLE void removeStickerPack(const QString &packId);
    Q_INVOKABLE void uploadStickerPack(const QString &title, const QUrl &zip);
    Q_INVOKABLE void cancelTransfer(const QString &kind, const QString &id);
    Q_INVOKABLE void startCall();
    Q_INVOKABLE void acceptCall();
    Q_INVOKABLE void declineCall();
    Q_INVOKABLE void hangUp();
    Q_INVOKABLE void toggleMic();
    Q_INVOKABLE void toggleVideo();
    /// Микрофоны / выходы звука: [{id, name, current}].
    Q_INVOKABLE QVariantList audioDevices(bool input);
    Q_INVOKABLE void selectAudioDevice(bool input, const QString &id);

Q_SIGNALS:
    void phaseChanged();
    void connectionChanged();
    void themeChanged();
    void langChanged();
    void accountChanged();
    void busyChanged();
    void openChatChanged();
    void openChatInfoChanged();
    void stickersChanged();
    void avatarsChanged();
    void recordingChanged();
    void recElapsedChanged();
    void presenceChanged();
    void appLockChanged();
    void lockedChanged();
    void transfersChanged();
    void callChanged();
    void searchResult(const QString &query, bool found, const QString &login, const QString &accountId);
    void error(const QString &text);
    void wallpaperDone(bool ok);
    /// {id, title, installed, deleted, stickers: [id]}; пустой — не загрузился.
    void stickerPackShown(const QVariantMap &pack);
    void recentStickersChanged();
    void stickerRevisionChanged();
    void previewStickerChanged();
    void closeActionChanged();
    void notificationsMutedChanged();
    void info(const QString &text);
    void totpReady(const QString &url, const QString &secret);
    void recoveryCodeSent();
    void totpVerified();
    void recoveryDone(const QString &newTotpUrl);
    void emailCodeSent();
    void profileLoaded(const QString &login);
    void stickerUploadProgress(const QString &stage);
    void stickerUploadDone();
    void scrollToMessage(const QString &messageId);
    /// Показать окно (нажали уведомление, повторный запуск).
    void raiseRequested();

private:
    void setPhase(const QString &p);
    void setBusy(bool b);
    void runOp(osh::Task<void> task, std::function<void()> onDone = {});
    void fail(std::exception_ptr e);
    std::optional<osh::ChatSummary> current() const;
    void subscribeToChat();
    void loadStrings();

    std::unique_ptr<osh::Core> core_;
    std::unique_ptr<ChatListModel> chats_;
    std::unique_ptr<MessageModel> messages_;
    std::unique_ptr<osh::GstRecorder> recorder_; // нет GStreamer — записи нет
    QString recordMode_ = QStringLiteral("voice");
    QString recState_ = QStringLiteral("idle");
    QString recKind_;
    QString recPeer_;
    QTimer recTicker_;
    QString recTempDir_;
    static constexpr qint64 MinRecordingMs = 700;
    static constexpr qint64 MaxVideoNoteMs = 5 * 60 * 1000;
    void setRecState(const QString &state);
    QHash<QString, QString> strings_, fallback_;
    QString phase_ = QStringLiteral("launching");
    QString themeId_, lang_;
    QString openChat_;
    QString presence_;
    QString subscribedDevice_;
    bool busy_ = false;
    bool windowActive_ = true;
    bool locked_ = false;
    qint64 hiddenAt_ = 0;
    /// Блокировка по таймауту, пока окно не в фокусе — даже если на него никто не переключался
    /// (окно на другом мониторе видно всем, кто подойдёт к ПК).
    QTimer lockTimer_;
    qint64 lastTypingSent_ = 0;
    int avatarRevision_ = 0;
    int stickerRevision_ = 0;
    QString previewSticker_;
    // что уже отдано QML: паки и «Недавние» сообщаются, только если правда изменились —
    // иначе панель пересоздавала все страницы на каждую отправку (мерцание)
    QVariantList shownPacks_, shownRecent_;
    bool tgsSupported_ = false;
    QSet<QString> stickerLoading_;
    QHash<QString, QVariantMap> profiles_;
    // короткий звук сообщения — QSoundEffect: QMediaPlayer в Qt 6.2 после конца файла второй раз
    // «играет» мгновенно и молча — звук был только у первого сообщения за сеанс
    QSoundEffect sound_;
    QMediaPlayer ring_;
    bool cameraAvailable_ = false;
    QAudioOutput ringOut_;
    void updateRinging();
    QSystemTrayIcon *tray_ = nullptr;
    QMenu *trayMenu_ = nullptr;
    QAction *trayOpen_ = nullptr, *trayMute_ = nullptr, *trayQuit_ = nullptr;
    QString closeAction_;
    bool notificationsMuted_ = false;
    void updateTrayMenu();
    Notifier *notifier_ = nullptr;
};

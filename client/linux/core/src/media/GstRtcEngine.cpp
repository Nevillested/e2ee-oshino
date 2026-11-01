#include "media/GstRtcEngine.h"

#include "support/Log.h"

#include <QCoreApplication>
#include <QHash>
#include <QMetaObject>
#include <QPointer>
#include <QRandomGenerator>
#include <QRegularExpression>
#include <QTimer>
#include <QUrl>

#define GST_USE_UNSTABLE_API
#include <gst/gst.h>
#include <gst/sdp/sdp.h>
#include <gst/webrtc/webrtc.h>

#include <QTime>

#include <atomic>
#include <cstdio>
#include <memory>
#include <mutex>

namespace osh {

namespace {

/// Выполнить в главном потоке Qt (сигналы webrtcbin приходят из его потоков).
template <typename F>
void onMain(F fn) {
    QMetaObject::invokeMethod(QCoreApplication::instance(), std::move(fn), Qt::QueuedConnection);
}

QString describe(GError *e) { return e ? QString::fromUtf8(e->message) : QStringLiteral("?"); }

bool hasFactory(const char *name) {
    GstElementFactory *f = gst_element_factory_find(name);
    if (f) gst_object_unref(f);
    return f != nullptr;
}

/// ssrc в caps: без него webrtcbin не пишет a=ssrc в SDP, и libwebrtc принимает поток как «безымянный».
guint32 newSsrc() { return QRandomGenerator::global()->generate() | 1u; }

/// Устройства звука PulseAudio / PipeWire: id — имя устройства в PulseAudio (свойство device
/// у pulsesrc/pulsesink); мониторы выходов в список микрофонов не попадают.
QList<AudioDevice> listAudioDevices(bool input) {
    QList<AudioDevice> out;
    GstDeviceMonitor *mon = gst_device_monitor_new();
    GstCaps *caps = gst_caps_new_empty_simple("audio/x-raw");
    gst_device_monitor_add_filter(mon, input ? "Audio/Source" : "Audio/Sink", caps);
    gst_caps_unref(caps);
    if (!gst_device_monitor_start(mon)) {
        gst_object_unref(mon);
        return out;
    }
    GList *devices = gst_device_monitor_get_devices(mon);
    for (GList *l = devices; l; l = l->next) {
        GstDevice *d = GST_DEVICE(l->data);
        GstStructure *props = gst_device_get_properties(d);
        const gchar *cls = props ? gst_structure_get_string(props, "device.class") : nullptr;
        const bool monitor = cls && g_strcmp0(cls, "monitor") == 0; // cls живёт, пока жива props
        gboolean isDefault = FALSE;
        if (props) gst_structure_get_boolean(props, "is-default", &isDefault);
        QString id;
        if (g_object_class_find_property(G_OBJECT_GET_CLASS(d), "internal-name")) {
            gchar *name = nullptr;
            g_object_get(d, "internal-name", &name, nullptr);
            id = QString::fromUtf8(name ? name : "");
            g_free(name);
        }
        gchar *display = gst_device_get_display_name(d);
        const QString title = QString::fromUtf8(display ? display : "");
        g_free(display);
        if (props) gst_structure_free(props);
        if (input && monitor) continue;
        if (id.isEmpty()) continue; // не PulseAudio — выбрать нечем
        out << AudioDevice{id, title, isDefault == TRUE};
    }
    g_list_free_full(devices, gst_object_unref);
    gst_device_monitor_stop(mon);
    gst_object_unref(mon);
    return out;
}

/// Пакеты через пад — счётчик для журнала (в какую сторону не идёт звук/видео).
GstPadProbeReturn countBuffers(GstPad *, GstPadProbeInfo *, gpointer counter) {
    static_cast<std::atomic<int> *>(counter)->fetch_add(1, std::memory_order_relaxed);
    return GST_PAD_PROBE_OK;
}

class GstRtcSession : public RtcSession {
public:
    GstRtcSession(GstRtcEngine &engine, const QList<IceServer> &servers, RtcEvents events)
        : engine_(engine), events_(std::move(events)), alive_(std::make_shared<bool>(true)) {
        pipeline_ = gst_pipeline_new("oshinobu-call");
        webrtc_ = gst_element_factory_make("webrtcbin", "webrtc");
        if (!pipeline_ || !webrtc_) throw std::runtime_error("GStreamer: нет webrtcbin (gst-plugins-bad)");
        g_object_set(webrtc_, "bundle-policy", GST_WEBRTC_BUNDLE_POLICY_MAX_BUNDLE, nullptr);
        for (const IceServer &s : servers) {
            for (const QString &url : s.urls) {
                if (url.startsWith("stun:")) {
                    g_object_set(webrtc_, "stun-server", ("stun://" + url.mid(5)).toUtf8().constData(), nullptr);
                } else if (url.startsWith("turn:")) {
                    // turn:host:port?transport=udp → turn://user:pass@host:port?transport=udp
                    const QString rest = url.mid(5);
                    const QString uri = "turn://" + QString::fromUtf8(QUrl::toPercentEncoding(s.username)) + ":" +
                                        QString::fromUtf8(QUrl::toPercentEncoding(s.credential)) + "@" + rest;
                    gboolean ok = FALSE;
                    g_signal_emit_by_name(webrtc_, "add-turn-server", uri.toUtf8().constData(), &ok);
                }
            }
        }
        gst_bin_add(GST_BIN(pipeline_), webrtc_);
        g_signal_connect(webrtc_, "on-ice-candidate", G_CALLBACK(&GstRtcSession::onIceCandidate), this);
        g_signal_connect(webrtc_, "on-negotiation-needed", G_CALLBACK(&GstRtcSession::onNegotiationNeeded), this);
        g_signal_connect(webrtc_, "notify::connection-state", G_CALLBACK(&GstRtcSession::onConnectionState), this);
        g_signal_connect(webrtc_, "pad-added", G_CALLBACK(&GstRtcSession::onPadAdded), this);
        g_signal_connect(webrtc_, "notify::ice-connection-state", G_CALLBACK(&GstRtcSession::onIceState), this);
        g_signal_connect(webrtc_, "notify::signaling-state", G_CALLBACK(&GstRtcSession::onSignalingState), this);
        // ошибки конвейера (устройство звука, согласование форматов) — в журнал: без этого звук
        // пропадал молча, а ICE рвался через несколько секунд
        GstBus *bus = gst_pipeline_get_bus(GST_PIPELINE(pipeline_));
        gst_bus_set_sync_handler(bus, &GstRtcSession::onBusMessage, nullptr, nullptr);
        gst_object_unref(bus);
        gst_element_set_state(pipeline_, GST_STATE_PLAYING);
        scheduleStats();
    }

    ~GstRtcSession() override { close(); }

    SignalingState signalingState() const override {
        GstWebRTCSignalingState s = GST_WEBRTC_SIGNALING_STATE_STABLE;
        if (webrtc_) g_object_get(webrtc_, "signaling-state", &s, nullptr);
        if (s == GST_WEBRTC_SIGNALING_STATE_STABLE) return SignalingState::Stable;
        if (s == GST_WEBRTC_SIGNALING_STATE_HAVE_LOCAL_OFFER) return SignalingState::HaveLocalOffer;
        return SignalingState::Other;
    }

    Task<QString> createOffer() override {
        keepNegotiatedDirections();
        co_return co_await createDescription("create-offer", GST_WEBRTC_SDP_TYPE_OFFER);
    }
    Task<QString> createAnswer() override {
        keepNegotiatedDirections();
        co_return co_await createDescription("create-answer", GST_WEBRTC_SDP_TYPE_ANSWER);
    }

    Task<void> setRemoteDescription(QString type, QString sdp) override {
        // звук до удалённого offer: иначе ответ выйдет recvonly
        if (type == "offer") ensureAudio();
        GstSDPMessage *msg = nullptr;
        gst_sdp_message_new(&msg);
        const QByteArray raw = sdp.toUtf8();
        if (gst_sdp_message_parse_buffer(reinterpret_cast<const guint8 *>(raw.constData()), guint(raw.size()), msg) != GST_SDP_OK) {
            gst_sdp_message_free(msg);
            throw std::runtime_error("SDP собеседника не разобран");
        }
        GstWebRTCSessionDescription *desc =
            gst_webrtc_session_description_new(type == "offer" ? GST_WEBRTC_SDP_TYPE_OFFER : GST_WEBRTC_SDP_TYPE_ANSWER, msg);
        // первый ответ собеседника на наш offer задаёт роли DTLS на весь звонок: он active — мы passive
        if (type == "answer" && !dtlsRole_) {
            const QString theirs = setupOf(msg);
            if (theirs == "active") dtlsRole_ = QStringLiteral("passive");
            else if (theirs == "passive") dtlsRole_ = QStringLiteral("active");
        }
        const QHash<QString, int> remoteDirs = dirsByMid(desc->sdp);
        co_await promiseCall("set-remote-description", desc);
        gst_webrtc_session_description_free(desc);
        if (type == "answer") {
            for (auto it = remoteDirs.cbegin(); it != remoteDirs.cend(); ++it) negotiated_[it.key()] = offeredDirs_.value(it.key(), 3) & reversed(it.value());
        }
    }

    Task<void> rollback() override {
        GstSDPMessage *msg = nullptr;
        gst_sdp_message_new(&msg);
        GstWebRTCSessionDescription *desc = gst_webrtc_session_description_new(GST_WEBRTC_SDP_TYPE_ROLLBACK, msg);
        co_await promiseCall("set-local-description", desc);
        gst_webrtc_session_description_free(desc);
    }

    Task<void> addIceCandidate(QString candidate, QString sdpMid, int sdpMLineIndex) override {
        Q_UNUSED(sdpMid)
        g_signal_emit_by_name(webrtc_, "add-ice-candidate", guint(sdpMLineIndex), candidate.toUtf8().constData());
        co_return;
    }

    Task<void> startAudio(bool micEnabled) override {
        ensureAudio();
        setMicEnabled(micEnabled);
        co_return;
    }

    void setMicEnabled(bool enabled) override {
        if (micVolume_) g_object_set(micVolume_, "mute", !enabled, nullptr);
    }

    Task<void> setVideoEnabled(bool enabled) override {
        videoWanted_ = enabled;
        if (enabled) {
            if (!videoBin_ && !engine_.hasCamera()) throw std::runtime_error("камера не найдена");
            // новый поток — только после перезапроса: пакеты VP8 до ответа собеседник не к чему
            // привязать, и его webrtcbin останавливает приём целиком (not-linked → ICE рвётся)
            if (!videoBin_) {
                ensureVideo();
                // webrtcbin 1.20 не просит перезапрос, если видео-трансивер уже создан по offer
                // собеседника (он включил камеру первым) — просим сами, иначе камера ждёт вечно
                std::weak_ptr<bool> alive = alive_;
                QTimer::singleShot(0, QCoreApplication::instance(), [this, alive] {
                    auto a = alive.lock();
                    if (a && *a && !videoOfferSent_ && events_.onRenegotiationNeeded) events_.onRenegotiationNeeded();
                });
            } else if (signalingState() == SignalingState::Stable && videoNegotiated_) {
                startVideo();
            }
        } else if (videoBin_) {
            gst_element_set_locked_state(videoBin_, TRUE);
            gst_element_set_state(videoBin_, GST_STATE_NULL);
        }
        co_return;
    }

    void setAudioDevice(bool input, const QString &id) override {
        GstElement *el = input ? mic_ : spk_;
        if (!el || !g_object_class_find_property(G_OBJECT_GET_CLASS(el), "device")) return;
        log(QStringLiteral("GStreamer %1 device -> %2").arg(input ? "mic" : "speaker", id.isEmpty() ? QStringLiteral("default") : id));
        // устройство PulseAudio открывается при старте элемента — перезапускаем только его
        gst_element_set_state(el, GST_STATE_NULL);
        g_object_set(el, "device", id.isEmpty() ? nullptr : id.toUtf8().constData(), nullptr);
        gst_element_sync_state_with_parent(el);
    }

    void close() override {
        if (!pipeline_) return;
        *alive_ = false;
        engine_.endCallLog();
        gst_element_set_state(pipeline_, GST_STATE_NULL);
        gst_object_unref(pipeline_);
        pipeline_ = nullptr;
        webrtc_ = nullptr;
        micVolume_ = nullptr;
        speaker_ = nullptr;
        outBin_ = nullptr;
        mic_ = nullptr;
        spk_ = nullptr;
        videoBin_ = nullptr;
    }

private:
    /// Раз в 5 с — сколько RTP ушло и пришло (только если что-то изменилось).
    void scheduleStats() {
        std::weak_ptr<bool> alive = alive_;
        QTimer::singleShot(5000, QCoreApplication::instance(), [this, alive] {
            auto a = alive.lock();
            if (!a || !*a) return;
            const int out = rtpOut_.load(), in = rtpIn_.load();
            if (out != lastOut_ || in != lastIn_) {
                log(QStringLiteral("GStreamer RTP out=%1 in=%2").arg(out).arg(in));
                lastOut_ = out;
                lastIn_ = in;
            }
            scheduleStats();
        });
    }

    /// Готовый bin с одним свободным выходом — в новый вход webrtcbin (новый transceiver).
    void linkToWebrtc(GstElement *bin) {
        gst_bin_add(GST_BIN(pipeline_), bin);
        GstPad *src = gst_element_get_static_pad(bin, "src");
        gst_pad_add_probe(src, GST_PAD_PROBE_TYPE_BUFFER, &countBuffers, &rtpOut_, nullptr);
        GstPad *sink = gst_element_request_pad_simple(webrtc_, "sink_%u");
        gst_pad_link(src, sink);
        gst_object_unref(src);
        gst_object_unref(sink);
        gst_element_sync_state_with_parent(bin);
    }

    GstElement *child(GstElement *bin, const char *name) {
        GstElement *e = gst_bin_get_by_name(GST_BIN(bin), name);
        if (e) gst_object_unref(e); // ссылку держит bin
        return e;
    }

    /// Микрофон → эхоподавление → Opus → webrtcbin; вывод — микшер входящих потоков.
    void ensureAudio() {
        if (audioAdded_) return;
        audioAdded_ = true;
        const bool pulse = hasFactory("pulsesrc") && hasFactory("pulsesink");
        GError *err = nullptr;
        // вывод собирается сразу: webrtcdsp при старте ищет эхо-зонд по имени и без него падает.
        // async=false: пока собеседник молчит, микшеру нечего отдать, и вывод, ожидая первые
        // данные, держал весь конвейер в PAUSED — микрофон не писал ни пакета
        const QString outDesc = QStringLiteral("audiomixer name=speaker ! audioconvert ! audioresample ! webrtcechoprobe name=echoprobe ! %1")
                                    .arg(pulse ? "pulsesink name=spk async=false" : "autoaudiosink name=spk async-handling=true");
        GstElement *out = gst_parse_bin_from_description(outDesc.toUtf8().constData(), FALSE, &err);
        if (!out) throw std::runtime_error(("GStreamer: вывод не собран: " + describe(err)).toStdString());
        outBin_ = out;
        speaker_ = child(out, "speaker");
        spk_ = child(out, "spk");
        if (pulse && !engine_.preferredAudioDevice(false).isEmpty()) {
            g_object_set(spk_, "device", engine_.preferredAudioDevice(false).toUtf8().constData(), nullptr);
        }
        gst_bin_add(GST_BIN(pipeline_), out);
        gst_element_sync_state_with_parent(out);
        // caps — через capsfilter: голые caps в конце описания gst_parse принимает за имя элемента.
        // encoding-params=2: libwebrtc знает Opus только как opus/48000/2 — без «/2» Android не
        // находил общего кодека, отклонял звук, и ICE даже не начинался
        const guint32 ssrc = newSsrc();
        const QString micDesc =
            QStringLiteral("%1 ! audioconvert ! audioresample ! capsfilter caps=audio/x-raw,rate=48000,channels=1 ! "
                           "webrtcdsp probe=echoprobe echo-cancel=true noise-suppression=true gain-control=true ! volume name=micvol ! "
                           "audioconvert ! opusenc bitrate=32000 ! rtpopuspay pt=111 ssrc=%2 ! "
                           "capsfilter caps=\"application/x-rtp,media=audio,encoding-name=OPUS,encoding-params=(string)2,payload=111,"
                           "clock-rate=48000,minptime=(string)10,useinbandfec=(string)1,ssrc=(uint)%2\"")
                .arg(pulse ? "pulsesrc name=mic" : "autoaudiosrc name=mic")
                .arg(ssrc);
        GstElement *bin = gst_parse_bin_from_description(micDesc.toUtf8().constData(), TRUE, &err);
        if (!bin) throw std::runtime_error(("GStreamer: аудио не собрано: " + describe(err)).toStdString());
        micVolume_ = child(bin, "micvol");
        mic_ = child(bin, "mic");
        if (pulse && !engine_.preferredAudioDevice(true).isEmpty()) {
            g_object_set(mic_, "device", engine_.preferredAudioDevice(true).toUtf8().constData(), nullptr);
        }
        linkToWebrtc(bin);
    }

    void startVideo() {
        if (!videoBin_ || !videoWanted_) return;
        gst_element_set_locked_state(videoBin_, FALSE);
        gst_element_sync_state_with_parent(videoBin_);
    }

    static void onSignalingState(GstElement *, GParamSpec *, gpointer user) {
        auto *self = static_cast<GstRtcSession *>(user);
        std::weak_ptr<bool> alive = self->alive_;
        onMain([self, alive] {
            auto a = alive.lock();
            if (!a || !*a || !self->videoBin_ || self->signalingState() != SignalingState::Stable) return;
            // offer с камерой принят и ответ применён — можно слать
            if (self->videoOfferSent_) {
                self->videoNegotiated_ = true;
                self->startVideo();
            }
        });
    }

    /// Камера → VP8 → webrtcbin (новый transceiver — webrtcbin попросит перезапрос, как
    /// addTrack на Android); вторая ветка — маленькое превью себя.
    void ensureVideo() {
        if (videoBin_) return;
        const guint32 ssrc = newSsrc();
        const QString desc =
            QStringLiteral("%1 ! videoconvert ! videoscale ! videorate ! "
                           "capsfilter caps=video/x-raw,width=640,height=480,pixel-aspect-ratio=1/1,framerate=30/1 ! tee name=camtee "
                           "camtee. ! queue leaky=downstream max-size-buffers=2 ! videoconvert ! "
                           "vp8enc deadline=1 cpu-used=8 target-bitrate=800000 end-usage=cbr keyframe-max-dist=60 ! "
                           "rtpvp8pay pt=96 ssrc=%2 picture-id-mode=15-bit ! "
                           "capsfilter caps=\"application/x-rtp,media=video,encoding-name=VP8,payload=96,clock-rate=90000,ssrc=(uint)%2\" "
                           "camtee. ! queue leaky=downstream max-size-buffers=1 ! videoconvert ! videoscale ! "
                           "capsfilter caps=video/x-raw,format=RGBA,width=320,height=240 ! "
                           "appsink name=localview emit-signals=true sync=false async=false max-buffers=1 drop=true")
                .arg(engine_.testVideo() ? "videotestsrc is-live=true pattern=ball" : "v4l2src")
                .arg(ssrc);
        GError *err = nullptr;
        GstElement *bin = gst_parse_bin_from_description(desc.toUtf8().constData(), TRUE, &err);
        if (!bin) throw std::runtime_error(("GStreamer: видео не собрано: " + describe(err)).toStdString());
        g_signal_connect(child(bin, "localview"), "new-sample", G_CALLBACK(&GstRtcSession::onLocalSample), this);
        videoBin_ = bin;
        gst_element_set_locked_state(bin, TRUE); // стартует в onSignalingState, после перезапроса
        gst_bin_add(GST_BIN(pipeline_), bin);
        GstPad *src = gst_element_get_static_pad(bin, "src");
        GstPad *sink = gst_element_request_pad_simple(webrtc_, "sink_%u");
        gst_pad_link(src, sink);
        gst_object_unref(src);
        gst_object_unref(sink);
    }

    /// set-*-description: ждём promise webrtcbin.
    Task<void> promiseCall(const char *signal, GstWebRTCSessionDescription *desc) {
        Deferred<QString> done; // пусто — применено, иначе текст ошибки webrtcbin
        auto *holder = new Deferred<QString>(done);
        GstPromise *promise = gst_promise_new_with_change_func(
            [](GstPromise *p, gpointer user) {
                auto *d = static_cast<Deferred<QString> *>(user);
                QString error;
                const GstStructure *reply = gst_promise_get_reply(p);
                GError *err = nullptr;
                if (reply && gst_structure_has_field(reply, "error")) gst_structure_get(reply, "error", G_TYPE_ERROR, &err, nullptr);
                if (err) {
                    error = describe(err);
                    g_error_free(err);
                }
                onMain([d, error] {
                    d->resolve(error);
                    delete d;
                });
            },
            holder, nullptr);
        log(QStringLiteral("GStreamer %1: %2").arg(QString::fromUtf8(signal), summarize(desc->sdp)));
        g_signal_emit_by_name(webrtc_, signal, desc, promise);
        std::optional<QString> result; // объявление отдельно: «T x = co_await …» GCC 11 не компилирует
        result = co_await done.waitFor(10000);
        gst_promise_unref(promise);
        if (!result) throw std::runtime_error(std::string("webrtcbin: ") + signal + " не ответил за 10 с");
        if (!result->isEmpty()) throw std::runtime_error(std::string("webrtcbin: ") + signal + ": " + result->toStdString());
    }

    // направление строки — биты «шлём» (1) и «принимаем» (2); 0 — inactive
    static int dirBits(const GstSDPMedia *m) {
        if (gst_sdp_media_get_attribute_val(m, "inactive")) return 0;
        if (gst_sdp_media_get_attribute_val(m, "sendonly")) return 1;
        if (gst_sdp_media_get_attribute_val(m, "recvonly")) return 2;
        return 3;
    }
    static int reversed(int bits) { return ((bits & 1) << 1) | ((bits & 2) >> 1); }
    static QHash<QString, int> dirsByMid(const GstSDPMessage *sdp) {
        QHash<QString, int> out;
        for (guint i = 0; i < gst_sdp_message_medias_len(sdp); ++i) {
            const GstSDPMedia *m = gst_sdp_message_get_media(sdp, i);
            if (const gchar *mid = gst_sdp_media_get_attribute_val(m, "mid")) out.insert(QString::fromUtf8(mid), dirBits(m));
        }
        return out;
    }
    static GstWebRTCRTPTransceiverDirection toDirection(int bits) {
        switch (bits) {
        case 0: return GST_WEBRTC_RTP_TRANSCEIVER_DIRECTION_INACTIVE;
        case 1: return GST_WEBRTC_RTP_TRANSCEIVER_DIRECTION_SENDONLY;
        case 2: return GST_WEBRTC_RTP_TRANSCEIVER_DIRECTION_RECVONLY;
        default: return GST_WEBRTC_RTP_TRANSCEIVER_DIRECTION_SENDRECV;
        }
    }

    /// webrtcbin 1.20 не умеет менять направление уже согласованной строки («transceiver direction
    /// changes are not implemented»), а Android, включая камеру после нас, переиспользует нашу
    /// видеостроку и просит sendrecv. Желаемое направление каждой согласованной строки ставим равным
    /// согласованному (свойство current-direction в 1.20 врёт — итог считаем по SDP сами): перезапрос
    /// проходит, строка остаётся как была; свою камеру Android шлёт новой строкой.
    void keepNegotiatedDirections() {
        GArray *list = nullptr;
        g_signal_emit_by_name(webrtc_, "get-transceivers", &list);
        if (!list) return;
        for (guint i = 0; i < list->len; ++i) {
            GstWebRTCRTPTransceiver *t = g_array_index(list, GstWebRTCRTPTransceiver *, i);
            gchar *mid = nullptr;
            GstWebRTCRTPTransceiverDirection wanted = GST_WEBRTC_RTP_TRANSCEIVER_DIRECTION_NONE;
            g_object_get(t, "mid", &mid, "direction", &wanted, nullptr);
            const QString key = QString::fromUtf8(mid ? mid : "");
            g_free(mid);
            const auto it = negotiated_.constFind(key);
            if (key.isEmpty() || it == negotiated_.constEnd() || toDirection(*it) == wanted) continue;
            g_object_set(t, "direction", toDirection(*it), nullptr);
            log(QStringLiteral("GStreamer mid=%1: direction kept (webrtcbin 1.20 can't change a negotiated one)").arg(key));
        }
        g_array_unref(list);
    }

    /// a=setup первой m-строки (active / passive / actpass), пусто — нет.
    static QString setupOf(const GstSDPMessage *sdp) {
        for (guint i = 0; i < gst_sdp_message_medias_len(sdp); ++i) {
            if (const gchar *v = gst_sdp_media_get_attribute_val(gst_sdp_message_get_media(sdp, i), "setup")) return QString::fromUtf8(v);
        }
        return {};
    }

    /// То же описание с a=setup:[role] во всех m-строках (через текст: разобранный SDP неизменяем).
    static GstWebRTCSessionDescription *withSetup(GstWebRTCSessionDescription *desc, const QString &role) {
        gchar *text = gst_sdp_message_as_text(desc->sdp);
        QString sdp = QString::fromUtf8(text);
        g_free(text);
        static const QRegularExpression setup(QStringLiteral("a=setup:(active|passive|actpass)"));
        sdp.replace(setup, "a=setup:" + role);
        GstSDPMessage *msg = nullptr;
        gst_sdp_message_new(&msg);
        const QByteArray raw = sdp.toUtf8();
        gst_sdp_message_parse_buffer(reinterpret_cast<const guint8 *>(raw.constData()), guint(raw.size()), msg);
        GstWebRTCSessionDescription *fixed = gst_webrtc_session_description_new(desc->type, msg);
        gst_webrtc_session_description_free(desc);
        return fixed;
    }

    /// Сводка SDP для журнала — без ключей ICE/DTLS: m-строки, mid, направление, кодеки.
    static QString summarize(const GstSDPMessage *sdp) {
        QStringList parts;
        for (guint i = 0; i < gst_sdp_message_medias_len(sdp); ++i) {
            const GstSDPMedia *m = gst_sdp_message_get_media(sdp, i);
            QString dir = "sendrecv";
            for (const char *d : {"sendonly", "recvonly", "inactive", "sendrecv"}) {
                if (gst_sdp_media_get_attribute_val(m, d)) dir = QString::fromLatin1(d);
            }
            QStringList codecs;
            for (guint k = 0; k < gst_sdp_media_attributes_len(m); ++k) {
                const GstSDPAttribute *a = gst_sdp_media_get_attribute(m, k);
                if (g_strcmp0(a->key, "rtpmap") == 0 && codecs.size() < 4) codecs << QString::fromUtf8(a->value);
            }
            const gchar *mid = gst_sdp_media_get_attribute_val(m, "mid");
            parts << QStringLiteral("%1 mid=%2 %3 port=%4 [%5]")
                         .arg(QString::fromUtf8(gst_sdp_media_get_media(m)), QString::fromUtf8(mid ? mid : "-"), dir)
                         .arg(gst_sdp_media_get_port(m))
                         .arg(codecs.join(", "));
        }
        return parts.join(" | ");
    }

    /// create-offer / create-answer → set-local-description → текст SDP.
    Task<QString> createDescription(const char *signal, GstWebRTCSDPType type) {
        Deferred<GstPromise *> done;
        auto *holder = new Deferred<GstPromise *>(done);
        GstPromise *promise = gst_promise_new_with_change_func(
            [](GstPromise *p, gpointer user) {
                auto *d = static_cast<Deferred<GstPromise *> *>(user);
                onMain([d, p] {
                    d->resolve(p);
                    delete d;
                });
            },
            holder, nullptr);
        g_signal_emit_by_name(webrtc_, signal, nullptr, promise);
        GstPromise *ready = *(co_await done.wait());
        if (gst_promise_wait(ready) != GST_PROMISE_RESULT_REPLIED) throw std::runtime_error("webrtcbin: SDP не создан");
        const GstStructure *reply = gst_promise_get_reply(ready);
        GstWebRTCSessionDescription *desc = nullptr;
        gst_structure_get(reply, type == GST_WEBRTC_SDP_TYPE_OFFER ? "offer" : "answer", GST_TYPE_WEBRTC_SESSION_DESCRIPTION, &desc, nullptr);
        gst_promise_unref(ready);
        if (!desc) throw std::runtime_error("webrtcbin: пустой SDP");
        if (type == GST_WEBRTC_SDP_TYPE_ANSWER) {
            if (!dtlsRole_) {
                dtlsRole_ = setupOf(desc->sdp); // первый наш ответ — роль выбирает webrtcbin
            } else if (setupOf(desc->sdp) != *dtlsRole_) {
                // webrtcbin 1.20 в каждом ответе пишет setup:active, даже если в звонке мы passive;
                // libwebrtc на смену роли посреди звонка отвечает «Failed to set SSL role» и
                // перезапрос (включение камеры) умирает — ставим роль, которая уже есть
                desc = withSetup(desc, *dtlsRole_);
            }
        }
        // mid каждой m-строки: webrtcbin называет их "audio0"/"video1", а libwebrtc сверяет
        // кандидата по sdpMid — с номером строки вместо mid Android отвергал все кандидаты
        localMids_.clear();
        for (guint i = 0; i < gst_sdp_message_medias_len(desc->sdp); ++i) {
            const gchar *mid = gst_sdp_media_get_attribute_val(gst_sdp_message_get_media(desc->sdp, i), "mid");
            localMids_ << (mid ? QString::fromUtf8(mid) : QString());
        }
        co_await promiseCall("set-local-description", desc);
        if (videoBin_) videoOfferSent_ = true; // локальное описание уже с камерой
        // итог направлений: наш ответ уже итог; наш offer — ждёт ответа собеседника
        if (type == GST_WEBRTC_SDP_TYPE_ANSWER) {
            const QHash<QString, int> ours = dirsByMid(desc->sdp);
            for (auto it = ours.cbegin(); it != ours.cend(); ++it) negotiated_[it.key()] = it.value();
        } else {
            offeredDirs_ = dirsByMid(desc->sdp);
        }
        gchar *text = gst_sdp_message_as_text(desc->sdp);
        const QString sdp = QString::fromUtf8(text);
        g_free(text);
        gst_webrtc_session_description_free(desc);
        co_return sdp;
    }

    static void onIceCandidate(GstElement *, guint mline, gchar *candidate, gpointer user) {
        auto *self = static_cast<GstRtcSession *>(user);
        const QString c = QString::fromUtf8(candidate);
        std::weak_ptr<bool> alive = self->alive_;
        onMain([self, alive, c, mline] {
            auto a = alive.lock();
            if (!a || !*a || !self->events_.onIceCandidate) return;
            const QString mid = int(mline) < self->localMids_.size() ? self->localMids_[int(mline)] : QString();
            self->events_.onIceCandidate(c, mid, int(mline));
        });
    }

    static void onNegotiationNeeded(GstElement *, gpointer user) {
        auto *self = static_cast<GstRtcSession *>(user);
        std::weak_ptr<bool> alive = self->alive_;
        onMain([self, alive] {
            if (auto a = alive.lock(); a && *a && self->events_.onRenegotiationNeeded) self->events_.onRenegotiationNeeded();
        });
    }

    static void onConnectionState(GstElement *webrtc, GParamSpec *, gpointer user) {
        auto *self = static_cast<GstRtcSession *>(user);
        GstWebRTCPeerConnectionState s = GST_WEBRTC_PEER_CONNECTION_STATE_NEW;
        g_object_get(webrtc, "connection-state", &s, nullptr);
        std::weak_ptr<bool> alive = self->alive_;
        onMain([self, alive, s] {
            auto a = alive.lock();
            if (!a || !*a) return;
            if (s == GST_WEBRTC_PEER_CONNECTION_STATE_CONNECTED && self->events_.onConnected) self->events_.onConnected();
            if (s == GST_WEBRTC_PEER_CONNECTION_STATE_FAILED && self->events_.onFailed) self->events_.onFailed();
        });
    }

    static void onIceState(GstElement *webrtc, GParamSpec *, gpointer user) {
        auto *self = static_cast<GstRtcSession *>(user);
        GstWebRTCICEConnectionState s = GST_WEBRTC_ICE_CONNECTION_STATE_NEW;
        g_object_get(webrtc, "ice-connection-state", &s, nullptr);
        static const char *names[] = {"NEW", "CHECKING", "CONNECTED", "COMPLETED", "FAILED", "DISCONNECTED", "CLOSED"};
        std::weak_ptr<bool> alive = self->alive_;
        onMain([self, alive, s] {
            auto a = alive.lock();
            if (!a || !*a) return;
            log(QStringLiteral("GStreamer ICE %1").arg(names[std::min<int>(s, 6)]));
            // connection-state в 1.20 отстаёт от ICE — «соединено» берём и отсюда
            if ((s == GST_WEBRTC_ICE_CONNECTION_STATE_CONNECTED || s == GST_WEBRTC_ICE_CONNECTION_STATE_COMPLETED) && self->events_.onConnected) {
                self->events_.onConnected();
            }
            if (s == GST_WEBRTC_ICE_CONNECTION_STATE_FAILED && self->events_.onFailed) self->events_.onFailed();
        });
    }

    static GstBusSyncReply onBusMessage(GstBus *, GstMessage *msg, gpointer) {
        const GstMessageType t = GST_MESSAGE_TYPE(msg);
        if (t == GST_MESSAGE_ERROR || t == GST_MESSAGE_WARNING) {
            GError *err = nullptr;
            gchar *debug = nullptr;
            if (t == GST_MESSAGE_ERROR) gst_message_parse_error(msg, &err, &debug);
            else gst_message_parse_warning(msg, &err, &debug);
            const QString text = QStringLiteral("GStreamer %1 from %2: %3 (%4)")
                                     .arg(t == GST_MESSAGE_ERROR ? "ERROR" : "WARNING", QString::fromUtf8(GST_OBJECT_NAME(msg->src)),
                                          describe(err), QString::fromUtf8(debug ? debug : ""));
            if (err) g_error_free(err);
            g_free(debug);
            const bool error = t == GST_MESSAGE_ERROR;
            onMain([text, error] { error ? logError(text) : log(text); });
        }
        return GST_BUS_DROP;
    }

    /// Входящий поток: звук — в микшер вывода (за ним эхо-зонд для webrtcdsp), видео — кадры RGBA на экран звонка.
    static void onPadAdded(GstElement *, GstPad *pad, gpointer user) {
        auto *self = static_cast<GstRtcSession *>(user);
        if (GST_PAD_DIRECTION(pad) != GST_PAD_SRC || !self->pipeline_) return;
        gst_pad_add_probe(pad, GST_PAD_PROBE_TYPE_BUFFER, &countBuffers, &self->rtpIn_, nullptr);
        GstElement *decode = gst_element_factory_make("decodebin", nullptr);
        g_signal_connect(decode, "pad-added", G_CALLBACK(&GstRtcSession::onDecodedPad), self);
        gst_bin_add(GST_BIN(self->pipeline_), decode);
        gst_element_sync_state_with_parent(decode);
        GstPad *sink = gst_element_get_static_pad(decode, "sink");
        linkOrLog(pad, sink);
        gst_object_unref(sink);
    }

    static void onDecodedPad(GstElement *, GstPad *pad, gpointer user) {
        auto *self = static_cast<GstRtcSession *>(user);
        GstCaps *caps = gst_pad_get_current_caps(pad);
        const gchar *name = caps ? gst_structure_get_name(gst_caps_get_structure(caps, 0)) : "";
        const bool audio = g_str_has_prefix(name, "audio");
        const bool video = g_str_has_prefix(name, "video");
        if (caps) gst_caps_unref(caps);
        onMain([audio] { log(QStringLiteral("GStreamer incoming %1 linked").arg(audio ? "audio" : "video")); });
        if (audio && self->speaker_) {
            // микшер — внутри bin вывода: снаружи к нему только через ghost-пад, иначе связь не
            // создаётся (wrong hierarchy), первый же пакет — not-linked, и приём встаёт целиком
            GstPad *mixPad = gst_element_request_pad_simple(self->speaker_, "sink_%u");
            GstPad *ghost = gst_ghost_pad_new(nullptr, mixPad);
            gst_object_unref(mixPad);
            gst_pad_set_active(ghost, TRUE);
            gst_element_add_pad(self->outBin_, ghost);
            linkOrLog(pad, ghost);
            return;
        }
        GError *err = nullptr;
        const char *desc = audio ? "audioconvert ! audioresample ! autoaudiosink async-handling=true"
                         : video ? "queue leaky=downstream max-size-buffers=2 ! videoconvert ! capsfilter caps=video/x-raw,format=RGBA ! "
                                   "appsink name=remoteview emit-signals=true sync=false async=false max-buffers=1 drop=true"
                                 : "fakesink sync=false async=false";
        GstElement *bin = gst_parse_bin_from_description(desc, TRUE, &err);
        if (!bin) {
            const QString e = describe(err);
            onMain([e] { logError("GStreamer: вывод не собран: " + e); });
            return;
        }
        if (video) g_signal_connect(self->child(bin, "remoteview"), "new-sample", G_CALLBACK(&GstRtcSession::onRemoteSample), self);
        gst_bin_add(GST_BIN(self->pipeline_), bin);
        gst_element_sync_state_with_parent(bin);
        GstPad *sink = gst_element_get_static_pad(bin, "sink");
        linkOrLog(pad, sink);
        gst_object_unref(sink);
    }

    static void linkOrLog(GstPad *src, GstPad *sink) {
        const GstPadLinkReturn r = gst_pad_link(src, sink);
        if (r != GST_PAD_LINK_OK) {
            const QString what = QString::fromUtf8(gst_pad_link_get_name(r));
            onMain([what] { logError("GStreamer: входящий поток не подключён: " + what); });
        }
    }

    static GstFlowReturn onLocalSample(GstElement *sink, gpointer user) { return static_cast<GstRtcSession *>(user)->deliverSample(sink, true); }
    static GstFlowReturn onRemoteSample(GstElement *sink, gpointer user) { return static_cast<GstRtcSession *>(user)->deliverSample(sink, false); }

    /// Кадр RGBA → главный поток. Пока предыдущий не показан, новые пропускаются — очередь не растёт.
    GstFlowReturn deliverSample(GstElement *sink, bool local) {
        GstSample *sample = nullptr;
        g_signal_emit_by_name(sink, "pull-sample", &sample);
        if (!sample) return GST_FLOW_OK;
        std::atomic<bool> &busy = local ? localPending_ : remotePending_;
        if (busy.exchange(true)) {
            gst_sample_unref(sample);
            return GST_FLOW_OK;
        }
        VideoFrame frame;
        const GstStructure *st = gst_caps_get_structure(gst_sample_get_caps(sample), 0);
        gst_structure_get_int(st, "width", &frame.width);
        gst_structure_get_int(st, "height", &frame.height);
        GstMapInfo map;
        GstBuffer *buf = gst_sample_get_buffer(sample);
        const gsize need = gsize(frame.width) * gsize(frame.height) * 4;
        if (buf && need > 0 && gst_buffer_map(buf, &map, GST_MAP_READ)) {
            if (map.size >= need) frame.rgba = QByteArray(reinterpret_cast<const char *>(map.data), qsizetype(need));
            gst_buffer_unmap(buf, &map);
        }
        gst_sample_unref(sample);
        std::weak_ptr<bool> alive = alive_;
        onMain([this, alive, local, frame] {
            auto a = alive.lock();
            if (!a || !*a) return;
            (local ? localPending_ : remotePending_) = false;
            if (!frame.rgba.isEmpty() && events_.onVideoFrame) events_.onVideoFrame(local, frame);
        });
        return GST_FLOW_OK;
    }

    GstRtcEngine &engine_;
    RtcEvents events_;
    std::shared_ptr<bool> alive_;
    GstElement *pipeline_ = nullptr;
    GstElement *webrtc_ = nullptr;
    GstElement *micVolume_ = nullptr;
    GstElement *speaker_ = nullptr;
    GstElement *outBin_ = nullptr;
    GstElement *mic_ = nullptr;
    GstElement *spk_ = nullptr;
    GstElement *videoBin_ = nullptr;
    std::atomic<bool> localPending_{false}, remotePending_{false};
    std::atomic<int> rtpOut_{0}, rtpIn_{0};
    int lastOut_ = 0, lastIn_ = 0;
    bool videoWanted_ = false, videoOfferSent_ = false, videoNegotiated_ = false;
    QStringList localMids_;
    std::optional<QString> dtlsRole_;
    QHash<QString, int> negotiated_;  // mid → итоговое направление для нас (биты dirBits)
    QHash<QString, int> offeredDirs_; // наш последний offer — до ответа собеседника // своя роль DTLS в этом звонке (active / passive)
    bool audioAdded_ = false;
};

} // namespace

GstRtcEngine::GstRtcEngine() : testVideo_(qEnvironmentVariableIntValue("OSHINOBU_TEST_VIDEO") == 1) { gst_init(nullptr, nullptr); }

std::unique_ptr<RtcSession> GstRtcEngine::createSession(const QList<IceServer> &servers, RtcEvents events) {
    beginCallLog();
    return std::make_unique<GstRtcSession>(*this, servers, std::move(events));
}

namespace {
std::mutex callLogMutex;
FILE *callLog = nullptr;
qint64 callLogBytes = 0;
constexpr qint64 CallLogMaxBytes = 30LL * 1024 * 1024;

void writeCallLog(GstDebugCategory *category, GstDebugLevel level, const gchar *file, const gchar *function, gint line, GObject *object,
                  GstDebugMessage *message, gpointer) {
    if (level > gst_debug_category_get_threshold(category)) return;
    std::lock_guard<std::mutex> lock(callLogMutex);
    if (!callLog || callLogBytes > CallLogMaxBytes) return;
    const gchar *obj = object && GST_IS_OBJECT(object) ? GST_OBJECT_NAME(object) : "";
    const int n = fprintf(callLog, "%s %-6s %s %s:%d:%s <%s> %s\n", QTime::currentTime().toString("HH:mm:ss.zzz").toUtf8().constData(),
                          gst_debug_level_get_name(level), gst_debug_category_get_name(category), file, line, function, obj ? obj : "",
                          gst_debug_message_get(message));
    if (n > 0) callLogBytes += n;
}
} // namespace

void GstRtcEngine::beginCallLog() {
    if (debugLogPath_.isEmpty()) return;
    std::lock_guard<std::mutex> lock(callLogMutex);
    if (callLog) fclose(callLog);
    callLog = fopen(debugLogPath_.toUtf8().constData(), "w");
    callLogBytes = 0;
    static bool installed = false;
    if (!installed) {
        gst_debug_add_log_function(&writeCallLog, nullptr, nullptr);
        installed = true;
    }
    // только то, что нужно для разбора звонка: согласование, RTP/демультиплексор, ICE, DTLS, ошибки
    gst_debug_set_threshold_from_string("2,webrtcbin:5,webrtctransportsendbin:4,webrtctransportreceivebin:4,rtpbin:5,rtpssrcdemux:5,"
                                        "rtpptdemux:5,rtpjitterbuffer:3,rtpsession:4,nicesrc:4,nicesink:3,webrtcice:4,dtlsdec:4,dtlssrtpdec:4,"
                                        "srtpdec:4,decodebin:4,vp8dec:3,rtpvp8depay:4",
                                        TRUE);
}

void GstRtcEngine::endCallLog() {
    std::lock_guard<std::mutex> lock(callLogMutex);
    if (callLog) {
        fclose(callLog);
        callLog = nullptr;
    }
    gst_debug_set_threshold_from_string("1", TRUE);
}

QList<AudioDevice> GstRtcEngine::audioDevices(bool input) { return listAudioDevices(input); }

void GstRtcEngine::setPreferredAudioDevice(bool input, const QString &id) { (input ? preferredIn_ : preferredOut_) = id; }

bool GstRtcEngine::hasCamera() {
    if (testVideo_) return true;
    GstDeviceMonitor *mon = gst_device_monitor_new();
    gst_device_monitor_add_filter(mon, "Video/Source", nullptr);
    bool found = false;
    if (gst_device_monitor_start(mon)) {
        GList *devices = gst_device_monitor_get_devices(mon);
        found = devices != nullptr;
        g_list_free_full(devices, gst_object_unref);
        gst_device_monitor_stop(mon);
    }
    gst_object_unref(mon);
    return found;
}

} // namespace osh

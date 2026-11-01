#pragma once

// WebRTC на GStreamer (webrtcbin) за интерфейсом RtcEngine — совместим с libwebrtc
// на Android/iOS: unified plan, max-bundle, Opus и VP8. Звук: микрофон (PulseAudio /
// PipeWire, выбранное устройство) → webrtcdsp (эхо- и шумоподавление) → Opus;
// входящий — decodebin → микшер → webrtcechoprobe → вывод. Видео: камера (v4l2) →
// VP8, своё превью и кадры собеседника — RGBA в RtcEvents::onVideoFrame.
// Сигналы webrtcbin приходят из его потоков и переносятся в главный поток Qt.

#include "service/Calls.h"

namespace osh {

class GstRtcEngine : public RtcEngine {
public:
    GstRtcEngine();
    std::unique_ptr<RtcSession> createSession(const QList<IceServer> &servers, RtcEvents events) override;
    QList<AudioDevice> audioDevices(bool input) override;
    void setPreferredAudioDevice(bool input, const QString &id) override;
    bool hasCamera() override;

    QString preferredAudioDevice(bool input) const { return input ? preferredIn_ : preferredOut_; }
    /// OSHINOBU_TEST_VIDEO=1 — тестовая картинка вместо камеры (проверки без устройства).
    bool testVideo() const { return testVideo_; }
    /// Подробный журнал GStreamer (webrtcbin, rtpbin, ICE/DTLS) на время звонка — в этот файл,
    /// перезаписывается на каждый звонок, не больше 30 МБ. Пусто — не писать.
    void setCallDebugLog(const QString &path) { debugLogPath_ = path; }
    void beginCallLog();
    void endCallLog();

private:
    QString preferredIn_, preferredOut_;
    bool testVideo_ = false;
    QString debugLogPath_;
};

} // namespace osh

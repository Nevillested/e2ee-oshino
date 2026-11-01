#pragma once

// Запись голосового (AAC в m4a, как MediaRecorder на Android) и видео-кружка (H.264 + AAC в
// mp4, качество SD, как CameraX на Android) на GStreamer. У кружка — живое превью кадрами RGBA.
// Остановка с сохранением — через EOS: mp4mux дописывает индекс (moov) только по концу потока.

#include "service/Calls.h"

#include <QElapsedTimer>
#include <QObject>
#include <memory>

namespace osh {

class GstRecorder : public QObject {
    Q_OBJECT
public:
    enum class Kind { Voice, VideoNote };

    explicit GstRecorder(QObject *parent = nullptr);
    ~GstRecorder() override;

    /// [micDevice] — имя устройства PulseAudio (пусто — системное); [testVideo] — тестовая
    /// картинка вместо камеры. false — не началось (причина в failed).
    bool start(Kind kind, const QString &path, const QString &micDevice = {}, bool testVideo = false);
    /// keep — дописать файл и сообщить finished; иначе — бросить запись и удалить файл.
    void stop(bool keep);
    bool isRecording() const { return pipeline_ != nullptr && !stopping_; }
    qint64 elapsedMs() const { return timer_.isValid() ? timer_.elapsed() : 0; }

Q_SIGNALS:
    /// Файл дописан. [firstFrame] — первый кадр кружка (миниатюра своего пузыря), у голосового пуст.
    void finished(const QString &path, qint64 durationMs, const osh::VideoFrame &firstFrame);
    void failed(const QString &reason);
    void previewFrame(const osh::VideoFrame &frame);

private:
    void teardown();
    void complete();

    struct Shared;
    std::shared_ptr<Shared> shared_;
    void *pipeline_ = nullptr; // GstElement*
    QString path_;
    QElapsedTimer timer_;
    qint64 duration_ = 0;
    bool stopping_ = false;
    VideoFrame firstFrame_;
};

} // namespace osh

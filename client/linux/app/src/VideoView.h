#pragma once

// Видео звонка в QML: VideoView { local: true } — своя камера, false — собеседник.
// Кадры (RGBA из GstRtcEngine) приходят в общий VideoFrames и рисуются с обрезкой «заполнить».

#include <QImage>
#include <QQuickPaintedItem>

class QVideoSink;

class VideoFrames : public QObject {
    Q_OBJECT
public:
    static VideoFrames &instance();
    void set(bool local, QImage frame);
    void clear();
    const QImage &frame(bool local) const { return local ? local_ : remote_; }

Q_SIGNALS:
    void frameChanged(bool local);

private:
    QImage local_, remote_;
};

class VideoView : public QQuickPaintedItem {
    Q_OBJECT
    Q_PROPERTY(bool local READ local WRITE setLocal NOTIFY localChanged)
    /// Есть ли кадр — пока нет, QML показывает аватар.
    Q_PROPERTY(bool hasFrame READ hasFrame NOTIFY hasFrameChanged)
    /// Своё превью — зеркально, как в зеркале (и на Android).
    Q_PROPERTY(bool mirrored MEMBER mirrored_ NOTIFY localChanged)
    /// Скругление углов (половина стороны — круг); рисуется здесь же, без масок.
    Q_PROPERTY(qreal radius MEMBER radius_ NOTIFY localChanged)
    /// Приёмник кадров для MediaPlayer.videoOutput (кружок): VideoOutput в Qt 6.2 не рисуется
    /// под маской-слоем, а здесь скругление своё. Пока его не спросили, вид — кадры звонка.
    Q_PROPERTY(QObject *videoSink READ videoSink CONSTANT)
public:
    explicit VideoView(QQuickItem *parent = nullptr);
    bool local() const { return local_; }
    void setLocal(bool local);
    bool hasFrame() const { return !frame().isNull(); }
    QObject *videoSink();
    void paint(QPainter *painter) override;

Q_SIGNALS:
    void localChanged();
    void hasFrameChanged();

private:
    bool local_ = false;
    bool mirrored_ = false;
    bool hadFrame_ = false;
    qreal radius_ = 0;
    QVideoSink *sink_ = nullptr;
    QImage own_;
    const QImage &frame() const { return sink_ ? own_ : VideoFrames::instance().frame(local_); }
};

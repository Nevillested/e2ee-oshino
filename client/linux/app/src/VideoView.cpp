#include "VideoView.h"

#include <QPainter>
#include <QPainterPath>
#include <QVideoFrame>
#include <QVideoSink>

VideoFrames &VideoFrames::instance() {
    static VideoFrames frames;
    return frames;
}

void VideoFrames::set(bool local, QImage frame) {
    (local ? local_ : remote_) = std::move(frame);
    Q_EMIT frameChanged(local);
}

void VideoFrames::clear() {
    local_ = {};
    remote_ = {};
    Q_EMIT frameChanged(true);
    Q_EMIT frameChanged(false);
}

VideoView::VideoView(QQuickItem *parent) : QQuickPaintedItem(parent) {
    connect(&VideoFrames::instance(), &VideoFrames::frameChanged, this, [this](bool local) {
        if (sink_ || local != local_) return;
        if (hasFrame() != hadFrame_) {
            hadFrame_ = hasFrame();
            Q_EMIT hasFrameChanged();
        }
        update();
    });
}

QObject *VideoView::videoSink() {
    if (!sink_) {
        sink_ = new QVideoSink(this);
        connect(sink_, &QVideoSink::videoFrameChanged, this, [this](const QVideoFrame &f) {
            own_ = f.toImage();
            if (hasFrame() != hadFrame_) {
                hadFrame_ = hasFrame();
                Q_EMIT hasFrameChanged();
            }
            update();
        });
    }
    return sink_;
}

void VideoView::setLocal(bool local) {
    if (local_ == local) return;
    local_ = local;
    mirrored_ = local;
    Q_EMIT localChanged();
    Q_EMIT hasFrameChanged();
    update();
}

void VideoView::paint(QPainter *painter) {
    const QImage &img = frame();
    if (img.isNull() || width() <= 0 || height() <= 0) return;
    // «заполнить»: масштаб по большей стороне, лишнее обрезается по центру
    const qreal k = std::max(width() / img.width(), height() / img.height());
    const QSizeF size(img.width() * k, img.height() * k);
    const QRectF target((width() - size.width()) / 2, (height() - size.height()) / 2, size.width(), size.height());
    painter->setRenderHint(QPainter::SmoothPixmapTransform);
    painter->setRenderHint(QPainter::Antialiasing);
    if (radius_ > 0) {
        QPainterPath clip;
        clip.addRoundedRect(QRectF(0, 0, width(), height()), radius_, radius_);
        painter->setClipPath(clip);
    }
    if (mirrored_) {
        painter->translate(width(), 0);
        painter->scale(-1, 1);
    }
    painter->drawImage(target, img);
}

#include "TgsItem.h"

#include "support/Log.h"

#include <QFile>
#include <QPainter>
#include <QUrl>
#include <rlottie.h>
#include <zlib.h>

namespace {
/// TGS — gzip; распаковать в JSON.
std::string gunzip(const QByteArray &in) {
    z_stream zs{};
    if (inflateInit2(&zs, 16 + MAX_WBITS) != Z_OK) return {};
    zs.next_in = reinterpret_cast<Bytef *>(const_cast<char *>(in.constData()));
    zs.avail_in = uInt(in.size());
    std::string out;
    char buf[64 * 1024];
    int rc;
    do {
        zs.next_out = reinterpret_cast<Bytef *>(buf);
        zs.avail_out = sizeof(buf);
        rc = inflate(&zs, Z_NO_FLUSH);
        out.append(buf, sizeof(buf) - zs.avail_out);
    } while (rc == Z_OK);
    inflateEnd(&zs);
    return rc == Z_STREAM_END ? out : std::string();
}
} // namespace

TgsItem::TgsItem(QQuickItem *parent) : QQuickPaintedItem(parent) {
    connect(&timer_, &QTimer::timeout, this, &TgsItem::nextFrame);
}

TgsItem::~TgsItem() = default;

void TgsItem::setSource(const QString &s) {
    if (s == source_) return;
    source_ = s;
    timer_.stop();
    anim_.reset();
    QFile f(QUrl(s).isLocalFile() ? QUrl(s).toLocalFile() : s);
    if (f.open(QIODevice::ReadOnly)) {
        const std::string json = gunzip(f.readAll());
        if (!json.empty()) anim_ = rlottie::Animation::loadFromData(json, s.toStdString());
    }
    if (anim_) {
        total_ = anim_->totalFrame();
        index_ = 0;
        const double fps = anim_->frameRate();
        timer_.start(int(1000.0 / (fps > 0 ? fps : 30)));
        nextFrame();
    }
    Q_EMIT sourceChanged();
}

void TgsItem::nextFrame() {
    if (!anim_ || width() < 1 || height() < 1) return;
    const int w = int(width()), h = int(height());
    if (frame_.size() != QSize(w, h)) frame_ = QImage(w, h, QImage::Format_ARGB32_Premultiplied);
    rlottie::Surface surface(reinterpret_cast<uint32_t *>(frame_.bits()), size_t(w), size_t(h), size_t(frame_.bytesPerLine()));
    anim_->renderSync(index_, surface);
    index_ = total_ ? (index_ + 1) % total_ : 0;
    update();
}

void TgsItem::paint(QPainter *painter) {
    if (!frame_.isNull()) painter->drawImage(QRectF(0, 0, width(), height()), frame_);
}

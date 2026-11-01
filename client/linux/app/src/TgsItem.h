#pragma once

// Анимированный стикер TGS (Lottie JSON в gzip) — кадры рисует rlottie.

#include <QImage>
#include <QQuickPaintedItem>
#include <QTimer>
#include <memory>

namespace rlottie {
class Animation;
}

class TgsItem : public QQuickPaintedItem {
    Q_OBJECT
    Q_PROPERTY(QString source READ source WRITE setSource NOTIFY sourceChanged)
public:
    explicit TgsItem(QQuickItem *parent = nullptr);
    ~TgsItem() override;
    QString source() const { return source_; }
    void setSource(const QString &s);
    void paint(QPainter *painter) override;

Q_SIGNALS:
    void sourceChanged();

private:
    void nextFrame();
    QString source_;
    std::unique_ptr<rlottie::Animation> anim_;
    QImage frame_;
    size_t index_ = 0, total_ = 0;
    QTimer timer_;
};

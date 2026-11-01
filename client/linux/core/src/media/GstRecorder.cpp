#include "media/GstRecorder.h"

#include "support/Log.h"

#include <QCoreApplication>
#include <QFile>
#include <QMetaObject>
#include <QTimer>

#include <gst/gst.h>

#include <atomic>

namespace osh {

namespace {

template <typename F>
void onMain(F fn) {
    QMetaObject::invokeMethod(QCoreApplication::instance(), std::move(fn), Qt::QueuedConnection);
}

bool hasFactory(const char *name) {
    GstElementFactory *f = gst_element_factory_find(name);
    if (f) gst_object_unref(f);
    return f != nullptr;
}

QString quoted(const QString &s) { return "\"" + QString(s).replace("\\", "\\\\").replace("\"", "\\\"") + "\""; }

} // namespace

/// Общее с потоками GStreamer: живо, пока жив рекордер (колбэки проверяют alive).
struct GstRecorder::Shared {
    GstRecorder *owner = nullptr;
    std::atomic<bool> alive{true};
    std::atomic<bool> framePending{false};
};

GstRecorder::GstRecorder(QObject *parent) : QObject(parent), shared_(std::make_shared<Shared>()) {
    gst_init(nullptr, nullptr);
    shared_->owner = this;
}

GstRecorder::~GstRecorder() {
    shared_->alive = false;
    if (pipeline_) {
        teardown();
        QFile::remove(path_);
    }
}

bool GstRecorder::start(Kind kind, const QString &path, const QString &micDevice, bool testVideo) {
    if (pipeline_) return false;
    const bool pulse = hasFactory("pulsesrc");
    const QString mic = pulse ? (micDevice.isEmpty() ? QStringLiteral("pulsesrc") : "pulsesrc device=" + quoted(micDevice)) : QStringLiteral("autoaudiosrc");
    // звук как у Android: AAC 64 кбит/с, моно
    const QString audio = mic + " ! audioconvert ! audioresample ! audio/x-raw,rate=48000,channels=1 ! voaacenc bitrate=64000 ! aacparse ! queue ! mux.";
    QString desc;
    if (kind == Kind::Voice) {
        desc = audio + " mp4mux name=mux faststart=true ! filesink location=" + quoted(path);
    } else {
        // SD 640×480 (как Quality.SD у CameraX) → H.264 baseline (openh264) — играет любой Android
        desc = QStringLiteral("%1 ! videoconvert ! videoscale ! videorate ! "
                              "video/x-raw,width=640,height=480,pixel-aspect-ratio=1/1,framerate=30/1 ! tee name=t "
                              "t. ! queue max-size-buffers=0 max-size-time=0 max-size-bytes=0 ! videoconvert ! video/x-raw,format=I420 ! "
                              "openh264enc bitrate=1200000 complexity=low ! h264parse ! queue ! mux. "
                              "t. ! queue leaky=downstream max-size-buffers=1 ! videoconvert ! videoscale ! "
                              "video/x-raw,format=RGBA,width=320,height=240 ! "
                              "appsink name=preview emit-signals=true sync=false async=false max-buffers=1 drop=true ")
                   .arg(testVideo ? "videotestsrc is-live=true pattern=ball" : "v4l2src") +
               audio + " mp4mux name=mux faststart=true ! filesink location=" + quoted(path);
    }
    GError *err = nullptr;
    GstElement *pipeline = gst_parse_launch(desc.toUtf8().constData(), &err);
    if (!pipeline || err) {
        const QString reason = err ? QString::fromUtf8(err->message) : QStringLiteral("?");
        if (err) g_error_free(err);
        if (pipeline) gst_object_unref(pipeline);
        logError("GstRecorder: не собрано: " + reason);
        Q_EMIT failed(reason);
        return false;
    }
    pipeline_ = pipeline;
    path_ = path;
    stopping_ = false;
    firstFrame_ = {};
    shared_->alive = true;

    std::weak_ptr<Shared> weak = shared_;
    if (kind == Kind::VideoNote) {
        GstElement *sink = gst_bin_get_by_name(GST_BIN(pipeline), "preview");
        auto onSample = +[](GstElement *appsink, gpointer user) -> GstFlowReturn {
            auto *w = static_cast<std::weak_ptr<Shared> *>(user);
            auto sh = w->lock();
            GstSample *sample = nullptr;
            g_signal_emit_by_name(appsink, "pull-sample", &sample);
            if (!sample) return GST_FLOW_OK;
            if (!sh || !sh->alive || sh->framePending.exchange(true)) {
                gst_sample_unref(sample);
                return GST_FLOW_OK;
            }
            VideoFrame frame;
            const GstStructure *st = gst_caps_get_structure(gst_sample_get_caps(sample), 0);
            gst_structure_get_int(st, "width", &frame.width);
            gst_structure_get_int(st, "height", &frame.height);
            GstBuffer *buf = gst_sample_get_buffer(sample);
            GstMapInfo map;
            const gsize need = gsize(frame.width) * gsize(frame.height) * 4;
            if (buf && need > 0 && gst_buffer_map(buf, &map, GST_MAP_READ)) {
                if (map.size >= need) frame.rgba = QByteArray(reinterpret_cast<const char *>(map.data), qsizetype(need));
                gst_buffer_unmap(buf, &map);
            }
            gst_sample_unref(sample);
            std::weak_ptr<Shared> again = sh;
            onMain([again, frame] {
                auto s = again.lock();
                if (!s) return;
                s->framePending = false;
                if (!s->alive || frame.rgba.isEmpty()) return;
                if (s->owner->firstFrame_.rgba.isEmpty()) s->owner->firstFrame_ = frame;
                Q_EMIT s->owner->previewFrame(frame);
            });
            return GST_FLOW_OK;
        };
        g_signal_connect_data(sink, "new-sample", G_CALLBACK(onSample), new std::weak_ptr<Shared>(weak),
                              [](gpointer data, GClosure *) { delete static_cast<std::weak_ptr<Shared> *>(data); }, GConnectFlags(0));
        gst_object_unref(sink);
    }

    GstBus *bus = gst_element_get_bus(pipeline);
    auto onBus = +[](GstBus *, GstMessage *msg, gpointer user) -> GstBusSyncReply {
        auto sh = static_cast<std::weak_ptr<Shared> *>(user)->lock();
        if (!sh) return GST_BUS_DROP;
        const GstMessageType t = GST_MESSAGE_TYPE(msg);
        if (t == GST_MESSAGE_EOS) {
            std::weak_ptr<Shared> w = sh;
            onMain([w] {
                if (auto s = w.lock(); s && s->alive) s->owner->complete();
            });
        } else if (t == GST_MESSAGE_ERROR) {
            GError *err = nullptr;
            gchar *debug = nullptr;
            gst_message_parse_error(msg, &err, &debug);
            const QString text = QStringLiteral("%1 (%2)").arg(QString::fromUtf8(err ? err->message : "?"), QString::fromUtf8(debug ? debug : ""));
            if (err) g_error_free(err);
            g_free(debug);
            std::weak_ptr<Shared> w = sh;
            onMain([w, text] {
                auto s = w.lock();
                if (!s || !s->alive) return;
                logError("GstRecorder: " + text);
                GstRecorder *self = s->owner;
                self->shared_->alive = false;
                self->teardown();
                QFile::remove(self->path_);
                Q_EMIT self->failed(text);
            });
        }
        return GST_BUS_DROP;
    };
    gst_bus_set_sync_handler(bus, onBus, new std::weak_ptr<Shared>(weak), [](gpointer data) { delete static_cast<std::weak_ptr<Shared> *>(data); });
    gst_object_unref(bus);

    if (gst_element_set_state(pipeline, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) {
        teardown();
        Q_EMIT failed(QStringLiteral("не удалось начать запись"));
        return false;
    }
    timer_.start();
    return true;
}

void GstRecorder::stop(bool keep) {
    if (!pipeline_ || stopping_) return;
    duration_ = timer_.elapsed();
    timer_.invalidate();
    if (!keep) {
        shared_->alive = false;
        teardown();
        QFile::remove(path_);
        shared_ = std::make_shared<Shared>();
        shared_->owner = this;
        return;
    }
    stopping_ = true;
    // конец потока: mp4mux допишет индекс; EOS придёт на шину → complete()
    gst_element_send_event(static_cast<GstElement *>(pipeline_), gst_event_new_eos());
    std::weak_ptr<Shared> weak = shared_;
    QTimer::singleShot(4000, this, [this, weak] {
        auto s = weak.lock();
        if (s && s->alive && stopping_) {
            logError("GstRecorder: EOS не пришёл за 4 с — файл может быть неполным");
            complete();
        }
    });
}

void GstRecorder::complete() {
    if (!pipeline_) return;
    teardown();
    stopping_ = false;
    shared_ = std::make_shared<Shared>(); // старые колбэки больше ничего не трогают
    shared_->owner = this;
    Q_EMIT finished(path_, duration_, firstFrame_);
}

void GstRecorder::teardown() {
    if (!pipeline_) return;
    auto *p = static_cast<GstElement *>(pipeline_);
    pipeline_ = nullptr;
    gst_element_set_state(p, GST_STATE_NULL);
    gst_object_unref(p);
}

} // namespace osh

// Запись голосового и кружка: файл дописан (есть индекс moov), длительность и первый кадр.

#include "media/GstRecorder.h"

#include <QFile>
#include <QTemporaryDir>
#include <QtTest>

using namespace osh;

class GstRecorderTest : public QObject {
    Q_OBJECT

    void record(GstRecorder::Kind kind, const QString &path) {
        GstRecorder rec;
        bool done = false;
        qint64 duration = 0;
        VideoFrame first;
        int previews = 0;
        connect(&rec, &GstRecorder::finished, this, [&](const QString &, qint64 d, const VideoFrame &f) { done = true; duration = d; first = f; });
        connect(&rec, &GstRecorder::previewFrame, this, [&](const VideoFrame &) { ++previews; });
        connect(&rec, &GstRecorder::failed, this, [&](const QString &r) { QFAIL(qPrintable(r)); });
        QVERIFY(rec.start(kind, path, {}, true));
        QTest::qWait(2000);
        rec.stop(true);
        QTRY_VERIFY_WITH_TIMEOUT(done, 6000);
        QVERIFY(duration >= 1900);
        QFile f(path);
        QVERIFY(f.open(QIODevice::ReadOnly));
        const QByteArray data = f.readAll();
        QVERIFY2(data.size() > 4000, qPrintable(QString::number(data.size())));
        QVERIFY(data.contains("moov"));
        if (kind == GstRecorder::Kind::VideoNote) {
            QVERIFY(previews > 5);
            QVERIFY(first.width == 320 && !first.rgba.isEmpty());
            QVERIFY(data.contains("avc1"));
        }
        QVERIFY(data.contains("mp4a"));
    }

private Q_SLOTS:
    void voice() {
        QTemporaryDir dir;
        record(GstRecorder::Kind::Voice, dir.filePath("v.m4a"));
    }
    void videoNote() {
        QTemporaryDir dir;
        record(GstRecorder::Kind::VideoNote, dir.filePath("n.mp4"));
    }
    void cancelRemovesFile() {
        QTemporaryDir dir;
        GstRecorder rec;
        QVERIFY(rec.start(GstRecorder::Kind::Voice, dir.filePath("c.m4a")));
        QTest::qWait(500);
        rec.stop(false);
        QTest::qWait(200);
        QVERIFY(!QFile::exists(dir.filePath("c.m4a")));
    }
};

QTEST_GUILESS_MAIN(GstRecorderTest)
#include "GstRecorderTest.moc"

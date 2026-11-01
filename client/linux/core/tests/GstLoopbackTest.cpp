// Два сеанса GstRtcEngine в одном процессе: offer/answer/ICE друг другу — соединение должно
// установиться (onConnected у обоих). Звук: микрофон и вывод — настоящие устройства системы.

#include "media/GstRtcEngine.h"
#include "support/Task.h"

#include <QRegularExpression>
#include <QtTest>

using namespace osh;

class GstLoopbackTest : public QObject {
    Q_OBJECT

private Q_SLOTS:
    void connectsBothWays() {
        qputenv("OSHINOBU_TEST_VIDEO", "1"); // тестовая картинка вместо камеры
        GstRtcEngine engine;
        std::unique_ptr<RtcSession> a, b;
        bool aConnected = false, bConnected = false, failed = false;
        int aLocalFrames = 0, bRemoteFrames = 0, aRemoteFrames = 0;
        bool bRenegotiationNeeded = false;
        RtcEvents ea, eb;
        ea.onIceCandidate = [&](QString c, QString mid, int idx) { spawn(b->addIceCandidate(c, mid, idx)); };
        eb.onIceCandidate = [&](QString c, QString mid, int idx) { spawn(a->addIceCandidate(c, mid, idx)); };
        ea.onConnected = [&] { aConnected = true; };
        eb.onConnected = [&] { bConnected = true; };
        ea.onFailed = [&] { failed = true; };
        eb.onFailed = [&] { failed = true; };
        ea.onVideoFrame = [&](bool local, VideoFrame f) {
            if (local && f.width > 0) ++aLocalFrames;
            if (!local && f.width > 0) ++aRemoteFrames;
        };
        eb.onRenegotiationNeeded = [&] { bRenegotiationNeeded = true; };
        eb.onVideoFrame = [&](bool local, VideoFrame f) { if (!local && f.width > 0) ++bRemoteFrames; };
        // как в жизни: STUN Google и TURN сервера (без верных учётных данных — проверка, что
        // сбор кандидатов через них не блокирует webrtcbin)
        QList<IceServer> servers;
        if (qEnvironmentVariableIsSet("WITH_ICE_SERVERS")) {
            servers << IceServer{{"stun:stun.l.google.com:19302"}, {}, {}};
            servers << IceServer{{"turn:195.19.66.107:3478?transport=udp", "turn:195.19.66.107:3478?transport=tcp"}, "1:test", "x"};
        }
        a = engine.createSession(servers, ea);
        b = engine.createSession(servers, eb);

        auto negotiate = [](RtcSession *a, RtcSession *b, bool *done, QString *error) -> Task<void> {
            try {
                co_await a->startAudio(true);
                const QString offer = co_await a->createOffer();
                // как в жизни: собеседник берёт трубку через несколько секунд
                const int answerDelay = qEnvironmentVariableIntValue("ANSWER_DELAY_MS");
                if (answerDelay > 0) co_await delay{answerDelay};
                co_await b->setRemoteDescription("offer", offer);
                co_await b->startAudio(true);
                const QString answer = co_await b->createAnswer();
                co_await a->setRemoteDescription("answer", answer);
            } catch (const std::exception &e) {
                *error = QString::fromUtf8(e.what());
            }
            *done = true;
        };
        bool done = false;
        QString error;
        spawn(negotiate(a.get(), b.get(), &done, &error));
        QTRY_VERIFY_WITH_TIMEOUT(done, 10000);
        QVERIFY2(error.isEmpty(), qPrintable(error));
        QTRY_VERIFY_WITH_TIMEOUT((aConnected && bConnected) || failed, 15000);
        QVERIFY(!failed);

        // смена устройств посреди разговора
        const auto mics = engine.audioDevices(true);
        const auto outs = engine.audioDevices(false);
        qInfo() << "mics" << mics.size() << "outputs" << outs.size();
        if (!mics.isEmpty() && !qEnvironmentVariableIsSet("NO_SWITCH")) a->setAudioDevice(true, mics.last().id);
        if (!outs.isEmpty() && !qEnvironmentVariableIsSet("NO_SWITCH")) a->setAudioDevice(false, outs.last().id);

        // видео: A включает камеру → перезапрос (как addTrack на Android) → кадры у B
        auto video = [](RtcSession *a, RtcSession *b, bool *done, QString *error) -> Task<void> {
            try {
                co_await a->setVideoEnabled(true);
                const QString offer = co_await a->createOffer();
                co_await b->setRemoteDescription("offer", offer);
                const QString answer = co_await b->createAnswer();
                co_await a->setRemoteDescription("answer", answer);
            } catch (const std::exception &e) {
                *error = QString::fromUtf8(e.what());
            }
            *done = true;
        };
        done = false;
        spawn(video(a.get(), b.get(), &done, &error));
        QTRY_VERIFY_WITH_TIMEOUT(done, 10000);
        QVERIFY2(error.isEmpty(), qPrintable(error));
        QTRY_VERIFY_WITH_TIMEOUT(aLocalFrames > 5, 10000);
        QTRY_VERIFY_WITH_TIMEOUT(bRemoteFrames > 5, 15000);

        // теперь B включает камеру в ответ (как пользователь, увидевший видео собеседника):
        // B обязан попросить перезапрос и после него слать видео A
        bRenegotiationNeeded = false;
        spawn(b->setVideoEnabled(true));
        QTRY_VERIFY2_WITH_TIMEOUT(bRenegotiationNeeded, "B не попросил перезапрос после включения камеры", 5000);
        done = false;
        spawn(video(b.get(), a.get(), &done, &error));
        QTRY_VERIFY_WITH_TIMEOUT(done, 10000);
        QVERIFY2(error.isEmpty(), qPrintable(error));
        QTRY_VERIFY2_WITH_TIMEOUT(aRemoteFrames > 5, "видео B не дошло до A", 15000);

        // обрыв у Android был через ~6 с после соединения — держим дольше
        QTest::qWait(12000);
        QVERIFY(!failed);
        a->close();
        b->close();
    }

    // offer как у libwebrtc (Android): mid "0", opus/48000/2, RED, G722, DTMF — ответ обязан
    // отправлять наш звук (sendrecv) в той же m-строке, иначе собеседник нас не слышит
    void answersLibwebrtcOffer() {
        GstRtcEngine engine;
        RtcEvents ev;
        auto b = engine.createSession({}, ev);
        const QString offer = QStringLiteral(
            "v=0\r\no=- 4611731400430051336 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\na=group:BUNDLE 0\r\na=extmap-allow-mixed\r\n"
            "a=msid-semantic: WMS stream0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111 63 9 0 8 13 110 126\r\nc=IN IP4 0.0.0.0\r\n"
            "a=rtcp:9 IN IP4 0.0.0.0\r\na=ice-ufrag:abcd\r\na=ice-pwd:abcdefghijklmnopqrstuvwx\r\na=ice-options:trickle renomination\r\n"
            "a=fingerprint:sha-256 12:34:56:78:9A:BC:DE:F0:12:34:56:78:9A:BC:DE:F0:12:34:56:78:9A:BC:DE:F0:12:34:56:78:9A:BC:DE:F0\r\n"
            "a=setup:actpass\r\na=mid:0\r\na=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level\r\n"
            "a=extmap:3 http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01\r\na=extmap:4 urn:ietf:params:rtp-hdrext:sdes:mid\r\n"
            "a=sendrecv\r\na=msid:stream0 audio0\r\na=rtcp-mux\r\na=rtpmap:111 opus/48000/2\r\na=rtcp-fb:111 transport-cc\r\n"
            "a=fmtp:111 minptime=10;useinbandfec=1\r\na=rtpmap:63 red/48000/2\r\na=fmtp:63 111/111\r\na=rtpmap:9 G722/8000\r\n"
            "a=rtpmap:0 PCMU/8000\r\na=rtpmap:8 PCMA/8000\r\na=rtpmap:13 CN/8000\r\na=rtpmap:110 telephone-event/48000\r\n"
            "a=rtpmap:126 telephone-event/8000\r\na=ssrc:1001 cname:abc\r\na=ssrc:1001 msid:stream0 audio0\r\n");
        QString answer, error;
        bool done = false;
        auto flow = [](RtcSession *b, QString offer, QString *answer, QString *error, bool *done) -> Task<void> {
            try {
                co_await b->setRemoteDescription("offer", offer);
                co_await b->startAudio(true);
                *answer = co_await b->createAnswer();
            } catch (const std::exception &e) {
                *error = QString::fromUtf8(e.what());
            }
            *done = true;
        };
        spawn(flow(b.get(), offer, &answer, &error, &done));
        QTRY_VERIFY_WITH_TIMEOUT(done, 10000);
        QVERIFY2(error.isEmpty(), qPrintable(error));
        qInfo().noquote() << "ANSWER:\n" << answer;
        QCOMPARE(answer.count("m=audio"), 1);
        QVERIFY(answer.contains("a=mid:0"));
        QVERIFY(answer.contains("a=sendrecv"));
        QVERIFY(answer.contains("OPUS/48000", Qt::CaseInsensitive));
        b->close();
    }

    // наш offer → ответ как у libwebrtc (Android): должен примениться без ошибки и без зависания
    void acceptsLibwebrtcAnswer() {
        GstRtcEngine engine;
        RtcEvents ev;
        auto a = engine.createSession({}, ev);
        QString error, offer;
        bool done = false;
        auto make = [](RtcSession *a, QString *offer, QString *error, bool *done) -> Task<void> {
            try {
                co_await a->startAudio(true);
                *offer = co_await a->createOffer();
            } catch (const std::exception &e) {
                *error = QString::fromUtf8(e.what());
            }
            *done = true;
        };
        spawn(make(a.get(), &offer, &error, &done));
        QTRY_VERIFY_WITH_TIMEOUT(done, 10000);
        QVERIFY2(error.isEmpty(), qPrintable(error));
        qInfo().noquote() << "OUR OFFER:\n" << offer;
        QVERIFY2(offer.contains("OPUS/48000/2", Qt::CaseInsensitive), "libwebrtc принимает Opus только как opus/48000/2");
        const QString answer = QStringLiteral(
            "v=0\r\no=- 2853155839862349651 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\na=group:BUNDLE audio0\r\na=extmap-allow-mixed\r\n"
            "a=msid-semantic: WMS stream0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\nc=IN IP4 0.0.0.0\r\na=rtcp:9 IN IP4 0.0.0.0\r\n"
            "a=ice-ufrag:Wq3N\r\na=ice-pwd:6sJzJQK0rFq8Wf7cVYyWZRMa\r\na=ice-options:trickle renomination\r\n"
            "a=fingerprint:sha-256 12:34:56:78:9A:BC:DE:F0:12:34:56:78:9A:BC:DE:F0:12:34:56:78:9A:BC:DE:F0:12:34:56:78:9A:BC:DE:F0\r\n"
            "a=setup:active\r\na=mid:audio0\r\na=sendrecv\r\na=msid:stream0 audio0\r\na=rtcp-mux\r\n"
            "a=rtpmap:111 OPUS/48000/2\r\na=rtcp-fb:111 transport-cc\r\na=fmtp:111 minptime=10;useinbandfec=1\r\n"
            "a=ssrc:2002 cname:xyz\r\n");
        done = false;
        auto apply = [](RtcSession *a, QString answer, QString *error, bool *done) -> Task<void> {
            try {
                co_await a->setRemoteDescription("answer", answer);
            } catch (const std::exception &e) {
                *error = QString::fromUtf8(e.what());
            }
            *done = true;
        };
        spawn(apply(a.get(), answer, &error, &done));
        QTRY_VERIFY_WITH_TIMEOUT(done, 15000);
        QVERIFY2(error.isEmpty(), qPrintable(error));
        a->close();
    }

    // перезапрос как у Android при включении камеры: к звуку (mid audio0) добавляется видео mid "0"
    void answersLibwebrtcVideoRenegotiation() {
        GstRtcEngine engine;
        RtcEvents ev;
        auto b = engine.createSession({}, ev);
        const QString head = QStringLiteral(
            "v=0\r\no=- 4611731400430051336 %1 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\na=group:BUNDLE %2\r\na=extmap-allow-mixed\r\n"
            "a=msid-semantic: WMS stream0\r\n");
        const QString common = QStringLiteral(
            "c=IN IP4 0.0.0.0\r\na=rtcp:9 IN IP4 0.0.0.0\r\na=ice-ufrag:abcd\r\na=ice-pwd:abcdefghijklmnopqrstuvwx\r\n"
            "a=ice-options:trickle renomination\r\n"
            "a=fingerprint:sha-256 12:34:56:78:9A:BC:DE:F0:12:34:56:78:9A:BC:DE:F0:12:34:56:78:9A:BC:DE:F0:12:34:56:78:9A:BC:DE:F0\r\n");
        const QString audio = QStringLiteral("m=audio 9 UDP/TLS/RTP/SAVPF 111\r\n") + common +
            "a=setup:actpass\r\na=mid:audio0\r\na=sendrecv\r\na=msid:stream0 audio0\r\na=rtcp-mux\r\na=rtpmap:111 opus/48000/2\r\n"
            "a=fmtp:111 minptime=10;useinbandfec=1\r\na=ssrc:1001 cname:abc\r\n";
        const QString video = QStringLiteral("m=video 9 UDP/TLS/RTP/SAVPF 96 97\r\n") + common +
            "a=setup:actpass\r\na=mid:0\r\na=sendrecv\r\na=msid:stream0 video0\r\na=rtcp-mux\r\na=rtcp-rsize\r\n"
            "a=rtpmap:96 VP8/90000\r\na=rtcp-fb:96 goog-remb\r\na=rtcp-fb:96 transport-cc\r\na=rtcp-fb:96 ccm fir\r\n"
            "a=rtcp-fb:96 nack\r\na=rtcp-fb:96 nack pli\r\na=rtpmap:97 rtx/90000\r\na=fmtp:97 apt=96\r\n"
            "a=ssrc-group:FID 2001 2002\r\na=ssrc:2001 cname:abc\r\na=ssrc:2002 cname:abc\r\n";
        const QString offer1 = head.arg(2).arg("audio0") + audio;
        const QString offer2 = head.arg(3).arg("audio0 0") + audio + video;
        QString a1, a2, error;
        bool done = false;
        auto flow = [](RtcSession *b, QString o1, QString o2, QString *a1, QString *a2, QString *error, bool *done) -> Task<void> {
            try {
                co_await b->setRemoteDescription("offer", o1);
                co_await b->startAudio(true);
                *a1 = co_await b->createAnswer();
                co_await b->setRemoteDescription("offer", o2);
                *a2 = co_await b->createAnswer();
            } catch (const std::exception &e) {
                *error = QString::fromUtf8(e.what());
            }
            *done = true;
        };
        spawn(flow(b.get(), offer1, offer2, &a1, &a2, &error, &done));
        QTRY_VERIFY_WITH_TIMEOUT(done, 10000);
        QVERIFY2(error.isEmpty(), qPrintable(error));
        qInfo().noquote() << "ANSWER1:\n" << a1 << "ANSWER2:\n" << a2;
        // перезапрос не меняет ICE-учётку (иначе libwebrtc видит внезапный ICE restart)
        const QRegularExpression ufrag("a=ice-ufrag:(\\S+)");
        QCOMPARE(ufrag.match(a2).captured(1), ufrag.match(a1).captured(1));
        // роль DTLS в перезапросе — та же, что в начале звонка
        const QRegularExpression setup("a=setup:(\\w+)");
        QCOMPARE(setup.match(a2).captured(1), setup.match(a1).captured(1));
        QVERIFY2(a2.contains("a=group:BUNDLE audio0 0"), "видео должно быть в том же BUNDLE, иначе для него нет ни ICE, ни DTLS");
        QVERIFY(a2.contains("a=mid:0"));
        b->close();
    }

    // мы звонили (offer наш, ответ Android с setup:active → мы passive), потом Android включил камеру
    // и прислал перезапрос: наш ответ обязан остаться passive (иначе «Failed to set SSL role»)
    void keepsDtlsRoleWhenAnsweringRenegotiation() {
        GstRtcEngine engine;
        RtcEvents ev;
        auto a = engine.createSession({}, ev);
        const QString common = QStringLiteral(
            "c=IN IP4 0.0.0.0\r\na=ice-ufrag:Wq3N\r\na=ice-pwd:6sJzJQK0rFq8Wf7cVYyWZRMa\r\n"
            "a=fingerprint:sha-256 12:34:56:78:9A:BC:DE:F0:12:34:56:78:9A:BC:DE:F0:12:34:56:78:9A:BC:DE:F0:12:34:56:78:9A:BC:DE:F0\r\n");
        const QString audioAnswer = QStringLiteral("m=audio 9 UDP/TLS/RTP/SAVPF 111\r\n") + common +
            "a=setup:active\r\na=mid:audio0\r\na=sendrecv\r\na=rtcp-mux\r\na=rtpmap:111 opus/48000/2\r\na=ssrc:2002 cname:x\r\n";
        const QString answer = "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\na=group:BUNDLE audio0\r\n" + audioAnswer;
        const QString audioOffer = QStringLiteral("m=audio 9 UDP/TLS/RTP/SAVPF 111\r\n") + common +
            "a=setup:actpass\r\na=mid:audio0\r\na=sendrecv\r\na=rtcp-mux\r\na=rtpmap:111 opus/48000/2\r\na=ssrc:2002 cname:x\r\n";
        const QString videoOffer = QStringLiteral("m=video 9 UDP/TLS/RTP/SAVPF 96\r\n") + common +
            "a=setup:actpass\r\na=mid:0\r\na=sendrecv\r\na=rtcp-mux\r\na=rtpmap:96 VP8/90000\r\na=ssrc:3003 cname:x\r\n";
        const QString reoffer = "v=0\r\no=- 1 3 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\na=group:BUNDLE audio0 0\r\n" + audioOffer + videoOffer;
        QString reanswer, error;
        bool done = false;
        auto flow = [](RtcSession *a, QString answer, QString reoffer, QString *reanswer, QString *error, bool *done) -> Task<void> {
            try {
                co_await a->startAudio(true);
                co_await a->createOffer();
                co_await a->setRemoteDescription("answer", answer);
                co_await a->setRemoteDescription("offer", reoffer);
                *reanswer = co_await a->createAnswer();
            } catch (const std::exception &e) {
                *error = QString::fromUtf8(e.what());
            }
            *done = true;
        };
        spawn(flow(a.get(), answer, reoffer, &reanswer, &error, &done));
        QTRY_VERIFY_WITH_TIMEOUT(done, 10000);
        QVERIFY2(error.isEmpty(), qPrintable(error));
        QVERIFY2(reanswer.contains("a=setup:passive") && !reanswer.contains("a=setup:active"), qPrintable(reanswer));
        a->close();
    }

    // мы включили камеру первыми (наша строка video1, Android ответил recvonly), потом Android
    // включил свою и переиспользовал video1 (sendrecv). webrtcbin 1.20 не умеет менять направление
    // согласованной строки — ответ обязан пройти, не меняя его (а не уронить перезапрос)
    void answersRenegotiationReusingOurVideo() {
        qputenv("OSHINOBU_TEST_VIDEO", "1");
        GstRtcEngine engine;
        RtcEvents ev;
        auto a = engine.createSession({}, ev);
        QString offer, error, reanswer;
        bool done = false;
        auto first = [](RtcSession *a, QString *offer, QString *error, bool *done) -> Task<void> {
            try {
                co_await a->startAudio(true);
                co_await a->setVideoEnabled(true);
                *offer = co_await a->createOffer();
            } catch (const std::exception &e) {
                *error = QString::fromUtf8(e.what());
            }
            *done = true;
        };
        spawn(first(a.get(), &offer, &error, &done));
        QTRY_VERIFY_WITH_TIMEOUT(done, 10000);
        QVERIFY2(error.isEmpty(), qPrintable(error));
        const QString videoMid = QRegularExpression("m=video[^\\n]*\\n(?:[^m][^\\n]*\\n)*?a=mid:(\\S+)").match(offer).captured(1);
        QVERIFY2(!videoMid.isEmpty(), qPrintable(offer));
        const QString common = QStringLiteral(
            "c=IN IP4 0.0.0.0\r\na=ice-ufrag:Wq3N\r\na=ice-pwd:6sJzJQK0rFq8Wf7cVYyWZRMa\r\na=rtcp-mux\r\n"
            "a=fingerprint:sha-256 12:34:56:78:9A:BC:DE:F0:12:34:56:78:9A:BC:DE:F0:12:34:56:78:9A:BC:DE:F0:12:34:56:78:9A:BC:DE:F0\r\n");
        auto sdp = [&](int version, const QString &setup, const QString &videoDir) {
            return QStringLiteral("v=0\r\no=- 1 %1 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\na=group:BUNDLE audio0 %2\r\n").arg(version).arg(videoMid) +
                   "m=audio 9 UDP/TLS/RTP/SAVPF 111\r\n" + common + "a=setup:" + setup + "\r\na=mid:audio0\r\na=sendrecv\r\n"
                   "a=rtpmap:111 opus/48000/2\r\na=ssrc:2002 cname:x\r\n"
                   "m=video 9 UDP/TLS/RTP/SAVPF 96\r\n" + common + "a=setup:" + setup + "\r\na=mid:" + videoMid + "\r\na=" + videoDir + "\r\n"
                   "a=rtpmap:96 VP8/90000\r\n" + (videoDir == "sendrecv" ? QStringLiteral("a=ssrc:3003 cname:x\r\n") : QString());
        };
        done = false;
        auto second = [](RtcSession *a, QString answer, QString reoffer, QString *reanswer, QString *error, bool *done) -> Task<void> {
            try {
                co_await a->setRemoteDescription("answer", answer);
                co_await a->setRemoteDescription("offer", reoffer);
                *reanswer = co_await a->createAnswer();
            } catch (const std::exception &e) {
                *error = QString::fromUtf8(e.what());
            }
            *done = true;
        };
        spawn(second(a.get(), sdp(2, "active", "recvonly"), sdp(3, "actpass", "sendrecv"), &reanswer, &error, &done));
        QTRY_VERIFY_WITH_TIMEOUT(done, 10000);
        QVERIFY2(error.isEmpty(), qPrintable(error));
        QVERIFY2(reanswer.contains("a=sendonly"), qPrintable(reanswer));
        a->close();
    }
};

QTEST_GUILESS_MAIN(GstLoopbackTest)
#include "GstLoopbackTest.moc"

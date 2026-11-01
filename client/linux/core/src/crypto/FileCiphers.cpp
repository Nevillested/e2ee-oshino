#include "crypto/FileCiphers.h"

#include <QFile>
#include <QtEndian>

namespace osh {

namespace {

constexpr int TagBytes = AesGcm::TagBytes;
constexpr qint64 MaxBlock = 64LL * 1024 * 1024 + 1024;

QByteArray nonceFor(qint64 index) {
    QByteArray n(12, '\0');
    qToBigEndian<quint64>(quint64(index), n.data() + 4);
    return n;
}

QByteArray aadFor(qint64 index, bool isLast) { return (QString::number(index) + u':' + (isLast ? u'1' : u'0')).toUtf8(); }

/// Блок: шифротекст+тег одним куском (как AES/GCM в javax).
QByteArray sealBlock(const QByteArray &key, qint64 index, bool isLast, const QByteArray &plain) {
    const SealedBox box = AesGcm::encrypt(key, plain, aadFor(index, isLast), nonceFor(index));
    return box.ciphertext + box.mac;
}

/// Последний ли блок — неизвестно заранее: пробуем оба AAD.
std::pair<QByteArray, bool> openBlock(const QByteArray &key, qint64 index, const QByteArray &payload) {
    const SealedBox box{nonceFor(index), payload.left(payload.size() - TagBytes), payload.right(TagBytes)};
    for (bool isLast : {false, true}) {
        try {
            return {AesGcm::decrypt(key, box, aadFor(index, isLast)), isLast};
        } catch (const AuthFailedError &) {
        }
    }
    throw FileCipherError("блок " + std::to_string(index) + " не расшифровывается (обрыв, подмена или неверный ключ)");
}

void open(QFile &f, QIODevice::OpenMode mode) {
    if (!f.open(mode)) throw FileCipherError("не открыть файл " + f.fileName().toStdString() + ": " + f.errorString().toStdString());
}

void writeAll(QFile &f, const QByteArray &data) {
    if (f.write(data) != data.size()) throw FileCipherError("не записать файл: " + f.errorString().toStdString());
}

} // namespace

namespace MediaCipher {

EncryptedFile encrypt(const QByteArray &plain) {
    const QByteArray key = randomBytes(32);
    const SealedBox box = AesGcm::encrypt(key, plain);
    return {key, box.nonce, box.mac, box.ciphertext};
}

QByteArray decrypt(const QByteArray &key, const QByteArray &nonce, const QByteArray &mac, const QByteArray &ciphertext) {
    return AesGcm::decrypt(key, SealedBox{nonce, ciphertext, mac});
}

} // namespace MediaCipher

namespace StreamingFileCipher {

QByteArray encryptFile(const QString &input, const QString &output, const Progress &onProgress) {
    const QByteArray key = randomBytes(32);
    QFile in(input), out(output);
    try {
        open(in, QIODevice::ReadOnly);
        open(out, QIODevice::WriteOnly | QIODevice::Truncate);
        const qint64 total = in.size();
        qint64 processed = 0;
        for (qint64 index = 0;; ++index) {
            const QByteArray plain = in.read(ChunkSize);
            if (in.error() != QFileDevice::NoError) throw FileCipherError("не прочитать файл: " + in.errorString().toStdString());
            const bool isLast = plain.size() < ChunkSize;
            const QByteArray sealed = sealBlock(key, index, isLast, plain);
            QByteArray len(4, '\0');
            qToBigEndian<quint32>(quint32(sealed.size()), len.data());
            writeAll(out, len);
            writeAll(out, sealed);
            processed += plain.size();
            if (onProgress) onProgress(total == 0 ? 100.0 : processed * 100.0 / total);
            if (isLast) break;
        }
    } catch (...) {
        out.close();
        QFile::remove(output);
        throw;
    }
    return key;
}

void decryptFile(const QString &input, const QString &output, const QByteArray &key, const Progress &onProgress) {
    QFile in(input), out(output);
    try {
        open(in, QIODevice::ReadOnly);
        open(out, QIODevice::WriteOnly | QIODevice::Truncate);
        const qint64 total = in.size();
        qint64 offset = 0;
        bool sawLast = false;
        for (qint64 index = 0; offset < total; ++index) {
            const QByteArray header = in.read(4);
            if (header.size() != 4) throw FileCipherError("повреждённый файл: неполный заголовок блока");
            offset += 4;
            const qint64 len = qFromBigEndian<quint32>(header.constData());
            if (len < TagBytes || len > MaxBlock) throw FileCipherError("повреждённый файл: недопустимая длина блока " + std::to_string(len));
            const QByteArray payload = in.read(len);
            if (payload.size() != len) throw FileCipherError("повреждённый файл: блок обрезан");
            offset += len;
            const auto [plain, isLast] = openBlock(key, index, payload);
            writeAll(out, plain);
            sawLast = isLast;
            if (onProgress) onProgress(total == 0 ? 100.0 : offset * 100.0 / total);
        }
        if (!sawLast) throw FileCipherError("файл повреждён или обрезан — нет завершающего блока");
    } catch (...) {
        out.close();
        QFile::remove(output);
        throw;
    }
}

} // namespace StreamingFileCipher

} // namespace osh

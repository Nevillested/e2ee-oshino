#include "support/Zip.h"

#include <QFile>
#include <QtEndian>
#include <zlib.h>

namespace osh {

namespace {

quint16 u16(const QByteArray &b, qint64 at) { return qFromLittleEndian<quint16>(b.constData() + at); }
quint32 u32(const QByteArray &b, qint64 at) { return qFromLittleEndian<quint32>(b.constData() + at); }

bool inflateRaw(const QByteArray &in, qint64 expected, QByteArray &out) {
    out.resize(expected);
    z_stream zs{};
    if (inflateInit2(&zs, -MAX_WBITS) != Z_OK) return false;
    zs.next_in = reinterpret_cast<Bytef *>(const_cast<char *>(in.constData()));
    zs.avail_in = uInt(in.size());
    zs.next_out = reinterpret_cast<Bytef *>(out.data());
    zs.avail_out = uInt(out.size());
    const int rc = inflate(&zs, Z_FINISH);
    inflateEnd(&zs);
    return rc == Z_STREAM_END && zs.total_out == uLong(expected);
}

} // namespace

bool forEachZipEntry(const QString &path, qint64 maxEntryBytes, const std::function<void(const QString &, const QByteArray &)> &onEntry) {
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return false;
    const QByteArray zip = f.readAll();
    // конец центрального каталога — последние 22 байта + комментарий до 64 КБ
    qint64 eocd = -1;
    for (qint64 i = zip.size() - 22; i >= 0 && i >= zip.size() - 22 - 65535; --i) {
        if (u32(zip, i) == 0x06054b50) {
            eocd = i;
            break;
        }
    }
    if (eocd < 0) return false;
    const int count = u16(zip, eocd + 10);
    qint64 p = u32(zip, eocd + 16);
    for (int n = 0; n < count; ++n) {
        if (p + 46 > zip.size() || u32(zip, p) != 0x02014b50) return false;
        const int method = u16(zip, p + 10);
        const qint64 compSize = u32(zip, p + 20), size = u32(zip, p + 24);
        const int nameLen = u16(zip, p + 28), extraLen = u16(zip, p + 30), commentLen = u16(zip, p + 32);
        const qint64 local = u32(zip, p + 42);
        const QString name = QString::fromUtf8(zip.mid(p + 46, nameLen));
        p += 46 + nameLen + extraLen + commentLen;
        if (name.endsWith(u'/') || size > maxEntryBytes || local + 30 > zip.size() || u32(zip, local) != 0x04034b50) continue;
        const qint64 dataAt = local + 30 + u16(zip, local + 26) + u16(zip, local + 28);
        if (dataAt + compSize > zip.size()) continue;
        const QByteArray comp = zip.mid(dataAt, compSize);
        QByteArray data;
        if (method == 0) {
            data = comp;
        } else if (method != 8 || !inflateRaw(comp, size, data)) {
            continue;
        }
        onEntry(name, data);
    }
    return true;
}

} // namespace osh

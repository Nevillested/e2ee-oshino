#include "crypto/MessageCipher.h"

#include "crypto/Primitives.h"
#include "support/Json.h"

#include <QStringList>

namespace osh {

namespace {

const char *const aadFieldNames[] = {
    "sender_device_id",
    "ratchet_pubkey",
    "message_number",
    "ephemeral_pubkey",
    "sender_identity_dh_pubkey",
    "used_one_time_prekey",
};

QString aadValue(const QJsonValue &v) {
    switch (v.type()) {
    case QJsonValue::Null:
    case QJsonValue::Undefined: return QStringLiteral("null");
    case QJsonValue::String: return v.toString();
    case QJsonValue::Bool: return v.toBool() ? QStringLiteral("true") : QStringLiteral("false");
    case QJsonValue::Double: return json::numberText(v);
    default: return json::compact(v);
    }
}

} // namespace

QByteArray buildAad(const QJsonObject &fields) {
    QStringList parts;
    for (const char *name : aadFieldNames) parts << QString::fromLatin1(name) + u'=' + aadValue(fields.value(QLatin1String(name)));
    return parts.join(u'|').toUtf8();
}

QJsonObject encryptMessage(const QByteArray &messageKey, const QString &plaintext, const QJsonObject &aad) {
    const SealedBox box = AesGcm::encrypt(messageKey, plaintext.toUtf8(), buildAad(aad));
    return {{"nonce", b64(box.nonce)}, {"ciphertext", b64(box.ciphertext)}, {"mac", b64(box.mac)}};
}

QString decryptMessage(const QByteArray &messageKey, const QJsonObject &envelope) {
    auto field = [&](const char *name) {
        const QJsonValue v = envelope.value(QLatin1String(name));
        if (!v.isString()) throw CryptoError(std::string("в конверте нет поля ") + name);
        return unb64(v.toString());
    };
    const SealedBox box{field("nonce"), field("ciphertext"), field("mac")};
    return QString::fromUtf8(AesGcm::decrypt(messageKey, box, buildAad(envelope)));
}

} // namespace osh

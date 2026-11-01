#pragma once

// Шифрование тела конверта (как MessageCipher.kt на Android).
//
// Заголовочные поля конверта (какой ключ ratchet, номер сообщения, чей это
// X3DH) лежат рядом с шифротекстом открыто, но связаны с ним через AAD
// AES-GCM: подмена любого из них ломает MAC. Строка AAD — зафиксированный
// формат, посимвольно: "name=value" через "|", в фиксированном порядке;
// отсутствующее поле и null дают одинаковое "null", число — без кавычек и
// дробной части.

#include <QByteArray>
#include <QJsonObject>
#include <QString>

namespace osh {

QByteArray buildAad(const QJsonObject &fields);

/// Поля nonce/ciphertext/mac (base64) — их кладут в конверт рядом с полями [aad].
QJsonObject encryptMessage(const QByteArray &messageKey, const QString &plaintext, const QJsonObject &aad);

/// AAD собирается из того же [envelope] — лишние поля игнорируются.
QString decryptMessage(const QByteArray &messageKey, const QJsonObject &envelope);

} // namespace osh

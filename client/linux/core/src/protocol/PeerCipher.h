#pragma once

// Сборка и вскрытие конверта — чистая криптографическая часть отправки и
// приёма (как PeerCipher.kt). Хранилище, сеть, повторы и самолечение сессии
// сюда НЕ входят — это уровень сервисов.
//
// Конверт на проводе: { nonce, ciphertext, mac, ratchet_pubkey,
// message_number, sender_device_id [, sender_identity_dh_pubkey,
// ephemeral_pubkey, used_one_time_prekey] } — все заголовочные поля входят
// в AAD (см. MessageCipher.h).

#include "crypto/RatchetState.h"
#include "crypto/X3dh.h"
#include "protocol/InnerMessage.h"

#include <QJsonObject>
#include <optional>
#include <utility>

namespace osh::PeerCipher {

/// Новая исходящая сессия по prekey-бандлу; initHeader передать в seal для ПЕРВОГО сообщения сессии.
std::pair<RatchetState, QJsonObject> startOutgoingSession(const QJsonObject &bundle, const QString &myDeviceId,
                                                          const X25519KeyPair &myIdentityDh);

/// Шифрует [inner] следующим ключом [state] (state продвигается — сохранить его до отправки).
QJsonObject seal(RatchetState &state, const InnerMessage &inner, const QString &myDeviceId, const QJsonObject &initHeader = {});

/// То же для произвольного текста — сигналы звонка шифруются тем же ratchet, внутри просто JSON `{type, ...}`.
QJsonObject sealText(RatchetState &state, const QString &plaintext, const QString &myDeviceId, const QJsonObject &initHeader = {});

/// Расшифровка входящего конверта текущим состоянием. Состояние продвигается.
InnerMessage open(RatchetState &state, const QJsonObject &envelope);

/// Свежая входящая сессия из X3DH-полей конверта; nullopt — их там нет.
std::optional<std::pair<RatchetState, X3dhIncoming>> startIncomingSession(const QJsonObject &envelope, const LocalIdentity &me);

} // namespace osh::PeerCipher

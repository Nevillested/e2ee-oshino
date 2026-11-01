#pragma once

// Шифрование вложений (как FileCiphers.kt).
//
// Мелкие файлы (≤ 20 МБ) — целиком одним AES-256-GCM: ключ/nonce/mac едут
// в конверте.
//
// Большие — потоково блоками по 4 МБ (формат зафиксирован — файлы на
// сервере и у собеседников других версий):
//   блок:  [4 байта BE = len(ciphertext+tag)] [ciphertext] [tag(16)]
//   nonce  = 0x00000000 || uint64_be(index)
//   AAD    = UTF-8("<index>:<0|1>"), 1 = последний блок; файл, кратный
//            4 МБ, завершается ПУСТЫМ последним блоком.

#include "crypto/Primitives.h"

#include <QString>
#include <functional>

namespace osh {

/// Файл повреждён, обрезан, подменён или ключ неверный.
struct FileCipherError : CryptoError {
    using CryptoError::CryptoError;
};

struct EncryptedFile {
    QByteArray key;
    QByteArray nonce;
    QByteArray mac;
    QByteArray ciphertext;
};

namespace MediaCipher {
EncryptedFile encrypt(const QByteArray &plain);
QByteArray decrypt(const QByteArray &key, const QByteArray &nonce, const QByteArray &mac, const QByteArray &ciphertext);
} // namespace MediaCipher

namespace StreamingFileCipher {
constexpr qint64 ChunkSize = 4 * 1024 * 1024;
/// Порог, с которого файл шифруется потоково и грузится частями.
constexpr qint64 StreamingThresholdBytes = 20LL * 1024 * 1024;

using Progress = std::function<void(double percent)>;

/// Шифрует [input] в [output], возвращает случайный 32-байтный ключ файла.
QByteArray encryptFile(const QString &input, const QString &output, const Progress &onProgress = {});
/// FileCipherError на обрыв, подмену или неверный ключ (недописанный [output] удаляется).
void decryptFile(const QString &input, const QString &output, const QByteArray &key, const Progress &onProgress = {});
} // namespace StreamingFileCipher

} // namespace osh

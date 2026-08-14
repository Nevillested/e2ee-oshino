package auth

import (
	"crypto/rand"
	"encoding/base64"

	"golang.org/x/crypto/argon2"
)

// Параметры хеширования и формат хранения ("hash$salt", обе части в
// base64) взяты 1-в-1 из исходной реализации в register.go — это
// единственное место, где они теперь заданы, чтобы регистрация
// (register.go) и ручной сброс пароля из cmd/admin никогда не могли
// разойтись по параметрам и не сломать проверку в login.go.
const (
	argonTime    = 1
	argonMemory  = 64 * 1024
	argonThreads = 4
	argonKeyLen  = 32
	saltLen      = 16
)

// HashPassword — argon2id с новой случайной солью на каждый вызов.
func HashPassword(password string) (string, error) {
	salt := make([]byte, saltLen)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	hash := argon2.IDKey([]byte(password), salt, argonTime, argonMemory, argonThreads, argonKeyLen)
	hashS := base64.StdEncoding.EncodeToString(hash)
	saltS := base64.StdEncoding.EncodeToString(salt)
	return hashS + "$" + saltS, nil
}

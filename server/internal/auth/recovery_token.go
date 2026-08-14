package auth

import (
	"crypto/rand"
	"math/big"
)

// Алфавит без визуально похожих символов (нет 0/O, 1/I/L) — код читают
// глазами из письма и вводят руками на телефоне, ошибиться легко.
const recoveryTokenAlphabet = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"

// GenerateRecoveryToken — буквенно-цифровой код восстановления пароля,
// 12 символов из recoveryTokenAlphabet (31 символ в алфавите, log2(31)≈4.95
// бит/символ — суммарно ~59 бит энтропии, с огромным запасом даже без
// ограничения попыток, а оно есть отдельно, см. password_reset_tokens и
// checkRecoveryToken в password_recovery.go).
//
// crypto/rand.Int, а не rand.Read+modulo — так выбор каждого символа
// равномерный без bias по модулю (31 не делит 256 нацело).
func GenerateRecoveryToken() (string, error) {
	const length = 12
	alphabetLen := big.NewInt(int64(len(recoveryTokenAlphabet)))
	out := make([]byte, length)
	for i := range out {
		n, err := rand.Int(rand.Reader, alphabetLen)
		if err != nil {
			return "", err
		}
		out[i] = recoveryTokenAlphabet[n.Int64()]
	}
	return string(out), nil
}

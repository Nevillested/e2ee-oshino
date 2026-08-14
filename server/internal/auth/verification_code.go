package auth

import (
	"crypto/rand"
	"math/big"
)

// Алфавит без визуально похожих символов (нет 0/O, 1/I/L) — код читают
// глазами из письма и вводят руками на телефоне, ошибиться легко.
const verificationCodeAlphabet = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"

// GenerateVerificationCode — буквенно-цифровой одноразовый код, 12 символов
// из verificationCodeAlphabet (31 символ в алфавите, log2(31)≈4.95
// бит/символ — суммарно ~59 бит энтропии, с огромным запасом даже без
// ограничения попыток, а оно есть отдельно на стороне вызывающего кода).
// Общая функция для восстановления пароля (password_recovery.go) и
// подтверждения новой почты (account_email_verification.go) — оба случая
// это один и тот же паттерн "код на почту, проверить, потратить один раз".
//
// crypto/rand.Int, а не rand.Read+modulo — так выбор каждого символа
// равномерный без bias по модулю (31 не делит 256 нацело).
func GenerateVerificationCode() (string, error) {
	const length = 12
	alphabetLen := big.NewInt(int64(len(verificationCodeAlphabet)))
	out := make([]byte, length)
	for i := range out {
		n, err := rand.Int(rand.Reader, alphabetLen)
		if err != nil {
			return "", err
		}
		out[i] = verificationCodeAlphabet[n.Int64()]
	}
	return string(out), nil
}

package auth

import (
	"errors"
	"unicode"
)

// ValidatePassword — единые требования к паролю, одинаковые во всех трёх
// местах, где пользователь его задаёт (регистрация, восстановление по
// коду, смена пароля в настройках): минимум 6 символов, хотя бы одна
// заглавная буква, одна строчная, одна цифра и один спецсимвол.
func ValidatePassword(password string) error {
	if len(password) < 6 {
		return errors.New("пароль должен быть не короче 6 символов")
	}

	var hasUpper, hasLower, hasDigit, hasSpecial bool
	for _, r := range password {
		switch {
		case unicode.IsUpper(r):
			hasUpper = true
		case unicode.IsLower(r):
			hasLower = true
		case unicode.IsDigit(r):
			hasDigit = true
		case unicode.IsPunct(r) || unicode.IsSymbol(r):
			hasSpecial = true
		}
	}

	if !hasUpper {
		return errors.New("пароль должен содержать хотя бы одну заглавную букву")
	}
	if !hasLower {
		return errors.New("пароль должен содержать хотя бы одну строчную букву")
	}
	if !hasDigit {
		return errors.New("пароль должен содержать хотя бы одну цифру")
	}
	if !hasSpecial {
		return errors.New("пароль должен содержать хотя бы один специальный символ")
	}

	return nil
}

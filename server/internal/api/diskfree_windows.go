//go:build windows

package api

import "errors"

// Сервер работает только на Linux; на Windows (локальная сборка) буфер
// считается переполненным — файлы идут сразу в MinIO.
func diskFreeBytes(path string) (int64, error) {
	return 0, errors.New("diskFreeBytes не поддерживается на Windows")
}

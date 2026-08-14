// Package mail — отправка писем через SMTP собственного почтового сервера
// (Mailcow на oshino.space, см. обсуждение с пользователем) от имени
// noreply@oshino.space. Только отправка — приём и человеческая переписка
// (support@oshino.space) идут отдельно, читаются напрямую в почтовом
// приложении на телефоне, сервера это не касается вообще.
package mail

import (
	"fmt"
	"mime"
	"net/smtp"
	"os"
)

// Настройки — из .env, тем же способом, что и DATABASE_URL/MINIO_* в
// main.go: SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASSWORD, SMTP_FROM.
func smtpConfig() (host, port, user, password, from string) {
	return os.Getenv("SMTP_HOST"),
		os.Getenv("SMTP_PORT"),
		os.Getenv("SMTP_USER"),
		os.Getenv("SMTP_PASSWORD"),
		os.Getenv("SMTP_FROM")
}

// SendPasswordResetCode — письмо с одноразовым кодом восстановления
// пароля. net/smtp.SendMail сам делает STARTTLS, если сервер его
// поддерживает (Mailcow на 587-м порту — поддерживает), отдельно
// настраивать TLS не нужно.
func SendPasswordResetCode(toEmail, code string) error {
	host, port, user, password, from := smtpConfig()

	// Заголовки письма формально должны быть 7-битным ASCII (RFC 5322) —
	// кириллицу в Subject кодируем по RFC 2047 (=?UTF-8?...?=), иначе часть
	// почтовых клиентов и спам-фильтров могут отобразить его криво или
	// заподозрить неладное. Тело письма — обычный UTF-8, там это разрешено
	// явным Content-Type.
	subject := mime.QEncoding.Encode("UTF-8", "Восстановление пароля Oshinobu")
	body := fmt.Sprintf(
		"Код для восстановления пароля: %s\r\n\r\n"+
			"Код действителен 30 минут. Если вы не запрашивали восстановление — просто проигнорируйте это письмо.",
		code,
	)

	msg := []byte(
		"From: " + from + "\r\n" +
			"To: " + toEmail + "\r\n" +
			"Subject: " + subject + "\r\n" +
			"MIME-Version: 1.0\r\n" +
			"Content-Type: text/plain; charset=UTF-8\r\n" +
			"\r\n" + body + "\r\n",
	)

	auth := smtp.PlainAuth("", user, password, host)
	addr := host + ":" + port
	return smtp.SendMail(addr, auth, from, []string{toEmail}, msg)
}

package api

import (
	"net"
	"net/http"
	"sync"
	"time"
)

// LoginRateLimiter — простой rate-limiter по IP для /login: слишком много
// неудачных попыток подряд с одного адреса — временная блокировка. В
// памяти процесса (тот же стиль, что и ConnectionRegistry/AckRegistry в
// этом проекте), без внешних зависимостей: сервер — один процесс на одной
// VPS, распределённый rate-limit тут ни к чему. Раньше от перебора паролей
// были защищены только коды восстановления (см. password_recovery.go), а
// сам /login — нет.
type LoginRateLimiter struct {
	mu       sync.Mutex
	attempts map[string][]time.Time // ip -> моменты неудачных попыток за окно
}

const (
	loginRateLimitWindow   = 15 * time.Minute
	loginRateLimitMaxTries = 5
)

func NewLoginRateLimiter() *LoginRateLimiter {
	return &LoginRateLimiter{attempts: make(map[string][]time.Time)}
}

// Allowed — можно ли сейчас пробовать логиниться с этого IP. Заодно
// вычищает устаревшие (за пределами окна) попытки — так карта не растёт
// вечно для IP, переставших ломиться.
func (l *LoginRateLimiter) Allowed(ip string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()

	cutoff := time.Now().Add(-loginRateLimitWindow)
	fresh := l.attempts[ip][:0]
	for _, t := range l.attempts[ip] {
		if t.After(cutoff) {
			fresh = append(fresh, t)
		}
	}
	if len(fresh) == 0 {
		delete(l.attempts, ip)
	} else {
		l.attempts[ip] = fresh
	}

	return len(fresh) < loginRateLimitMaxTries
}

// RecordFailure — зафиксировать неудачную попытку входа с этого IP.
func (l *LoginRateLimiter) RecordFailure(ip string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.attempts[ip] = append(l.attempts[ip], time.Now())
}

// RecordSuccess — успешный вход сбрасывает счётчик для этого IP: не
// наказываем легитимного пользователя, пару раз опечатавшегося перед
// правильным паролем.
func (l *LoginRateLimiter) RecordSuccess(ip string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.attempts, ip)
}

// clientIP — реальный IP клиента, а не адрес nginx. Сервер стоит за
// реверс-прокси (см. /etc/nginx/sites-available/e2ee.conf), который
// прокидывает X-Real-IP; без этого r.RemoteAddr был бы всегда 127.0.0.1
// (адрес самого nginx) — тогда лимитер видел бы ВСЕХ пользователей как
// один IP, и пять неудачных попыток КОГО УГОДНО блокировали бы вход всем
// сразу. RemoteAddr — только как запасной вариант, если приложение
// вдруг дёрнут напрямую, в обход nginx.
func clientIP(r *http.Request) string {
	if realIP := r.Header.Get("X-Real-IP"); realIP != "" {
		return realIP
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

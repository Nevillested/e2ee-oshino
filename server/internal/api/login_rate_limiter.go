package api

import (
	"net"
	"net/http"
	"sync"
	"time"
)

// RateLimiter — простой rate-limiter по произвольному строковому ключу:
// слишком много неудачных попыток подряд для одного ключа — временная
// блокировка. В памяти процесса (тот же стиль, что и
// ConnectionRegistry/AckRegistry в этом проекте), без внешних зависимостей:
// сервер — один процесс на одной VPS, распределённый rate-limit тут ни к
// чему.
//
// Ключ — не обязательно IP: для /login используется связка "ip|login"
// (см. login.go) плюс отдельный лимитер по одному только login — так один
// человек, ломящийся в конкретный чужой аккаунт с разных IP, всё равно
// упирается в лимит по логину, а не просто перебирает IP-адреса, но при
// этом NAT/офис/VPN с одним внешним IP не блокирует ВСЕХ, кто за ним сидит,
// из-за чужих неудачных попыток — только тех, кто ломится в тот же логин.
type RateLimiter struct {
	mu       sync.Mutex
	window   time.Duration
	maxTries int
	attempts map[string][]time.Time // key -> моменты неудачных попыток за окно
}

func NewRateLimiter(window time.Duration, maxTries int) *RateLimiter {
	return &RateLimiter{
		window:   window,
		maxTries: maxTries,
		attempts: make(map[string][]time.Time),
	}
}

// Совместимость со старым именем конструктора — /login исторически заведён
// через NewLoginRateLimiter(), поведение (15 минут / 5 попыток) сохранено.
func NewLoginRateLimiter() *RateLimiter {
	return NewRateLimiter(loginRateLimitWindow, loginRateLimitMaxTries)
}

const (
	loginRateLimitWindow   = 15 * time.Minute
	loginRateLimitMaxTries = 5
)

// Allowed — можно ли сейчас пробовать снова с этим ключом. Заодно вычищает
// устаревшие (за пределами окна) попытки — так карта не растёт вечно для
// ключей, переставших ломиться.
func (l *RateLimiter) Allowed(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()

	cutoff := time.Now().Add(-l.window)
	fresh := l.attempts[key][:0]
	for _, t := range l.attempts[key] {
		if t.After(cutoff) {
			fresh = append(fresh, t)
		}
	}
	if len(fresh) == 0 {
		delete(l.attempts, key)
	} else {
		l.attempts[key] = fresh
	}

	return len(fresh) < l.maxTries
}

// RecordFailure — зафиксировать неудачную попытку для этого ключа.
func (l *RateLimiter) RecordFailure(key string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.attempts[key] = append(l.attempts[key], time.Now())
}

// RecordSuccess — успех сбрасывает счётчик для этого ключа: не наказываем
// легитимного пользователя, пару раз опечатавшегося перед правильным вводом.
func (l *RateLimiter) RecordSuccess(key string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.attempts, key)
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

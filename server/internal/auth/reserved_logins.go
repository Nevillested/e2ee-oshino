package auth

import "strings"

// reservedLogins — логины, которые нельзя занять при регистрации: имена,
// которыми легко представиться администрацией/поддержкой (в переписке 1-в-1
// собеседник видит только логин, никакой "галочки верификации" у нас нет —
// это единственная защита от буквального "Здравствуйте, я admin, назовите
// код от аккаунта").
var reservedLogins = map[string]struct{}{
	"admin":         {},
	"administrator": {},
	"root":          {},
	"superuser":     {},
	"moderator":     {},
	"mod":           {},
	"support":       {},
	"helpdesk":      {},
	"help":          {},
	"service":       {},
	"contact":       {},
	"official":      {},
	"system":        {},
	"staff":         {},
	"team":          {},
	"security":      {},
	"abuse":         {},
	"noreply":       {},
	"no-reply":      {},
	"postmaster":    {},
	"webmaster":     {},
	"oshino":        {},
	"oshinobu":      {},
	"shinobu":       {},
	"oshinospace":   {},
}

// IsReservedLogin — сравнение без учёта регистра: "Admin"/"ADMIN"/"admin"
// одинаково зарезервированы, раз собеседник в чате видит логин как есть, а
// не в каком-то одном фиксированном регистре.
func IsReservedLogin(login string) bool {
	_, reserved := reservedLogins[strings.ToLower(login)]
	return reserved
}

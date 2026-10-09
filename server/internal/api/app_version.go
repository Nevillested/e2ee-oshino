package api

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"strconv"
)

// AppVersion — единственная допустимая версия клиента. Приложение с любой
// другой версией (старше или новее) сервер не обслуживает: ответ 426 с этой
// же информацией, клиент показывает экран "обновите приложение".
//
// Задаётся переменными окружения:
//
//	APP_VERSION_CODE — номер сборки (versionCode); не задан или 0 — проверка выключена;
//	APP_APK_URL      — откуда скачать APK тем, кто ставил не из Google Play.
type AppVersion struct {
	VersionCode int    `json:"version_code"`
	ApkURL      string `json:"apk_url"`
}

// AppVersionHeader — заголовок, в котором клиент сообщает свой versionCode.
const AppVersionHeader = "X-App-Version"

func LoadAppVersion() AppVersion {
	code, _ := strconv.Atoi(os.Getenv("APP_VERSION_CODE"))
	return AppVersion{VersionCode: code, ApkURL: os.Getenv("APP_APK_URL")}
}

func (v AppVersion) writeJSON(w http.ResponseWriter, status int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// NewAppVersionHandler — GET /app/version: какая версия сейчас обязательна.
func NewAppVersionHandler(v AppVersion) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		v.writeJSON(w, http.StatusOK)
	}
}

// RequireAppVersion пропускает к остальным маршрутам только клиентов с
// обязательной версией. /app/version и /health доступны всем.
func RequireAppVersion(v AppVersion, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if v.VersionCode == 0 || r.URL.Path == "/app/version" || r.URL.Path == "/health" {
			next.ServeHTTP(w, r)
			return
		}
		client, err := strconv.Atoi(r.Header.Get(AppVersionHeader))
		if err != nil || client != v.VersionCode {
			log.Printf("app version: отказ %s %s — версия клиента %q, нужна %d", r.Method, r.URL.Path, r.Header.Get(AppVersionHeader), v.VersionCode)
			v.writeJSON(w, http.StatusUpgradeRequired)
			return
		}
		next.ServeHTTP(w, r)
	})
}

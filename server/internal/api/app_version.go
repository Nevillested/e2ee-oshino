package api

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
)

// AppVersion — единственная допустимая версия клиента. Приложение с любой
// другой версией (старше или новее) сервер не обслуживает: ответ 426 с этой
// же информацией, клиент показывает экран "обновите приложение".
//
// Задаётся переменными окружения:
//
//	APP_VERSION_CODE — номер сборки (versionCode); не задан или 0 — проверка выключена;
//	APP_APK_DIR      — папка, где лежит oshinobu.apk той же версии: сервер сам
//	                   раздаёт его по GET /app/apk тем, кто ставил не из Google Play;
//	APP_APK_URL      — APK лежит где-то ещё: полный адрес вместо /app/apk.
//
// Установленные из Play обновляются через Play — им apk_url не нужен.
type AppVersion struct {
	VersionCode int    `json:"version_code"`
	ApkURL      string `json:"apk_url"`
	ApkDir      string `json:"-"`
}

// ApkFileName — имя APK в APP_APK_DIR.
const ApkFileName = "oshinobu.apk"

// ApkPath — маршрут, по которому сервер раздаёт APK из APP_APK_DIR.
const ApkPath = "/app/apk"

// AppVersionHeader — заголовок, в котором клиент сообщает свой versionCode.
const AppVersionHeader = "X-App-Version"

func LoadAppVersion() AppVersion {
	code, _ := strconv.Atoi(os.Getenv("APP_VERSION_CODE"))
	return AppVersion{VersionCode: code, ApkURL: os.Getenv("APP_APK_URL"), ApkDir: os.Getenv("APP_APK_DIR")}
}

// apkFile — путь к APK в APP_APK_DIR, если он там лежит.
func (v AppVersion) apkFile() (string, bool) {
	if v.ApkDir == "" {
		return "", false
	}
	path := filepath.Join(v.ApkDir, ApkFileName)
	info, err := os.Stat(path)
	return path, err == nil && info.Mode().IsRegular()
}

// withApkURL — откуда клиенту качать APK: явный APP_APK_URL, иначе свой
// /app/apk (относительный — клиент дополнит адресом сервера), но только
// если файл на месте; проверяется на каждый запрос — APK можно выложить
// без перезапуска сервера.
func (v AppVersion) withApkURL() AppVersion {
	if v.ApkURL == "" {
		if _, ok := v.apkFile(); ok {
			v.ApkURL = ApkPath
		}
	}
	return v
}

func (v AppVersion) writeJSON(w http.ResponseWriter, status int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v.withApkURL())
}

// NewAppVersionHandler — GET /app/version: какая версия сейчас обязательна.
func NewAppVersionHandler(v AppVersion) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		v.writeJSON(w, http.StatusOK)
	}
}

// NewAppApkHandler — GET /app/apk: сам APK из APP_APK_DIR (с поддержкой
// докачки через Range); нет файла — 404.
func NewAppApkHandler(v AppVersion) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		path, ok := v.apkFile()
		if !ok {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/vnd.android.package-archive")
		w.Header().Set("Content-Disposition", `attachment; filename="`+ApkFileName+`"`)
		http.ServeFile(w, r, path)
	}
}

// RequireAppVersion пропускает к остальным маршрутам только клиентов с
// обязательной версией. /app/version, /app/apk (устаревшему клиенту надо
// откуда-то скачать новую версию) и /health доступны всем.
func RequireAppVersion(v AppVersion, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if v.VersionCode == 0 || r.URL.Path == "/app/version" || r.URL.Path == ApkPath || r.URL.Path == "/health" {
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

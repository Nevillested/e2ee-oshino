package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func versionJSON(t *testing.T, v AppVersion) AppVersion {
	t.Helper()
	rec := httptest.NewRecorder()
	NewAppVersionHandler(v)(rec, httptest.NewRequest(http.MethodGet, "/app/version", nil))
	var got AppVersion
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	return got
}

func TestAppApk(t *testing.T) {
	dir := t.TempDir()
	v := AppVersion{VersionCode: 45, ApkDir: dir}

	// APK ещё не выложен: ссылки нет, раздавать нечего
	if got := versionJSON(t, v); got.ApkURL != "" {
		t.Errorf("APK нет, а apk_url = %q", got.ApkURL)
	}
	rec := httptest.NewRecorder()
	NewAppApkHandler(v)(rec, httptest.NewRequest(http.MethodGet, ApkPath, nil))
	if rec.Code != http.StatusNotFound {
		t.Errorf("APK нет, а ответ %d", rec.Code)
	}

	// выложили — без перезапуска появилась ссылка, файл отдаётся как есть
	if err := os.WriteFile(filepath.Join(dir, ApkFileName), []byte("apk-bytes"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := versionJSON(t, v); got.ApkURL != ApkPath {
		t.Errorf("APK выложен, а apk_url = %q", got.ApkURL)
	}
	rec = httptest.NewRecorder()
	NewAppApkHandler(v)(rec, httptest.NewRequest(http.MethodGet, ApkPath, nil))
	if rec.Code != http.StatusOK || rec.Body.String() != "apk-bytes" {
		t.Errorf("раздача APK: %d %q", rec.Code, rec.Body.String())
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/vnd.android.package-archive" {
		t.Errorf("Content-Type = %q", ct)
	}

	// явный APP_APK_URL важнее своей раздачи
	v.ApkURL = "https://example/app.apk"
	if got := versionJSON(t, v); got.ApkURL != "https://example/app.apk" {
		t.Errorf("явный адрес потерян: %q", got.ApkURL)
	}
}

func TestLoadAppVersion(t *testing.T) {
	dir := t.TempDir()
	write := func(name, body string) string {
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		return path
	}
	cases := []struct {
		name, body string
		want       int
	}{
		{"ok", "# комментарий\nversionCode = 47\nversionName=1.0.0\n", 47},
		{"no-code", "versionName=1.0.0\n", 0},
		{"garbage", "versionCode=abc\n", 0},
		{"commented", "#versionCode=47\n", 0},
	}
	for _, c := range cases {
		if got := LoadAppVersion(write(c.name, c.body)).VersionCode; got != c.want {
			t.Errorf("%s: got %d, want %d", c.name, got, c.want)
		}
	}
	if got := LoadAppVersion(filepath.Join(dir, "missing")).VersionCode; got != 0 {
		t.Errorf("нет файла: got %d", got)
	}
	// настоящий файл репозитория читается с того же относительного пути, что и на сервере
	real := LoadAppVersion(filepath.Join("..", "..", AppVersionFile))
	if real.VersionCode <= 0 {
		t.Errorf("app-version.properties в корне репозитория: versionCode = %d", real.VersionCode)
	}
}

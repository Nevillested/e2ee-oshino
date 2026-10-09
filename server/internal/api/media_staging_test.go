package api

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/google/uuid"
)

func newTestStaging(t *testing.T, minFreeMB string) *MediaStaging {
	t.Helper()
	t.Setenv("MEDIA_STAGING_DIR", t.TempDir())
	t.Setenv("MEDIA_STAGING_MIN_FREE_MB", minFreeMB)
	s := NewMediaStaging()
	if s == nil {
		t.Fatal("буфер не создался")
	}
	return s
}

func TestStagingSaveAndOpen(t *testing.T) {
	s := newTestStaging(t, "0")
	id := uuid.NewString()
	data := []byte("шифротекст")
	n, err := s.SaveFile(id, bytes.NewReader(data))
	if err != nil || n != int64(len(data)) {
		t.Fatalf("SaveFile: n=%d err=%v", n, err)
	}
	if _, err := os.Stat(s.filePath(id) + ".tmp"); !os.IsNotExist(err) {
		t.Fatal(".tmp остался после записи")
	}
	f, err := s.Open(id)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	got, _ := io.ReadAll(f)
	if !bytes.Equal(got, data) {
		t.Fatalf("прочитано %q", got)
	}
}

func TestStagingRejectsBadMediaID(t *testing.T) {
	s := newTestStaging(t, "0")
	for _, bad := range []string{"../etc/passwd", "", "abc", "x/" + uuid.NewString()} {
		if _, err := s.SaveFile(bad, strings.NewReader("x")); err == nil {
			t.Errorf("SaveFile(%q) должен был отказать", bad)
		}
		if _, err := s.Open(bad); err == nil {
			t.Errorf("Open(%q) должен был отказать", bad)
		}
		if _, err := s.NewChunkedUpload(bad); err == nil {
			t.Errorf("NewChunkedUpload(%q) должен был отказать", bad)
		}
	}
}

func TestStagingChunkedUpload(t *testing.T) {
	s := newTestStaging(t, "0")
	id := uuid.NewString()
	uploadID, err := s.NewChunkedUpload(id)
	if err != nil || !isLocalUploadID(uploadID) {
		t.Fatalf("NewChunkedUpload: %q %v", uploadID, err)
	}

	parts := [][]byte{[]byte("aaaa"), []byte("bbbb"), []byte("cc")}
	// чужой upload_id не принимается
	if err := s.WritePart(id, localUploadIDPrefix+"wrong", 1, parts[0]); err == nil {
		t.Fatal("часть с чужим upload_id принята")
	}
	// части приходят не по порядку
	for _, pn := range []int{3, 1} {
		if err := s.WritePart(id, uploadID, pn, parts[pn-1]); err != nil {
			t.Fatal(err)
		}
	}
	// без части 2 склейка невозможна
	if _, _, err := s.CompleteChunkedUpload(id, uploadID); err == nil {
		t.Fatal("склейка без части 2 прошла")
	}
	listed, err := s.ListParts(id, uploadID)
	if err != nil || len(listed) != 2 || listed[0].Number != 1 || listed[1].Number != 3 || listed[1].Size != 2 {
		t.Fatalf("ListParts: %+v %v", listed, err)
	}
	if err := s.WritePart(id, uploadID, 2, parts[1]); err != nil {
		t.Fatal(err)
	}
	total, count, err := s.CompleteChunkedUpload(id, uploadID)
	if err != nil || total != 10 || count != 3 {
		t.Fatalf("Complete: total=%d count=%d err=%v", total, count, err)
	}
	got, _ := os.ReadFile(s.filePath(id))
	if string(got) != "aaaabbbbcc" {
		t.Fatalf("собрано %q", got)
	}
	if _, err := os.Stat(s.chunkDir(id)); !os.IsNotExist(err) {
		t.Fatal("папка частей не удалена после склейки")
	}
}

func TestStagingAbort(t *testing.T) {
	s := newTestStaging(t, "0")
	id := uuid.NewString()
	uploadID, _ := s.NewChunkedUpload(id)
	_ = s.WritePart(id, uploadID, 1, []byte("x"))
	if err := s.AbortChunkedUpload(id, uploadID); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(s.chunkedRoot(), id)); !os.IsNotExist(err) {
		t.Fatal("папка не удалена после отмены")
	}
}

func TestStagingCanAccept(t *testing.T) {
	var nilStaging *MediaStaging
	if nilStaging.CanAccept(1) {
		t.Fatal("выключенный буфер принял файл")
	}
	if _, err := nilStaging.Open(uuid.NewString()); err == nil {
		t.Fatal("выключенный буфер открыл файл")
	}

	s := newTestStaging(t, "0")
	if !s.CanAccept(1) {
		t.Fatal("1 байт не поместился при нулевом запасе")
	}
	// запас больше любого реального диска — не принимаем ничего
	huge := newTestStaging(t, "1000000000")
	if huge.CanAccept(1) {
		t.Fatal("файл принят, хотя запаса свободного места нет")
	}
}

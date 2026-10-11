package api

import (
	"archive/zip"
	"bytes"
	"compress/gzip"
	"image"
	"image/png"
	"net/http"
	"testing"
)

func pngBytes(t *testing.T, w, h int) []byte {
	t.Helper()
	var b bytes.Buffer
	if err := png.Encode(&b, image.NewRGBA(image.Rect(0, 0, w, h))); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

func tgsBytes(t *testing.T, json string) []byte {
	t.Helper()
	var b bytes.Buffer
	zw := gzip.NewWriter(&b)
	zw.Write([]byte(json))
	zw.Close()
	return b.Bytes()
}

func TestInspectSticker(t *testing.T) {
	cases := []struct {
		name, file string
		data       []byte
		format     string
		code       string
	}{
		{"png ok", "1.png", pngBytes(t, 512, 512), "png", ""},
		{"png too wide", "2.png", pngBytes(t, 513, 100), "", "file.badDimensions"},
		{"tgs ok", "3.tgs", tgsBytes(t, `{"w":512,"h":512,"layers":[{}]}`), "tgs", ""},
		{"tgs no layers", "4.tgs", tgsBytes(t, `{"w":512,"h":512,"layers":[]}`), "", "file.corrupt"},
		{"webm", "5.webm", []byte("\x1aE\xdf\xa3 webm"), "", "file.webm"},
		{"text", "6.txt", []byte("hello"), "", "file.unsupported"},
		{"png renamed to jpg — по содержимому", "7.jpg", pngBytes(t, 100, 100), "png", ""},
	}
	for _, c := range cases {
		format, err := inspectSticker(c.file, c.data)
		code := ""
		if err != nil {
			code = err.Code
		}
		if format != c.format || code != c.code {
			t.Errorf("%s: got (%q, %q), want (%q, %q)", c.name, format, code, c.format, c.code)
		}
	}
}

func TestStickerEntriesOrderAndJunk(t *testing.T) {
	var b bytes.Buffer
	zw := zip.NewWriter(&b)
	for _, name := range []string{"pack/10.png", "pack/2.png", "__MACOSX/pack/._2.png", "pack/.DS_Store", "pack/1.png"} {
		w, _ := zw.Create(name)
		w.Write([]byte("x"))
	}
	zw.Close()
	r, err := zip.NewReader(bytes.NewReader(b.Bytes()), int64(b.Len()))
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, e := range stickerEntries(r) {
		got = append(got, e.name)
	}
	want := []string{"pack/1.png", "pack/2.png", "pack/10.png"}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v, want %v", got, want)
		}
	}
}

func TestValidPackTitle(t *testing.T) {
	for title, want := range map[string]bool{
		"Котики":       true,
		"Cats 2":       true,
		"Ёжики и Ёлки": true,
		"":             false,
		" Котики":      false,
		"Котики!":      false,
		"emoji😀":       false,
		"Очень длинное название пака": false,
		"12345678901234567890":        true,
		"123456789012345678901":       false,
	} {
		if got := validPackTitle(title); got != want {
			t.Errorf("%q: got %v, want %v", title, got, want)
		}
	}
}

// Маршруты стикеров не должны конфликтовать — иначе ServeMux падает при запуске сервера.
func TestStickerRoutesRegister(t *testing.T) {
	mux := http.NewServeMux()
	ok := func(http.ResponseWriter, *http.Request) {}
	for _, p := range []string{
		"POST /stickers/packs",
		"GET /stickers/packs/mine",
		"GET /stickers/packs/{pack_id}",
		"GET /stickers/packs/{pack_id}/files",
		"POST /stickers/packs/{pack_id}/install",
		"DELETE /stickers/packs/{pack_id}/install",
		"DELETE /stickers/packs/{pack_id}",
		"GET /stickers/items/{sticker_id}",
		"GET /stickers/items/{sticker_id}/pack",
	} {
		mux.HandleFunc(p, ok)
	}
}

package api

import (
	"context"
	"encoding/binary"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// ebml — элемент: id (как есть, с битом длины) и размер 8-байтовым vint.
func ebml(id []byte, body ...[]byte) []byte {
	var payload []byte
	for _, b := range body {
		payload = append(payload, b...)
	}
	size := make([]byte, 8)
	binary.BigEndian.PutUint64(size, uint64(len(payload)))
	size[0] = 0x01
	out := append(append([]byte{}, id...), size...)
	return append(out, payload...)
}

func ebmlU(v uint64) []byte {
	b := make([]byte, 8)
	binary.BigEndian.PutUint64(b, v)
	return b
}

func ebmlF(v float64) []byte {
	b := make([]byte, 8)
	binary.BigEndian.PutUint64(b, math.Float64bits(v))
	return b
}

// fakeWebm — заголовок WebM: тип документа, длительность (мс), дорожки.
func fakeWebm(docType string, durationMs float64, tracks ...[]byte) []byte {
	return append(
		ebml([]byte{0x1A, 0x45, 0xDF, 0xA3}, ebml([]byte{0x42, 0x82}, []byte(docType))),
		ebml([]byte{0x18, 0x53, 0x80, 0x67},
			ebml([]byte{0x15, 0x49, 0xA9, 0x66},
				ebml([]byte{0x2A, 0xD7, 0xB1}, ebmlU(1_000_000)),
				ebml([]byte{0x44, 0x89}, ebmlF(durationMs)),
			),
			ebml([]byte{0x16, 0x54, 0xAE, 0x6B}, tracks...),
			ebml([]byte{0x1F, 0x43, 0xB6, 0x75}, []byte("кадры")),
		)...,
	)
}

func videoTrack(codec string, w, h uint64) []byte {
	return ebml([]byte{0xAE},
		ebml([]byte{0x83}, ebmlU(1)),
		ebml([]byte{0x86}, []byte(codec)),
		ebml([]byte{0xE0}, ebml([]byte{0xB0}, ebmlU(w)), ebml([]byte{0xBA}, ebmlU(h))),
	)
}

func audioTrack() []byte {
	return ebml([]byte{0xAE}, ebml([]byte{0x83}, ebmlU(2)), ebml([]byte{0x86}, []byte("A_OPUS")))
}

func TestParseWebM(t *testing.T) {
	info, err := parseWebM(fakeWebm("webm", 2960, videoTrack("V_VP9", 512, 384)))
	if err != nil {
		t.Fatal(err)
	}
	if info.docType != "webm" || info.codec != "V_VP9" || info.width != 512 || info.height != 384 || info.hasAudio {
		t.Fatalf("разобрано не то: %+v", info)
	}
	if math.Abs(info.seconds-2.96) > 1e-9 {
		t.Fatalf("длительность %v", info.seconds)
	}
}

func TestCheckWebmSticker(t *testing.T) {
	for name, c := range map[string]struct {
		data []byte
		code string
	}{
		"годный":           {fakeWebm("webm", 3000, videoTrack("V_VP9", 512, 512)), ""},
		"VP8":              {fakeWebm("webm", 1000, videoTrack("V_VP8", 100, 512)), ""},
		"длинный":          {fakeWebm("webm", 3500, videoTrack("V_VP9", 512, 512)), "file.badDuration"},
		"без длительности": {fakeWebm("webm", 0, videoTrack("V_VP9", 512, 512)), "file.badDuration"},
		"со звуком":        {fakeWebm("webm", 2000, videoTrack("V_VP9", 512, 512), audioTrack()), "file.hasAudio"},
		"AV1":              {fakeWebm("webm", 2000, videoTrack("V_AV1", 512, 512)), "file.badCodec"},
		"большой кадр":     {fakeWebm("webm", 2000, videoTrack("V_VP9", 640, 512)), "file.badDimensions"},
		"matroska":         {fakeWebm("matroska", 2000, videoTrack("V_VP9", 512, 512)), ""},
		"чужой контейнер":  {fakeWebm("mkv3d", 2000, videoTrack("V_VP9", 512, 512)), "file.corrupt"},
		"мусор":            {[]byte{0x1A, 0x45, 0xDF, 0xA3, 0x00}, "file.corrupt"},
		"тяжёлый":          {append(fakeWebm("webm", 2000, videoTrack("V_VP9", 512, 512)), make([]byte, maxWebmStickerSz)...), "file.tooLarge"},
	} {
		format, err := inspectSticker(name+".webm", c.data)
		switch {
		case c.code == "" && (err != nil || format != "webm"):
			t.Errorf("%s: ждали webm, получили %q %v", name, format, err)
		case c.code != "" && (err == nil || err.Code != c.code):
			t.Errorf("%s: ждали %s, получили %v", name, c.code, err)
		}
	}
}

// Настоящая перекодировка: прозрачный VP9 → анимированный WebP с альфой.
func TestConvertWebm(t *testing.T) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("ffmpeg не установлен")
	}
	dir := t.TempDir()
	src := filepath.Join(dir, "src.webm")
	gen := exec.Command(ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
		"-i", "testsrc2=s=256x256:d=1:r=20,format=yuva420p,geq=lum='lum(X,Y)':a='if(gt(X,128),255,0)'",
		"-c:v", "libvpx-vp9", "-pix_fmt", "yuva420p", "-b:v", "200k", "-an", src)
	if out, err := gen.CombinedOutput(); err != nil {
		t.Skipf("ffmpeg не собрал тестовый WEBM: %v %s", err, out)
	}
	data, err := os.ReadFile(src)
	if err != nil {
		t.Fatal(err)
	}
	if format, cerr := inspectSticker("src.webm", data); cerr != nil || format != "webm" {
		t.Fatalf("проверка: %q %v", format, cerr)
	}
	webp, cerr := convertWebm(context.Background(), ffmpeg, dir, "src.webm", data)
	if cerr != nil {
		t.Fatal(cerr)
	}
	// RIFF....WEBPVP8X, флаги: 0x10 — альфа, 0x02 — анимация
	if len(webp) < 30 || string(webp[0:4]) != "RIFF" || string(webp[8:16]) != "WEBPVP8X" {
		t.Fatalf("не WebP VP8X: % x", webp[:min(len(webp), 32)])
	}
	if webp[20]&0x10 == 0 || webp[20]&0x02 == 0 {
		t.Fatalf("флаги VP8X %#x — нет альфы или анимации", webp[20])
	}
	if format, cerr := inspectSticker("out.webp", webp); cerr != nil || format != "webp" {
		t.Fatalf("результат не проходит как webp: %q %v", format, cerr)
	}
}

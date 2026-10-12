package api

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"log"
	"math"
	"math/bits"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

// WEBM-стикеры (видео VP8/VP9 с прозрачностью). Встроенные декодеры Android
// альфа-канал WebM не показывают, поэтому сервер при загрузке перекодирует
// каждый WEBM в анимированный WebP (ffmpeg: libvpx умеет альфу, libwebp_anim
// её сохраняет) — клиенту приходит обычный стикер формата webp.

const (
	maxWebmStickerSz = 256 * 1024
	maxWebmSeconds   = 3
	// длительность в заголовке бывает чуть больше из-за округления последнего кадра
	webmDurationSlack = 0.05
	// одна попытка перекодирования одного стикера
	webmConvertTimeout = 60 * time.Second
)

var errBadWebM = errors.New("webm: повреждённый заголовок")

// webmInfo — то, что нужно для проверки, из заголовка WebM.
type webmInfo struct {
	docType  string
	codec    string // CodecID видеодорожки: V_VP8 / V_VP9
	hasAudio bool
	width    uint64
	height   uint64
	seconds  float64 // 0 — длительность не указана
}

// readVint — число переменной длины EBML. [keepMarker] — для id (с битом
// длины), иначе — для размера (без него).
func readVint(b []byte, keepMarker bool) (uint64, int, bool) {
	if len(b) == 0 || b[0] == 0 {
		return 0, 0, false
	}
	l := bits.LeadingZeros8(b[0]) + 1
	if len(b) < l {
		return 0, 0, false
	}
	v := uint64(b[0])
	if !keepMarker {
		v &= (1 << (8 - l)) - 1
	}
	for i := 1; i < l; i++ {
		v = v<<8 | uint64(b[i])
	}
	return v, l, true
}

// ebmlElements — дочерние элементы [b] по порядку; [visit] вернул false —
// дальше не идём. Размер "неизвестен" (потоковая запись) или больше
// оставшегося — элемент до конца родителя.
func ebmlElements(b []byte, visit func(id uint64, body []byte) bool) error {
	for len(b) > 0 {
		id, n, ok := readVint(b, true)
		if !ok {
			return errBadWebM
		}
		b = b[n:]
		size, m, ok := readVint(b, false)
		if !ok {
			return errBadWebM
		}
		b = b[m:]
		if size == (1<<(7*uint(m)))-1 || size > uint64(len(b)) {
			size = uint64(len(b))
		}
		if !visit(id, b[:size]) {
			return nil
		}
		b = b[size:]
	}
	return nil
}

func ebmlUint(b []byte) uint64 {
	var v uint64
	for _, c := range b {
		v = v<<8 | uint64(c)
	}
	return v
}

func ebmlFloat(b []byte) float64 {
	switch len(b) {
	case 4:
		return float64(math.Float32frombits(binary.BigEndian.Uint32(b)))
	case 8:
		return math.Float64frombits(binary.BigEndian.Uint64(b))
	}
	return 0
}

func ebmlString(b []byte) string {
	for i, c := range b {
		if c == 0 {
			return string(b[:i])
		}
	}
	return string(b)
}

// ID элементов Matroska/WebM, которые нужны для проверки.
const (
	idEBML          = 0x1A45DFA3
	idDocType       = 0x4282
	idSegment       = 0x18538067
	idInfo          = 0x1549A966
	idTimecodeScale = 0x2AD7B1
	idDuration      = 0x4489
	idTracks        = 0x1654AE6B
	idTrackEntry    = 0xAE
	idTrackType     = 0x83
	idCodecID       = 0x86
	idVideo         = 0xE0
	idPixelWidth    = 0xB0
	idPixelHeight   = 0xBA
	idCluster       = 0x1F43B675
)

// parseWebM — тип документа, кодек, звук, размеры и длительность из
// заголовка; кадры (кластеры) не читаются.
func parseWebM(data []byte) (webmInfo, error) {
	var info webmInfo
	timescale := uint64(1_000_000) // нс на единицу Duration по умолчанию
	var duration float64
	videoSeen := false
	var parseErr error
	note := func(err error) {
		if err != nil && parseErr == nil {
			parseErr = err
		}
	}
	note(ebmlElements(data, func(id uint64, body []byte) bool {
		switch id {
		case idEBML:
			note(ebmlElements(body, func(id uint64, b []byte) bool {
				if id == idDocType {
					info.docType = ebmlString(b)
				}
				return true
			}))
		case idSegment:
			note(ebmlElements(body, func(id uint64, b []byte) bool {
				switch id {
				case idInfo:
					note(ebmlElements(b, func(id uint64, v []byte) bool {
						switch id {
						case idTimecodeScale:
							if s := ebmlUint(v); s > 0 {
								timescale = s
							}
						case idDuration:
							duration = ebmlFloat(v)
						}
						return true
					}))
				case idTracks:
					note(ebmlElements(b, func(id uint64, entry []byte) bool {
						if id != idTrackEntry {
							return true
						}
						var kind uint64
						var codec string
						var w, h uint64
						note(ebmlElements(entry, func(id uint64, v []byte) bool {
							switch id {
							case idTrackType:
								kind = ebmlUint(v)
							case idCodecID:
								codec = ebmlString(v)
							case idVideo:
								note(ebmlElements(v, func(id uint64, p []byte) bool {
									switch id {
									case idPixelWidth:
										w = ebmlUint(p)
									case idPixelHeight:
										h = ebmlUint(p)
									}
									return true
								}))
							}
							return true
						}))
						switch kind {
						case 1: // видео — первая дорожка
							if !videoSeen {
								videoSeen = true
								info.codec, info.width, info.height = codec, w, h
							}
						case 2:
							info.hasAudio = true
						}
						return true
					}))
				case idCluster:
					return false // дальше — кадры
				}
				return true
			}))
			return false
		}
		return true
	}))
	if parseErr != nil {
		return info, parseErr
	}
	info.seconds = duration * float64(timescale) / 1e9
	return info, nil
}

// checkWebmSticker — видеостикер: WebM/Matroska VP8/VP9 без звука, до
// 256 КБ, до 3 с, сторона до 512.
func checkWebmSticker(name string, data []byte) (string, *stickerCheckError) {
	if len(data) > maxWebmStickerSz {
		return "", &stickerCheckError{Code: "file.tooLarge", Name: name, Limit: maxWebmStickerSz / 1024}
	}
	info, err := parseWebM(data)
	// WebM — подмножество Matroska: многие видеостикеры записаны с DocType
	// "matroska", внутри то же VP8/VP9 — кодек проверяется ниже
	if err != nil || (info.docType != "webm" && info.docType != "matroska") {
		return "", &stickerCheckError{Code: "file.corrupt", Name: name}
	}
	if info.codec != "V_VP8" && info.codec != "V_VP9" {
		return "", &stickerCheckError{Code: "file.badCodec", Name: name}
	}
	if info.hasAudio {
		return "", &stickerCheckError{Code: "file.hasAudio", Name: name}
	}
	if info.width == 0 || info.height == 0 || info.width > maxStickerSide || info.height > maxStickerSide {
		return "", &stickerCheckError{Code: "file.badDimensions", Name: name, Limit: maxStickerSide}
	}
	if info.seconds <= 0 || info.seconds > maxWebmSeconds+webmDurationSlack {
		return "", &stickerCheckError{Code: "file.badDuration", Name: name, Limit: maxWebmSeconds}
	}
	return "webm", nil
}

// webmAttempt — параметры перекодирования: сначала качество, если файл
// вышел больше предела — грубее и реже кадры.
type webmAttempt struct {
	quality int
	fps     int // 0 — как в исходнике
}

var webmAttempts = []webmAttempt{{75, 0}, {55, 24}, {40, 20}}

// convertWebm — WebM в анимированный WebP с прозрачностью, не больше
// maxStaticStickerSz (его же ждут клиенты при распаковке пака).
func convertWebm(ctx context.Context, ffmpeg, workDir, name string, data []byte) ([]byte, *stickerCheckError) {
	info, err := parseWebM(data)
	if err != nil {
		return nil, &stickerCheckError{Code: "file.corrupt", Name: name}
	}
	// альфу WebM понимает только декодер libvpx (встроенный в ffmpeg её теряет)
	decoder := "libvpx-vp9"
	if info.codec == "V_VP8" {
		decoder = "libvpx"
	}
	dir, err := os.MkdirTemp(workDir, ".webm-*")
	if err != nil {
		return nil, &stickerCheckError{Code: "server.error"}
	}
	defer os.RemoveAll(dir)
	in := filepath.Join(dir, "in.webm")
	out := filepath.Join(dir, "out.webp")
	if err := os.WriteFile(in, data, 0o600); err != nil {
		return nil, &stickerCheckError{Code: "server.error"}
	}
	for _, a := range webmAttempts {
		if ctx.Err() != nil {
			return nil, &stickerCheckError{Code: "cancelled"}
		}
		args := []string{"-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-c:v", decoder, "-i", in, "-an"}
		if a.fps > 0 {
			args = append(args, "-vf", fmt.Sprintf("fps=%d", a.fps))
		}
		args = append(args,
			"-c:v", "libwebp_anim", "-lossless", "0", "-q:v", fmt.Sprint(a.quality), "-compression_level", "4",
			"-loop", "0", "-pix_fmt", "yuva420p", out,
		)
		attemptCtx, cancel := context.WithTimeout(ctx, webmConvertTimeout)
		output, runErr := exec.CommandContext(attemptCtx, ffmpeg, args...).CombinedOutput()
		cancel()
		if runErr != nil {
			if ctx.Err() != nil {
				return nil, &stickerCheckError{Code: "cancelled"}
			}
			log.Printf("стикеры: ffmpeg не перекодировал %s: %v %s", name, runErr, output)
			return nil, &stickerCheckError{Code: "file.convertFailed", Name: name}
		}
		webp, err := os.ReadFile(out)
		if err != nil {
			return nil, &stickerCheckError{Code: "server.error"}
		}
		if len(webp) <= maxStaticStickerSz {
			return webp, nil
		}
	}
	return nil, &stickerCheckError{Code: "file.convertTooLarge", Name: name, Limit: maxStaticStickerSz / 1024}
}

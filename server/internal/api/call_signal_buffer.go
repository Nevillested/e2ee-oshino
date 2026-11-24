package api

import (
	"sync"
	"time"
)

// callSignalBufferTTL — сколько держим сигналы звонка устройству, выпавшему из
// сети. Столько же клиент ждёт соединения после ответа (mediaConnectTimeout)
// и восстановления посреди разговора (iceRecoveryTimeout).
const CallSignalBufferTTL = 30 * time.Second

// callSignalBufferMax — предел кадров на устройство (ICE-кандидатов за звонок —
// десятки; больше — что-то пошло не так, старые выбрасываем).
const callSignalBufferMax = 200

// CallSignalBuffer — сигналы уже идущего звонка (call_answer, call_ice,
// call_end…) устройству, которое на секунды выпало из сети. Типичный случай:
// у звонящего оборвался WebSocket, пока шли гудки, а собеседник в эту паузу
// ответил — раньше ответ терялся (отправителю уходил call_unavailable, и он
// клал трубку), хотя звонящий возвращался через несколько секунд и так и
// гудел до таймаута. Теперь кадры ждут здесь и уходят ему сразу при
// переподключении (см. NewWebSocketHandler). Звонок ещё не дошедший до
// получателя (call_offer и всё вслед) — в PendingCallRegistry, не здесь.
//
// Только память, как и PendingCallRegistry: звонок эфемерен.
type CallSignalBuffer struct {
	mu      sync.Mutex
	ttl     time.Duration
	entries map[string]*bufferedCallSignals
}

type bufferedCallSignals struct {
	frames [][]byte
	timer  *time.Timer
}

func NewCallSignalBuffer(ttl time.Duration) *CallSignalBuffer {
	return &CallSignalBuffer{ttl: ttl, entries: make(map[string]*bufferedCallSignals)}
}

// Add — кадр для устройства не в сети; каждый новый кадр продлевает срок.
func (b *CallSignalBuffer) Add(toDeviceID string, frame []byte) {
	b.mu.Lock()
	defer b.mu.Unlock()

	entry, ok := b.entries[toDeviceID]
	if !ok {
		entry = &bufferedCallSignals{}
		b.entries[toDeviceID] = entry
	} else {
		entry.timer.Stop()
	}
	entry.frames = append(entry.frames, frame)
	if len(entry.frames) > callSignalBufferMax {
		entry.frames = entry.frames[len(entry.frames)-callSignalBufferMax:]
	}
	entry.timer = time.AfterFunc(b.ttl, func() { b.expire(toDeviceID, entry) })
}

// Take забирает накопленное для подключившегося устройства (в исходном порядке).
func (b *CallSignalBuffer) Take(toDeviceID string) [][]byte {
	b.mu.Lock()
	defer b.mu.Unlock()

	entry, ok := b.entries[toDeviceID]
	if !ok {
		return nil
	}
	entry.timer.Stop()
	delete(b.entries, toDeviceID)
	return entry.frames
}

// expire убирает запись по сроку, только если это всё ещё она (не забрана и не заведена заново).
func (b *CallSignalBuffer) expire(toDeviceID string, entry *bufferedCallSignals) {
	b.mu.Lock()
	defer b.mu.Unlock()

	if b.entries[toDeviceID] == entry {
		delete(b.entries, toDeviceID)
	}
}

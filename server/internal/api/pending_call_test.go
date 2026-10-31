package api

import (
	"sync/atomic"
	"testing"
	"time"
)

// Обрыв 2026-10-31: offer дошёл до получателя живьём, но ack опоздал —
// звонок встал в отложенные, разговор начался, а через TTL звонящему ушёл
// call_unavailable. Сигнал получателя по звонку снимает запись, и по TTL
// "недоступен" больше не уходит.
func TestPendingCallTakenByRecipientSignalDoesNotExpire(t *testing.T) {
	reg := NewPendingCallRegistry()
	var unavailable atomic.Int32
	reg.Start("callee", "c1", "caller", []byte("offer"), 30*time.Millisecond, func() {
		if reg.Expire("callee", "c1") {
			unavailable.Add(1)
		}
	})
	if reg.TakeIfSame("callee", "c1") == nil {
		t.Fatal("отложенный звонок должен сниматься по сигналу получателя")
	}
	time.Sleep(80 * time.Millisecond)
	if unavailable.Load() != 0 {
		t.Fatal("после снятия звонка call_unavailable уходить не должен")
	}
}

func TestPendingCallExpiresWhenNobodyTookIt(t *testing.T) {
	reg := NewPendingCallRegistry()
	done := make(chan bool, 1)
	reg.Start("callee", "c1", "caller", []byte("offer"), 10*time.Millisecond, func() {
		done <- reg.Expire("callee", "c1")
	})
	select {
	case expired := <-done:
		if !expired {
			t.Fatal("никем не забранный звонок должен истечь")
		}
	case <-time.After(time.Second):
		t.Fatal("таймер не сработал")
	}
}

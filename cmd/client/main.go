package main

import (
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// TCP flood client - generates sustained TCP traffic to a receiver.
// Each instance runs from a separate pod (unique source IP) so the kernel's
// SO_REUSEPORT flow hash distributes connections across receiver cores.

var (
	target      = flag.String("target", "", "target host:port (required)")
	connections = flag.Int("conns", 32, "number of concurrent TCP connections")
	duration    = flag.Duration("duration", 60*time.Second, "test duration")
	payloadSize = flag.Int("payload", 4096, "payload size per write in bytes")
)

var totalBytes atomic.Int64
var totalConns atomic.Int64

func main() {
	flag.Parse()

	if *target == "" {
		log.Fatal("--target is required (e.g., receiver-svc:8080)")
	}

	log.Printf("Starting client: target=%s conns=%d duration=%v payload=%d",
		*target, *connections, *duration, *payloadSize)

	// Create stop channel
	stop := make(chan struct{})

	// Start reporter
	go reporter(stop)

	// Launch connections
	var wg sync.WaitGroup
	for i := 0; i < *connections; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			runConnection(id, stop)
		}(i)
	}

	// Wait for duration or signal
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)

	select {
	case <-time.After(*duration):
		log.Println("Duration reached, stopping...")
	case s := <-sig:
		log.Printf("Signal %v received, stopping...", s)
	}

	close(stop)
	wg.Wait()

	// Final report
	totalB := totalBytes.Load()
	bps := float64(totalB) * 8 / duration.Seconds()
	fmt.Printf("\n=== FINAL: sent %.2f GB (%.2f Gb/s avg), %d connections ===\n",
		float64(totalB)/1e9, bps/1e9, totalConns.Load())
}

func runConnection(id int, stop <-chan struct{}) {
	payload := make([]byte, *payloadSize)
	// Fill with non-zero data to avoid compression optimizations
	for i := range payload {
		payload[i] = byte(i % 251)
	}

	for {
		select {
		case <-stop:
			return
		default:
		}

		conn, err := net.DialTimeout("tcp", *target, 5*time.Second)
		if err != nil {
			log.Printf("conn %d: dial error: %v (retrying...)", id, err)
			time.Sleep(100 * time.Millisecond)
			continue
		}
		totalConns.Add(1)

		// Blast data until stopped or error
		for {
			select {
			case <-stop:
				conn.Close()
				return
			default:
			}

			n, err := conn.Write(payload)
			if err != nil {
				conn.Close()
				break // reconnect
			}
			totalBytes.Add(int64(n))
		}
	}
}

func reporter(stop <-chan struct{}) {
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()

	var lastBytes int64
	lastTime := time.Now()

	for {
		select {
		case <-stop:
			return
		case <-ticker.C:
			now := time.Now()
			currBytes := totalBytes.Load()
			elapsed := now.Sub(lastTime).Seconds()
			delta := currBytes - lastBytes

			bitsPerSec := float64(delta) * 8 / elapsed
			var unit string
			var value float64
			switch {
			case bitsPerSec >= 1e9:
				unit = "Gb/s"
				value = bitsPerSec / 1e9
			case bitsPerSec >= 1e6:
				unit = "Mb/s"
				value = bitsPerSec / 1e6
			default:
				unit = "Kb/s"
				value = bitsPerSec / 1e3
			}

			fmt.Printf("[%s] sending=%.2f %s  conns=%d\n",
				now.Format("15:04:05"), value, unit, totalConns.Load())

			lastBytes = currBytes
			lastTime = now
		}
	}
}

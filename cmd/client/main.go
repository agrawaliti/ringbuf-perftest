package main

import (
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"strconv"
	"strings"
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
	qpsRaw      = flag.String("qps", "0", "writes per second per connection; supports suffixes k/m/g (e.g., 5k, 2m), 0 = unlimited")
)

var totalBytes atomic.Int64
var totalConns atomic.Int64
var qpsPerConn int64

func main() {
	flag.Parse()

	if *target == "" {
		log.Fatal("--target is required (e.g., receiver-svc:8080)")
	}

	parsedQPS, err := parseQPS(*qpsRaw)
	if err != nil {
		log.Fatalf("invalid --qps value %q: %v", *qpsRaw, err)
	}
	qpsPerConn = parsedQPS

	log.Printf("Starting client: target=%s conns=%d duration=%v payload=%d",
		*target, *connections, *duration, *payloadSize)
	if qpsPerConn > 0 {
		log.Printf("Rate limit enabled: %d writes/s per connection", qpsPerConn)
	}

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

	var ticker *time.Ticker
	if qpsPerConn > 0 {
		interval := time.Second / time.Duration(qpsPerConn)
		if interval <= 0 {
			interval = time.Nanosecond
		}
		ticker = time.NewTicker(interval)
		defer ticker.Stop()
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

			if ticker != nil {
				select {
				case <-stop:
					conn.Close()
					return
				case <-ticker.C:
				}
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

func parseQPS(raw string) (int64, error) {
	v := strings.TrimSpace(strings.ToLower(raw))
	if v == "" {
		return 0, fmt.Errorf("empty value")
	}

	multiplier := int64(1)
	suffix := v[len(v)-1]
	switch suffix {
	case 'k':
		multiplier = 1_000
		v = v[:len(v)-1]
	case 'm':
		multiplier = 1_000_000
		v = v[:len(v)-1]
	case 'g':
		multiplier = 1_000_000_000
		v = v[:len(v)-1]
	}

	base, err := strconv.ParseInt(v, 10, 64)
	if err != nil {
		return 0, err
	}
	if base < 0 {
		return 0, fmt.Errorf("must be >= 0")
	}

	if base > 0 && base > (int64(^uint64(0)>>1)/multiplier) {
		return 0, fmt.Errorf("value overflow")
	}

	return base * multiplier, nil
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

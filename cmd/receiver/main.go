package main

import (
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"runtime"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// Multi-threaded TCP receiver using SO_REUSEPORT.
// Replicates the production traffic pattern described in:
// https://blog.zmalik.dev/p/who-will-observe-the-observability
//
// The kernel distributes incoming SYN packets across listeners via flow hashing
// on client source IPs, ensuring packet processing spreads across ALL cores.

var (
	port       = flag.Int("port", 8080, "listen port")
	listeners  = flag.Int("listeners", 0, "number of SO_REUSEPORT listeners (default: NumCPU)")
	workers    = flag.Int("workers", 0, "worker pool size per listener (default: NumCPU)")
	bufSize    = flag.Int("buf", 32*1024, "read buffer size in bytes")
	reportSecs = flag.Int("report", 2, "reporting interval in seconds")
)

var totalBytes atomic.Int64
var totalConns atomic.Int64
var activeConns atomic.Int64

func main() {
	flag.Parse()

	numCPU := runtime.NumCPU()
	if *listeners == 0 {
		*listeners = numCPU
	}
	if *workers == 0 {
		*workers = numCPU
	}

	log.Printf("Starting receiver: port=%d listeners=%d workers=%d cores=%d buf=%d",
		*port, *listeners, *workers, numCPU, *bufSize)

	// Start reporter
	go reporter()

	// Start listeners
	var wg sync.WaitGroup
	for i := 0; i < *listeners; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			runListener(id)
		}(i)
	}

	// Wait for signal
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	log.Println("Shutting down...")
}

func runListener(id int) {
	ln, err := listenReusePort(*port)
	if err != nil {
		log.Fatalf("listener %d: failed to listen: %v", id, err)
	}
	defer ln.Close()

	log.Printf("listener %d: accepting connections on :%d", id, *port)

	// Worker pool with buffered channel
	work := make(chan net.Conn, *workers*4)
	for w := 0; w < *workers; w++ {
		go worker(work)
	}

	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Printf("listener %d: accept error: %v", id, err)
			continue
		}
		totalConns.Add(1)
		activeConns.Add(1)
		work <- conn
	}
}

func worker(work <-chan net.Conn) {
	buf := make([]byte, *bufSize)
	for conn := range work {
		handleConn(conn, buf)
	}
}

func handleConn(conn net.Conn, buf []byte) {
	defer func() {
		conn.Close()
		activeConns.Add(-1)
	}()

	for {
		n, err := conn.Read(buf)
		if n > 0 {
			totalBytes.Add(int64(n))
		}
		if err != nil {
			if err != io.EOF {
				// Connection reset etc - normal under load
			}
			return
		}
	}
}

func reporter() {
	ticker := time.NewTicker(time.Duration(*reportSecs) * time.Second)
	defer ticker.Stop()

	var lastBytes int64
	var lastTime time.Time = time.Now()

	for range ticker.C {
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

		fmt.Printf("[%s] throughput=%.2f %s  conns_total=%d  conns_active=%d\n",
			now.Format("15:04:05"), value, unit, totalConns.Load(), activeConns.Load())

		lastBytes = currBytes
		lastTime = now
	}
}

// listenReusePort creates a TCP listener with SO_REUSEPORT set,
// allowing multiple goroutines/threads to accept on the same port.
// The kernel distributes SYNs via flow hash across all listeners.
func listenReusePort(port int) (net.Listener, error) {
	// Create raw socket
	fd, err := unix.Socket(unix.AF_INET6, unix.SOCK_STREAM, unix.IPPROTO_TCP)
	if err != nil {
		return nil, fmt.Errorf("socket: %w", err)
	}

	// Set SO_REUSEPORT - this is the key for multi-core distribution
	if err := unix.SetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_REUSEPORT, 1); err != nil {
		unix.Close(fd)
		return nil, fmt.Errorf("SO_REUSEPORT: %w", err)
	}

	// Also set SO_REUSEADDR
	if err := unix.SetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_REUSEADDR, 1); err != nil {
		unix.Close(fd)
		return nil, fmt.Errorf("SO_REUSEADDR: %w", err)
	}

	// Bind to all interfaces
	addr := unix.SockaddrInet6{Port: port}
	if err := unix.Bind(fd, &addr); err != nil {
		unix.Close(fd)
		return nil, fmt.Errorf("bind: %w", err)
	}

	// Listen with large backlog
	if err := unix.Listen(fd, 4096); err != nil {
		unix.Close(fd)
		return nil, fmt.Errorf("listen: %w", err)
	}

	// Convert to net.Listener
	file := os.NewFile(uintptr(fd), fmt.Sprintf("reuseport-listener-%d", port))
	ln, err := net.FileListener(file)
	file.Close() // FileListener dups the fd
	if err != nil {
		return nil, fmt.Errorf("FileListener: %w", err)
	}

	return ln, nil
}

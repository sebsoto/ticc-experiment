package main

import (
	"bufio"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"regexp"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// Matches any TICC Time Interval measurement: a line containing only a decimal number
// (e.g. "0.00000000431", "-0.00000042201", "-0.3", "1.23456789012").
// Rejects menu text, config output, and partial lines.
var tiPattern = regexp.MustCompile(`^(-?\d+\.\d+)$`)

func configureSerial(fd int) error {
	termios, err := unix.IoctlGetTermios(fd, unix.TCGETS)
	if err != nil {
		return fmt.Errorf("TCGETS: %w", err)
	}

	// 115200 8N1
	termios.Cflag = unix.B115200 | unix.CS8 | unix.CLOCAL | unix.CREAD
	termios.Iflag = unix.IGNCR // strip \r from input
	termios.Oflag = 0
	termios.Lflag = 0

	// Read returns as soon as 1 byte is available
	termios.Cc[unix.VMIN] = 1
	termios.Cc[unix.VTIME] = 0

	if err := unix.IoctlSetTermios(fd, unix.TCSETS, termios); err != nil {
		return fmt.Errorf("TCSETS: %w", err)
	}
	return nil
}

func main() {
	device := flag.String("device", "/dev/ttyACM0", "TICC serial device")
	output := flag.String("o", "", "output CSV file (default: ticc_TIMESTAMP.csv)")
	duration := flag.Duration("d", 0, "stop after this duration (e.g. 10m, 2h). 0 means run until signal")
	flag.Parse()

	if *output == "" {
		*output = fmt.Sprintf("ticc_%s.csv", time.Now().UTC().Format("20060102_150405"))
	}

	// Open serial device
	fd, err := unix.Open(*device, unix.O_RDWR|unix.O_NOCTTY, 0)
	if err != nil {
		log.Fatalf("open %s: %v", *device, err)
	}
	defer unix.Close(fd)

	if err := configureSerial(fd); err != nil {
		log.Fatalf("configure serial: %v", err)
	}

	// Open output file
	outFile, err := os.Create(*output)
	if err != nil {
		log.Fatalf("create %s: %v", *output, err)
	}
	defer outFile.Close()

	fmt.Fprintln(outFile, "timestamp,offset_s")

	// Handle Ctrl+C
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	serialFile := os.NewFile(uintptr(fd), *device)
	scanner := bufio.NewScanner(serialFile)

	if *duration > 0 {
		log.Printf("Reading from %s → %s (stopping after %s)", *device, *output, *duration)
	} else {
		log.Printf("Reading from %s → %s (Ctrl+C to stop)", *device, *output)
	}

	// Optional timer for auto-stop
	var timerCh <-chan time.Time
	if *duration > 0 {
		timerCh = time.After(*duration)
	}

	count := 0
	done := make(chan struct{})

	go func() {
		for {
			for scanner.Scan() {
				line := strings.TrimSpace(scanner.Text())

				m := tiPattern.FindStringSubmatch(line)
				if m == nil {
					continue
				}

				ts := time.Now().UTC().Format("2006-01-02T15:04:05.000Z")
				fmt.Fprintf(outFile, "%s,%s\n", ts, m[1])
				count++

				if count%100 == 0 {
					log.Printf("%d measurements recorded", count)
				}
			}
			if err := scanner.Err(); err != nil {
				log.Printf("read error: %v — retrying in 1s", err)
			} else {
				log.Printf("scanner EOF after %d measurements — retrying in 1s", count)
			}
			// If no duration set, treat EOF as terminal
			if *duration == 0 {
				break
			}
			time.Sleep(1 * time.Second)
			scanner = bufio.NewScanner(serialFile)
		}
		close(done)
	}()

	select {
	case <-sigCh:
		log.Printf("Stopping. %d measurements written to %s", count, *output)
	case <-timerCh:
		log.Printf("Duration reached. %d measurements written to %s", count, *output)
	case <-done:
		log.Printf("Device closed. %d measurements written to %s", count, *output)
	}
}

# 1 Billion Row Challenge

Solution for the 1 Billion Row Challege using Zig:
- Memory-map the file
- Divide into chunks (one per logical CPU), align chunk boundaries to the next newline
- Each thread scans its chunk, parses station name and integer temperature, updates a local `StringHashMap(StationStats)`
- Main thread merges all chunk maps by iterating keys and combining stats
- Sort output alphabetically, print in the required format

Solution produces output in around 7 seconds

## Setup
1. Create measurements file. Used Zig 0.12.1. Writes a file called “1brc.txt”.

```bash
zig run -Doptimize=ReleaseFast gen1brc.zig
```

2. Build and run

```bash
zig build -Doptimize=ReleaseFast
.\zig-out\bin\1brc.exe
```

Or with a custom path: `.\zig-out\bin\1brc.exe path\to\1brc.txt`

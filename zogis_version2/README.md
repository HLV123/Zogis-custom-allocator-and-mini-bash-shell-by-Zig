# ZOGIS — Custom Memory Allocator & Mini Bash Shell in Zig

> **Một dự án nghiên cứu kết hợp giữa quản lý bộ nhớ cấp thấp (custom allocator) và xây dựng shell tương tác (mini bash) bằng ngôn ngữ Zig, chạy trực tiếp trên terminal Windows.**

---

## Mục lục

- [Giới thiệu](#-giới-thiệu)
- [Mục đích dự án](#-mục-đích-dự-án)
- [Kiến trúc tổng quan](#-kiến-trúc-tổng-quan)
- [Cài đặt môi trường](#-cài-đặt-môi-trường)
- [Build & Chạy chương trình](#-build--chạy-chương-trình)
- [Tính năng đầy đủ](#-tính-năng-đầy-đủ)
- [Hướng dẫn test toàn bộ tính năng](#-hướng-dẫn-test-toàn-bộ-tính-năng)
- [Phân tích mã nguồn từng module](#-phân-tích-mã-nguồn-từng-module)
- [Giá trị nghiên cứu ](#-Value-Portfolio)

---

## Giới thiệu

**ZOGIS** là một **mini bash shell** tự xây dựng hoàn toàn bằng ngôn ngữ [Zig](https://ziglang.org/), chạy trên **hệ điều hành Windows** và sử dụng trực tiếp khung terminal (Windows Console / PowerShell terminal). Dự án không phụ thuộc vào bất kỳ thư viện bên ngoài nào — mọi thứ từ **quản lý bộ nhớ** đến **lexer**, **parser**, và **executor** đều được viết từ đầu.

Điểm nổi bật của dự án:
- **5 loại custom allocator** được thiết kế theo mô hình thực tế (Bump, Arena, Pool, Slab, Debug)
- **Shell tương tác** với đầy đủ tính năng: pipe, redirect, alias, glob, command substitution
- **100% Zig** — không dùng C, không dùng libc, không dependency ngoài
- **Cross-platform** tương thích (thiết kế chính cho Windows, có thể build trên Linux/macOS)

---

## Mục đích dự án

Dự án được xây dựng với **hai mục đích nghiên cứu song song**:

### 1. Custom Memory Allocator — Nghiên cứu quản lý bộ nhớ cấp thấp

Trong các ngôn ngữ như C/C++/Zig, lập trình viên phải tự quản lý bộ nhớ. Dự án triển khai **5 chiến lược cấp phát bộ nhớ** từ đơn giản đến phức tạp, giúp người đọc hiểu:

| Allocator | Chiến lược | Độ phức tạp | Ứng dụng thực tế |
|---|---|---|---|
| **BumpAllocator** | Con trỏ tuyến tính | O(1) alloc, không free riêng | Scratch buffer, parsing |
| **ArenaAllocator** | Bump + tự mở rộng chunk | O(1) amortized | Lifetime-based allocation |
| **PoolAllocator** | Free-list cố định kích thước | O(1) alloc/free | Object pool, token list |
| **SlabAllocator** | Multi-class pool (Linux SLAB) | O(1) alloc/free | General-purpose shell allocation |
| **DebugAllocator** | Wrapper + guard bytes + tracking | Tùy backing | Leak detection, overflow detection |

### 2. Mini Bash Shell — Nghiên cứu thiết kế trình thông dịch lệnh

Shell là thành phần cốt lõi của mọi hệ điều hành. Dự án triển khai pipeline hoàn chỉnh:

```
User Input → Lexer (tokenize) → Parser (AST) → Executor (run)
```

Giúp người đọc hiểu cách một shell thực sự hoạt động: từ việc tách chuỗi ký tự thành token, xây dựng cây cú pháp, đến việc thực thi lệnh, quản lý process, và xử lý I/O redirection.

---

## Kiến trúc tổng quan

```
zogis/
├── build.zig             # Zig build system configuration
└── src/
    ├── main.zig          # Entry point — REPL loop, allocator setup
    ├── allocator.zig     # 5 custom allocators + unit tests
    ├── lexer.zig         # Tokenizer + expansion ($VAR, ~, $())
    ├── parser.zig        # Recursive descent parser → AST
    └── executor.zig      # Command execution engine
```

### Luồng xử lý chính

```
main.zig
  │
  ├── Khởi tạo allocator chain:
  │     GPA → SlabAllocator → DebugAllocator → tracked allocator
  │
  └── REPL loop:
        │
        ├── Đọc input từ stdin
        ├── Khởi tạo ArenaAllocator cho mỗi lệnh
        ├── Lexer: tokenize input (mở rộng $VAR, ~, $())
        ├── Parser: xây dựng ParsedInput (pipelines + connectors)
        ├── Executor: thực thi từng pipeline
        └── Arena deinit (giải phóng toàn bộ bộ nhớ của lệnh)
```

### Chuỗi allocator (Allocator Chain)

```
┌──────────────────┐
│ GeneralPurpose   │  ← Zig's built-in GPA (backing allocator)
│ Allocator (GPA)  │
└────────┬─────────┘
         │
┌────────▼─────────┐
│  SlabAllocator   │  ← 6 size classes: 8/16/32/64/128/256 bytes
│  (Linux SLAB)    │     Allocations > 256b → fallback to GPA
└────────┬─────────┘
         │
┌────────▼─────────┐
│ DebugAllocator   │  ← Guard bytes + leak tracking + stats
│ (wrapper)        │     Powers: meminfo, slabinfo commands
└────────┬─────────┘
         │
┌────────▼─────────┐
│ ArenaAllocator   │  ← Per-command lifetime (lexer + parser)
│ (per command)    │     deinit() frees all at once
└──────────────────┘
```

---

## Cài đặt môi trường

### Yêu cầu hệ thống

- **Hệ điều hành**: Windows 10 / 11
- **Terminal**: Windows PowerShell hoặc Command Prompt
- **Zig**: phiên bản **0.13.0**
- **Dung lượng đĩa**: ~200MB (Zig compiler + cache)

### Bước 1: Tải Zig 0.13.0

1. Truy cập trang tải chính thức: [https://ziglang.org/download/](https://ziglang.org/download/)

2. Tìm mục **0.13.0** và tải bản **Windows x86_64**:
   ```
   zig-windows-x86_64-0.13.0.zip
   ```

3. Hoặc tải trực tiếp qua link:
   ```
   https://ziglang.org/download/0.13.0/zig-windows-x86_64-0.13.0.zip
   ```

### Bước 2: Giải nén và đặt thư mục

1. Giải nén file `.zip` vào một thư mục cố định, ví dụ:
   ```
   C:\zig
   ```

2. Sau khi giải nén, cấu trúc thư mục sẽ là:
   ```
   C:\zig\
   ├── zig.exe
   ├── lib\
   ├── doc\
   └── ...
   ```

> ⚠️ **Lưu ý**: Đảm bảo `zig.exe` nằm trực tiếp trong `C:\zig\`, không phải trong thư mục con.

### Bước 3: Thêm Zig vào biến môi trường PATH

**Cách 1: Qua giao diện (GUI)**

1. Nhấn `Win + S`, tìm **"Environment Variables"** hoặc **"Biến môi trường"**
2. Click **"Environment Variables..."** (Biến môi trường)
3. Trong phần **System variables** (Biến hệ thống), tìm biến **Path** → Click **Edit** (Sửa)
4. Click **New** (Mới) → Nhập: `C:\zig`
5. Click **OK** để lưu tất cả

**Cách 2: Qua PowerShell (admin)**

```powershell
[System.Environment]::SetEnvironmentVariable("Path", $env:Path + ";C:\zig", "Machine")
```

### Bước 4: Kiểm tra cài đặt

**Đóng và mở lại PowerShell**, sau đó chạy:

```powershell
PS C:\Users\ADMIN> zig version
0.13.0
```

Nếu hiện `0.13.0` thì cài đặt thành công. ✅

Nếu báo lỗi `'zig' is not recognized...`, kiểm tra lại bước 3 (PATH).

---

## Build & Chạy chương trình

### Clone / Copy dự án

Copy thư mục dự án vào một vị trí trên máy, ví dụ:
```
D:\zogis
```

### Chạy unit tests

```powershell
PS D:\zogis> zig build test
```

Nếu không có output lỗi → tất cả tests pass. ✅

Tests bao gồm:
- **Allocator tests**: BumpAllocator, ArenaAllocator, PoolAllocator, SlabAllocator, DebugAllocator
- **Lexer tests**: simple command, pipe, `&&`/`||`, quoted string, redirect, cmd substitution
- **Parser tests**: single command, pipeline, connectors, redirect, empty command error

### Build và chạy shell

```powershell
PS D:\zogis> zig build run
```

Kết quả mong đợi:
```
  ______   ____    _____   _____   _____
 |___  /  / __ \  / ____| |_   _| / ____|
    / /  | |  | || |  __    | |  | (___
   / /   | |  | || | |_ |   | |   \___ \
  / /__  | |__| || |__| |  _| |_  ____) |
 /_____|  \____/  \_____| |_____| |_____|

  ==========================================
    Zogis Shell  -  type 'help' for commands
  ==========================================
zogis:D:\zogis$
```

Shell đã sẵn sàng nhận lệnh! Gõ `help` để xem danh sách lệnh.

---

## Tính năng đầy đủ

### Built-in Commands (Lệnh nội bộ)

| Lệnh | Mô tả |
|---|---|
| `help` | Hiển thị danh sách lệnh |
| `exit` / `quit` | Thoát shell |
| `clear` | Xóa màn hình |
| `echo [args]` | In các đối số ra stdout |
| `pwd` | In thư mục hiện tại |
| `cd [dir\|-]` | Đổi thư mục (`-` = quay lại, không đối số = HOME) |
| `history` | Hiển thị lịch sử lệnh |
| `export NAME=VAL` | Đặt biến môi trường shell |
| `export NAME` | Import biến từ process environment |
| `unset NAME` | Xóa biến môi trường |
| `alias NAME=CMD` | Tạo alias cho lệnh |
| `alias` | Liệt kê tất cả alias |
| `unalias NAME` | Xóa alias |

### Memory Commands (Lệnh bộ nhớ)

| Lệnh | Mô tả |
|---|---|
| `meminfo` | Báo cáo DebugAllocator: tổng allocated/freed, peak, leak report |
| `slabinfo` | Báo cáo SlabAllocator: utilization từng size class |
| `benchmark [sz] [n]` | Đo throughput alloc+free (ops/sec) |

### Operators (Toán tử)

| Toán tử | Mô tả |
|---|---|
| `cmd1 \| cmd2` | Pipe stdout của cmd1 vào stdin của cmd2 |
| `cmd1 && cmd2` | Chạy cmd2 chỉ khi cmd1 thành công (exit 0) |
| `cmd1 \|\| cmd2` | Chạy cmd2 chỉ khi cmd1 thất bại (exit ≠ 0) |
| `cmd > file` | Redirect stdout vào file (ghi đè) |
| `cmd >> file` | Redirect stdout vào file (nối thêm) |
| `cmd < file` | Đọc stdin từ file |
| `cmd1 ; cmd2` | Chạy tuần tự, không điều kiện |

### Expansions (Mở rộng)

| Cú pháp | Mô tả |
|---|---|
| `$VAR` / `${VAR}` | Mở rộng biến môi trường |
| `~` | Thư mục home (`C:\Users\ADMIN`) |
| `*.ext` / `?` | Glob patterns (wildcard matching) |
| `$(cmd)` | Command substitution — chạy cmd, thay bằng output |

### External Commands (Lệnh ngoài)

Shell tự động chuyển tiếp các lệnh không phải built-in đến hệ thống:
- Các lệnh Windows (`dir`, `type`, `copy`, `del`, `find`, `findstr`...) được wrap qua `cmd.exe /c`
- Các chương trình `.exe` trong PATH được gọi trực tiếp
- Hỗ trợ stdin/stdout redirect cho external commands

---

## Hướng dẫn test toàn bộ tính năng

Sau khi chạy `zig build run`, lần lượt thực hiện các lệnh sau:

### 1. Echo & Output cơ bản
```bash
echo hello world
echo
echo one two three
```
> ✅ Kỳ vọng: in ra đúng nội dung, dòng trống cho `echo` không đối số

### 2. Redirect `>` (ghi đè) và `>>` (nối thêm)
```bash
echo line1 > test.txt
type test.txt
echo line2 > test.txt
type test.txt
echo hello > out.txt
echo world >> out.txt
echo foo >> out.txt
type out.txt
```
> ✅ Kỳ vọng: `>` ghi đè, `>>` nối thêm. `out.txt` hiển thị 3 dòng: hello, world, foo

### 3. Navigation — pwd, cd
```bash
pwd
cd ..
pwd
cd -
pwd
cd
pwd
cd -
```
> ✅ Kỳ vọng: `cd ..` lên thư mục cha, `cd -` quay lại, `cd` về HOME

### 4. Environment Variables
```bash
export MY_VAR=hello_zogis
echo $MY_VAR
export ANOTHER=world
echo $MY_VAR $ANOTHER
unset MY_VAR
echo $MY_VAR
```
> ✅ Kỳ vọng: biến được set/get đúng, sau `unset` thì rỗng

### 5. Alias
```bash
alias gs="echo git status fake"
alias ll="echo listing files"
alias
gs
ll
unalias gs
alias
gs
```
> ✅ Kỳ vọng: alias hoạt động, sau `unalias` thì `gs` báo "command not found"

### 6. Conditional Operators
```bash
echo first && echo second
notexist_cmd || echo fallback_worked
echo success || echo should_not_appear
echo aaa ; echo bbb ; echo ccc
```
> ✅ Kỳ vọng: `&&` chạy cả hai, `||` chạy fallback khi lỗi, `;` chạy tuần tự

### 7. Command Substitution `$()`
```bash
echo $(echo inner_value)
echo prefix_$(echo middle)_suffix
export DIR=$(pwd)
echo $DIR
```
> ✅ Kỳ vọng: `$(cmd)` thay thế bằng output, `$DIR` chứa đường dẫn hiện tại

### 8. Glob Patterns
```bash
cd src
echo *.zig
echo ?????.zig
cd -
```
> ✅ Kỳ vọng: `*.zig` liệt kê tất cả file .zig, `?????.zig` chỉ match tên 5 ký tự

### 9. Tilde Expansion
```bash
echo ~
cd ~
pwd
cd -
```
> ✅ Kỳ vọng: `~` mở rộng thành thư mục HOME

### 10. Pipe `|`
```bash
echo hello world > test_find.txt
find "hello" test_find.txt
echo hello world | find "hello"
echo line1 > pipe_test.txt
echo line2 >> pipe_test.txt
type pipe_test.txt | find "line2"
```
> ✅ Kỳ vọng: pipe truyền stdout sang stdin đúng, `find` tìm đúng chuỗi

### 11. Combined Operations
```bash
echo combined > combo.txt && echo test >> combo.txt
type combo.txt
```
> ✅ Kỳ vọng: file chứa 2 dòng: "combined" và "test"

### 12. Builtin Redirect (pwd, help, history → file)
```bash
pwd > pwd_out.txt
type pwd_out.txt
help > help_out.txt
type help_out.txt
history > hist.txt
type hist.txt
```
> ✅ Kỳ vọng: output của builtins được ghi vào file đúng

### 13. Memory Commands
```bash
meminfo
slabinfo
benchmark 64 1000
```
> ✅ Kỳ vọng: hiển thị báo cáo bộ nhớ, slab utilization, và benchmark ops/sec

### 14. Misc
```bash
history
clear
help
exit
```
> ✅ Kỳ vọng: history hiển thị tất cả lệnh đã gõ, clear xóa màn hình, exit thoát sạch

---

## Phân tích mã nguồn từng module

### 1. `allocator.zig` — Custom Memory Allocators

Đây là **trái tim kỹ thuật** của dự án. File này triển khai 5 allocator từ đầu, mỗi cái dạy một khái niệm quản lý bộ nhớ khác nhau:

#### BumpAllocator (Bump Pointer / Linear Allocator)
```
Buffer: [████████████░░░░░░░░]
                      ↑ offset
```
- **Nguyên lý**: Duy trì một con trỏ `offset` trong buffer cố định. Mỗi lần alloc, tiến con trỏ lên. Không thể free riêng lẻ — chỉ `reset()` toàn bộ.
- **Người đọc học được**: Cách allocator đơn giản nhất hoạt động, alignment, trade-off giữa tốc độ và linh hoạt.

#### ArenaAllocator (Region-based Allocation)
```
Chunk 1: [████████████████]  ← full
Chunk 2: [████████░░░░░░░░]  ← current
                   ↑ offset
```
- **Nguyên lý**: Mở rộng BumpAllocator — khi chunk hiện tại đầy, cấp chunk mới từ backing allocator. `deinit()` giải phóng tất cả cùng lúc.
- **Người đọc học được**: Lifetime-based memory management, tại sao arena phổ biến trong compiler/game engine.

#### PoolAllocator (Fixed-size Free List)
```
Free list:  slot3 → slot1 → slot5 → null
In use:     [slot0] [slot2] [slot4]
```
- **Nguyên lý**: Chia buffer thành các slot cùng kích thước. Free list lưu trữ **xâm nhập (intrusive)** — mỗi slot rỗng chứa con trỏ đến slot rỗng tiếp theo. Alloc = pop, free = push.
- **Người đọc học được**: Intrusive linked list, O(1) alloc/free, zero overhead khi slot đang dùng, tại sao pool allocator lý tưởng cho object pool.

#### SlabAllocator (Linux SLAB-inspired)
```
Class 0 (8B):   [pool ████░░░░]
Class 1 (16B):  [pool ██░░░░░░]
Class 2 (32B):  [pool ████████]
Class 3 (64B):  [pool ██░░░░░░]
Class 4 (128B): [pool ░░░░░░░░]
Class 5 (256B): [pool ░░░░░░░░]
> 256B:         → backing allocator
```
- **Nguyên lý**: Kết hợp nhiều PoolAllocator với size class khác nhau (8/16/32/64/128/256). Request được route đến class nhỏ nhất phù hợp. Request > 256 bytes fall back to backing.
- **Người đọc học được**: Size-class allocation, nội bộ fragmentation vs external fragmentation, cách Linux kernel quản lý bộ nhớ nhỏ (kmalloc).
- **Kỹ thuật nâng cao**: Pointer ownership check — khi free, kiểm tra con trỏ thuộc pool nào (không chỉ dựa vào size) để tránh lỗi sau resize.

#### DebugAllocator (Diagnostics Wrapper)
```
Layout per allocation:
[ GUARD_HEAD (8B) | user data (N bytes) | GUARD_TAIL (8B) ]
         0xAB...AB                            0xAB...AB
```
- **Nguyên lý**: Wrap bất kỳ allocator nào, thêm guard bytes (canary) trước/sau mỗi allocation. Khi free, kiểm tra guard bytes — nếu bị thay đổi → buffer overflow detected. Đồng thời track mọi allocation sống để report leak.
- **Người đọc học được**: Guard byte technique (dùng trong Valgrind, AddressSanitizer), leak detection, memory profiling, benchmark methodology.

---

### 2. `lexer.zig` — Tokenizer

**Vai trò**: Biến chuỗi input thành danh sách token có nghĩa.

**Input**: `echo "hello $NAME" > out.txt && pwd`

**Output tokens**:
```
[word:"echo"] [string:"hello Zogis"] [redirect_out:">"] [word:"out.txt"] [and_and:"&&"] [word:"pwd"]
```

**Người đọc học được**:
- Cách viết lexer/scanner từ đầu
- Xử lý quote (single/double), escape sequences
- Variable expansion (`$VAR`, `${VAR}`) tại lex time
- Tilde expansion (`~` → home directory)
- Command substitution marker (`$(cmd)` → token đặc biệt)
- Glob patterns: truyền `*`/`?` nguyên bản cho executor xử lý
- Sự khác biệt giữa `word` và `string` token (quoted vs unquoted)

---

### 3. `parser.zig` — Recursive Descent Parser

**Vai trò**: Biến danh sách token thành cấu trúc dữ liệu có cấp bậc (AST).

**Grammar**:
```
input      := pipeline (( ';' | '&&' | '||' ) pipeline)*
pipeline   := command ('|' command)*
command    := WORD arg* redirect*
```

**Cấu trúc dữ liệu**:
```
ParsedInput
  └── PipelineNode[]
        ├── Pipeline
        │     └── Command[]
        │           ├── argv: [][]const u8
        │           ├── is_cmd_sub: []bool
        │           ├── is_quoted: []bool
        │           ├── redirect_in/out
        │           └── redirect_append
        └── Connector (semicolon | and_and | or_or)
```

**Người đọc học được**:
- Recursive descent parsing — kỹ thuật phổ biến nhất để parse ngôn ngữ
- Cách xây dựng AST (Abstract Syntax Tree)
- Operator precedence: `;` < `&&`/`||` < `|`
- Error handling trong parser (EmptyCommand, MissingRedirectTarget)
- Metadata tracking (is_quoted, is_cmd_sub) để hỗ trợ executor

---

### 4. `executor.zig` — Command Execution Engine

**Vai trò**: Thực thi AST — chạy lệnh, quản lý process, I/O redirect.

**Người đọc học được**:

| Khái niệm | Vị trí trong code |
|---|---|
| **Connector logic** (`&&`, `||`, `;`) | `execute()` — kiểm tra `last_exit` để quyết định |
| **Pipeline execution** | `executePipeline()` — temp file I/O giữa các lệnh |
| **Built-in dispatch** | `executeCommand()` — pattern matching tên lệnh |
| **Unified output writer** | Builtins dùng `out_w` thay vì `stdout` trực tiếp → hỗ trợ redirect và `$()` |
| **Alias expansion** | Re-lex + re-parse alias value, chạy đệ quy |
| **Command substitution** | `runCmdSub()` — chạy sub-command, capture output vào temp file |
| **Glob expansion** | `expandGlob()` + `matchGlob()` — directory iteration + wildcard matching |
| **Environment variable** | Shell-level env (`ctx.env`) vs process env |
| **External command on Windows** | Wrap Windows built-ins qua `cmd.exe /c`, temp `.bat` file để preserve quotes |
| **Process management** | `std.process.Child` — spawn, pipe stdin/stdout, wait |

---

### 5. `main.zig` — Entry Point & REPL

**Vai trò**: Khởi tạo allocator chain, chạy vòng lặp Read-Eval-Print.

**Người đọc học được**:
- Cách tổ chức allocator theo chuỗi (chain of responsibility)
- REPL pattern: đọc input → lex → parse → execute → lặp lại
- Per-command arena: mỗi lệnh dùng arena riêng, tự động giải phóng khi xong
- Colored prompt sử dụng ANSI escape codes
- Exit code display (prompt đỏ khi lệnh trước thất bại)
- Graceful shutdown: report memory leaks trước khi thoát

---

## Value Portfolio

- **Quản lý bộ nhớ** | Tại sao `malloc/free` hoạt động như vậy, fragmentation là gì, bump vs pool vs slab |
- **Systems programming** | Cách tương tác với OS: process spawn, file I/O, environment variables |
- **Compiler front-end** | Lexer → Parser → AST pipeline (áp dụng cho mọi ngôn ngữ lập trình) |
- **Ngôn ngữ Zig** | Comptime, error unions, optionals, slices, allocator interface |
- **Shell internals** | Pipe, redirect, glob, alias — những thứ bạn dùng hàng ngày nhưng ít khi biết cách hoạt động |

- **Hệ điều hành**: Sinh viên có thể mở rộng shell (thêm lệnh, thêm feature)
- **Quản lý bộ nhớ**: Mỗi allocator là một bài giảng riêng, có unit test minh họa
- **Đánh giá**: Dùng `meminfo`/`slabinfo` để sinh viên quan sát hành vi bộ nhớ runtime

- **Hiểu sâu Linux kernel**: SlabAllocator mô phỏng kmalloc/SLAB cache thực tế
- **Hiểu Zig allocator interface**: Dự án demo cách implement `std.mem.Allocator` vtable
- **So sánh**: Benchmark custom allocator vs GPA, đo throughput với lệnh `benchmark`

### Các câu hỏi nghiên cứu có thể đặt ra

1. *Tại sao SlabAllocator cần kiểm tra pointer ownership thay vì chỉ dựa vào size khi free?*
2. *Arena allocator phù hợp cho parser nhưng không phù hợp cho shell state — tại sao?*
3. *Guard bytes phát hiện buffer overflow nhưng không ngăn chặn được — giải pháp nào tốt hơn?*
4. *Pipe implementation dùng temp file thay vì OS pipe — trade-off là gì?*
5. *Tại sao Windows `find.exe` cần quotes trong command line nhưng Unix `grep` thì không?*

---

## License

Dự án phục vụ mục đích nghiên cứu và học tập.


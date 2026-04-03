# ZOGIS Shell — Bộ lệnh test toàn diện

> Chạy `zig build test` để kiểm tra unit tests, sau đó `zig build run` để mở shell và paste từng nhóm lệnh bên dưới.

---

## 0. Unit Tests (trước khi vào shell)

```powershell
PS D:\zogis> zig build test
PS D:\zogis> zig build run
```

> Không có output = tất cả tests pass (BumpAllocator, ArenaAllocator, PoolAllocator, SlabAllocator, DebugAllocator, Lexer, Parser)

---

## 1. ECHO — In chuỗi cơ bản

```bash
echo hello
echo hello world
echo one two three four five
echo
echo    spaced    out    words
echo "quoted string"
echo 'single quoted'
```

**Kỳ vọng:** In đúng nội dung, `echo` không đối số in dòng trống, quotes bị bóc ra.

---

## 2. REDIRECT `>` — Ghi đè file

```bash
echo first line > file1.txt
type file1.txt
echo second line > file1.txt
type file1.txt
echo overwritten > file1.txt
type file1.txt
```

**Kỳ vọng:** Mỗi lần `>` đều ghi đè. `type file1.txt` cuối cùng chỉ hiện `overwritten`.

---

## 3. REDIRECT `>>` — Nối thêm file

```bash
echo line1 > append_test.txt
echo line2 >> append_test.txt
echo line3 >> append_test.txt
echo line4 >> append_test.txt
echo line5 >> append_test.txt
type append_test.txt
```

**Kỳ vọng:** File chứa 5 dòng: line1, line2, line3, line4, line5.

---

## 4. REDIRECT kết hợp `>` và `>>`

```bash
echo start > mix.txt
echo middle >> mix.txt
echo reset > mix.txt
echo after_reset >> mix.txt
type mix.txt
```

**Kỳ vọng:** File chứa 2 dòng: `reset` và `after_reset` (vì `>` đã ghi đè).

---

## 5. PWD — In thư mục hiện tại

```bash
pwd
```

**Kỳ vọng:** In đường dẫn tuyệt đối của thư mục hiện tại.

---

## 6. CD — Chuyển thư mục

```bash
pwd
cd ..
pwd
cd -
pwd
```

**Kỳ vọng:** `cd ..` lên cha, `cd -` quay lại thư mục trước.

---

## 7. CD — Về HOME và quay lại

```bash
pwd
cd
pwd
cd -
pwd
```

**Kỳ vọng:** `cd` không đối số về HOME (`C:\Users\ADMIN`), `cd -` quay lại.

---

## 8. CD — Vào thư mục con

```bash
cd src
pwd
echo *.zig
cd -
pwd
```

**Kỳ vọng:** Vào `src`, liệt kê files `.zig`, quay lại.

---

## 9. TILDE `~` — Expansion

```bash
echo ~
cd ~
pwd
cd -
```

**Kỳ vọng:** `~` mở rộng thành đường dẫn HOME.

---

## 10. EXPORT — Đặt biến môi trường

```bash
export VAR1=hello
export VAR2=world
export VAR3=zogis_shell
echo $VAR1
echo $VAR2
echo $VAR3
echo $VAR1 $VAR2 $VAR3
```

**Kỳ vọng:** Mỗi biến in đúng giá trị, dòng cuối in `hello world zogis_shell`.

---

## 11. EXPORT — Ghi đè biến

```bash
export MYVAR=old_value
echo $MYVAR
export MYVAR=new_value
echo $MYVAR
```

**Kỳ vọng:** Giá trị thay đổi từ `old_value` sang `new_value`.

---

## 12. UNSET — Xóa biến

```bash
export TEMP_VAR=exists
echo $TEMP_VAR
unset TEMP_VAR
echo $TEMP_VAR
```

**Kỳ vọng:** Sau `unset`, `echo $TEMP_VAR` in dòng trống.

---

## 13. BIẾN MÔI TRƯỜNG — ${VAR} syntax

```bash
export NAME=Zogis
echo ${NAME}
echo hello_${NAME}_shell
```

**Kỳ vọng:** `${NAME}` mở rộng đúng, kể cả inline trong chuỗi.

---

## 14. EXPORT — Import từ process environment

```bash
export PATH
echo $PATH
export USERPROFILE
echo $USERPROFILE
```

**Kỳ vọng:** In giá trị PATH và USERPROFILE từ hệ thống Windows.

---

## 15. ALIAS — Tạo alias

```bash
alias greet="echo hello from alias"
alias ls="dir"
alias status="echo all systems go"
greet
status
```

**Kỳ vọng:** `greet` in `hello from alias`, `status` in `all systems go`.

---

## 16. ALIAS — Liệt kê tất cả

```bash
alias
```

**Kỳ vọng:** Liệt kê tất cả alias đã tạo theo format `alias name='value'`.

---

## 17. UNALIAS — Xóa alias

```bash
alias temp_alias="echo temporary"
temp_alias
unalias temp_alias
temp_alias
```

**Kỳ vọng:** Sau `unalias`, `temp_alias` báo "command not found".

---

## 18. ALIAS — Alias gọi lệnh thật

```bash
alias mydir="dir"
mydir
unalias mydir
```

**Kỳ vọng:** `mydir` chạy `dir` liệt kê thư mục.

---

## 19. `&&` — AND operator

```bash
echo step1 && echo step2
echo step1 && echo step2 && echo step3
echo success && echo chained && echo all_pass
```

**Kỳ vọng:** Tất cả lệnh đều chạy vì lệnh trước thành công.

---

## 20. `&&` — Dừng khi lỗi

```bash
nonexistent_cmd && echo should_not_run
```

**Kỳ vọng:** Chỉ hiện "command not found", `echo should_not_run` KHÔNG chạy.

---

## 21. `||` — OR operator

```bash
nonexistent_cmd || echo fallback_works
echo ok || echo should_not_run
```

**Kỳ vọng:** Dòng 1 in `fallback_works`, dòng 2 chỉ in `ok`.

---

## 22. `||` — Chuỗi fallback

```bash
bad_cmd1 || bad_cmd2 || echo final_fallback
```

**Kỳ vọng:** `final_fallback` được in ra.

---

## 23. `;` — Sequential execution

```bash
echo one ; echo two ; echo three
echo aaa ; echo bbb ; echo ccc ; echo ddd
```

**Kỳ vọng:** Mỗi echo chạy tuần tự, không điều kiện.

---

## 24. KẾT HỢP `&&`, `||`, `;`

```bash
echo start && echo middle ; echo end
nonexistent || echo recovered ; echo continues
echo a && echo b || echo c ; echo d
```

**Kỳ vọng:** Các toán tử hoạt động theo thứ tự trái sang phải.

---

## 25. COMMAND SUBSTITUTION `$()`

```bash
echo $(echo hello)
echo $(echo substitution works)
echo result: $(echo 42)
```

**Kỳ vọng:** `$(cmd)` được thay bằng output của cmd.

---

## 26. COMMAND SUBSTITUTION — Inline

```bash
echo prefix_$(echo middle)_suffix
echo start_$(echo INNER)_end
echo ver_$(echo 2.0)_release
```

**Kỳ vọng:** Substitution chính xác trong chuỗi.

---

## 27. COMMAND SUBSTITUTION — Với export

```bash
export CWD=$(pwd)
echo $CWD
export GREETING=$(echo hello_world)
echo $GREETING
```

**Kỳ vọng:** Biến chứa output của command substitution.

---

## 28. GLOB — Wildcard `*`

```bash
cd src
echo *.zig
echo *
cd -
```

**Kỳ vọng:** `*.zig` liệt kê tất cả file .zig, `*` liệt kê tất cả file.

---

## 29. GLOB — Wildcard `?`

```bash
cd src
echo ?????.zig
echo ????.zig
cd -
```

**Kỳ vọng:** `?????` match tên 5 ký tự (lexer), `????` match tên 4 ký tự (main).

---

## 30. PIPE `|` — Cơ bản

```bash
echo hello world | find "hello"
echo test pipe | find "pipe"
```

**Kỳ vọng:** `find` tìm đúng chuỗi trong pipe input.

---

## 31. PIPE `|` — Với file

```bash
echo alpha > pipe_input.txt
echo beta >> pipe_input.txt
echo gamma >> pipe_input.txt
type pipe_input.txt | find "beta"
type pipe_input.txt | find "gamma"
```

**Kỳ vọng:** Tìm đúng từng dòng.

---

## 32. REDIRECT `>` + PIPE

```bash
echo test_data > data.txt
type data.txt | find "test"
```

**Kỳ vọng:** `find` tìm thấy "test" trong pipe.

---

## 33. REDIRECT `<` — Stdin từ file

```bash
echo searchable content > input.txt
find "searchable" < input.txt
```

**Kỳ vọng:** `find` đọc nội dung từ file và tìm đúng.

---

## 34. BUILTIN REDIRECT — pwd, help, history vào file

```bash
pwd > pwd_output.txt
type pwd_output.txt
help > help_output.txt
type help_output.txt
history > history_output.txt
type history_output.txt
```

**Kỳ vọng:** Output của các builtin được ghi đúng vào file.

---

## 35. BUILTIN REDIRECT — echo append

```bash
echo first > builtin_append.txt
echo second >> builtin_append.txt
echo third >> builtin_append.txt
type builtin_append.txt
```

**Kỳ vọng:** File chứa 3 dòng.

---

## 36. KẾT HỢP `&&` + REDIRECT

```bash
echo part1 > combined.txt && echo part2 >> combined.txt
type combined.txt
```

**Kỳ vọng:** File chứa 2 dòng: `part1` và `part2`.

---

## 37. KẾT HỢP `&&` + REDIRECT + PIPE

```bash
echo searchme > search.txt && echo otherstuff >> search.txt
type search.txt | find "searchme"
type search.txt | find "otherstuff"
```

**Kỳ vọng:** `find` tìm thấy cả hai chuỗi.

---

## 38. KẾT HỢP `;` + REDIRECT

```bash
echo line_a > seq.txt ; echo line_b >> seq.txt ; echo line_c >> seq.txt
type seq.txt
```

**Kỳ vọng:** File chứa 3 dòng.

---

## 39. WINDOWS CMD — dir

```bash
dir
```

**Kỳ vọng:** Liệt kê thư mục hiện tại (qua cmd.exe).

---

## 40. WINDOWS CMD — type

```bash
echo content for type > type_test.txt
type type_test.txt
```

**Kỳ vọng:** Hiển thị nội dung file.

---

## 41. WINDOWS CMD — find

```bash
echo hello find test > find_test.txt
find "hello" find_test.txt
find "find" find_test.txt
find "notexist" find_test.txt
```

**Kỳ vọng:** 2 lệnh đầu tìm thấy, lệnh cuối không tìm thấy.

---

## 42. WINDOWS CMD — mkdir & rmdir

```bash
mkdir test_dir_zogis
dir
rmdir test_dir_zogis
dir
```

**Kỳ vọng:** Tạo thư mục rồi xóa.

---

## 43. EXPORT + ECHO phức tạp

```bash
export A=hello
export B=world
export C=from
export D=zogis
echo $A $B $C $D
echo ${A}_${B}_${C}_${D}
```

**Kỳ vọng:** In `hello world from zogis` và `hello_world_from_zogis`.

---

## 44. NHIỀU BIẾN TRÊN CÙNG DÒNG

```bash
export X=1 ; export Y=2 ; export Z=3
echo $X $Y $Z
unset X ; unset Y ; unset Z
echo $X $Y $Z
```

**Kỳ vọng:** In `1 2 3`, sau unset in dòng trống.

---

## 45. CD đa bước

```bash
pwd
cd ..
pwd
cd ..
pwd
cd -
pwd
cd -
pwd
```

**Kỳ vọng:** Nhảy lên 2 cấp rồi quay lại đúng.

---

## 46. ALIAS gọi ALIAS

```bash
alias say="echo"
alias hi="say hello from nested alias"
hi
unalias hi
unalias say
```

**Kỳ vọng:** `hi` in `hello from nested alias`.

---

## 47. ALIAS với redirect

```bash
alias save="echo saved_data"
save > alias_out.txt
type alias_out.txt
unalias save
```

**Kỳ vọng:** File chứa `saved_data`.

---

## 48. COMMAND SUBSTITUTION lồng trong export + echo

```bash
export MACHINE=$(echo zogis_machine)
export VERSION=$(echo v2.0)
echo $MACHINE $VERSION
echo running_$MACHINE_$VERSION
```

**Kỳ vọng:** In đúng giá trị biến từ command substitution.

---

## 49. ERROR HANDLING — Lệnh không tồn tại

```bash
this_command_does_not_exist
fakecmd123
```

**Kỳ vọng:** Hiển thị "command not found" với exit code [127].

---

## 50. EXIT CODE — Hiển thị trên prompt

```bash
nonexistent_cmd
echo $?_shown_in_prompt
echo back_to_normal
```

**Kỳ vọng:** Prompt hiện `[127]` màu đỏ sau lệnh lỗi, trở lại bình thường sau lệnh thành công.

---

## 51. MEMINFO — Báo cáo bộ nhớ

```bash
meminfo
```

**Kỳ vọng:** Hiển thị tổng allocated, freed, active, peak, alloc/free counts, overflow detected, live allocations + leak report.

---

## 52. SLABINFO — Báo cáo slab

```bash
slabinfo
```

**Kỳ vọng:** Hiển thị 6 size classes (8/16/32/64/128/256) với SlotSize, InUse, Free, Utilization%.

---

## 53. BENCHMARK — Đo throughput

```bash
benchmark
benchmark 32 1000
benchmark 64 5000
benchmark 128 10000
benchmark 256 1000
```

**Kỳ vọng:** Hiển thị elapsed ms và ops/sec cho từng kích thước.

---

## 54. PIPE nhiều tầng

```bash
echo multi pipe test > mp.txt
echo another line >> mp.txt
type mp.txt | find "pipe"
type mp.txt | find "another"
```

**Kỳ vọng:** Pipe hoạt động đúng, tìm thấy kết quả.

---

## 55. REDIRECT lỗi — File không tồn tại

```bash
type nonexistent_file.txt
find "x" < no_such_file.txt
```

**Kỳ vọng:** Hiển thị thông báo lỗi phù hợp (FileNotFound).

---

## 56. ECHO — Chuỗi rỗng và đặc biệt

```bash
echo ""
echo ''
echo hello   world
echo "hello   world"
```

**Kỳ vọng:** Quotes bóc ra, spaces trong quotes giữ nguyên.

---

## 57. STRESS — Nhiều lệnh liên tiếp

```bash
echo 1 ; echo 2 ; echo 3 ; echo 4 ; echo 5
echo a && echo b && echo c && echo d && echo e
echo x > s.txt ; echo y >> s.txt ; echo z >> s.txt ; type s.txt
```

**Kỳ vọng:** Tất cả chạy đúng, file s.txt chứa x, y, z.

---

## 58. GLOB + REDIRECT

```bash
cd src
echo *.zig > filelist.txt
cd -
type src\filelist.txt
```

**Kỳ vọng:** File chứa danh sách tất cả .zig files.

---

## 59. COMMAND SUBSTITUTION + PIPE

```bash
echo $(echo piped_value) | find "piped"
```

**Kỳ vọng:** `find` tìm thấy "piped" trong kết quả.

---

## 60. TỔNG HỢP CUỐI — Kịch bản phức tạp

```bash
export PROJECT=zogis
export VER=2.0
echo $PROJECT v$VER > info.txt
echo build: $(echo success) >> info.txt
echo platform: windows >> info.txt
type info.txt
echo --- && echo All features tested && echo ---
```

**Kỳ vọng:** File `info.txt` chứa 3 dòng thông tin project. Cuối cùng in `---`, `All features tested`, `---`.

---

## 61. HISTORY — Xem lịch sử đầy đủ

```bash
history
```

**Kỳ vọng:** Liệt kê TẤT CẢ lệnh đã gõ từ đầu, đánh số thứ tự.

---

## 62. HELP — Xem hướng dẫn

```bash
help
```

**Kỳ vọng:** Hiển thị đầy đủ danh sách lệnh, operators, expansions.

---

## 63. CLEAR — Xóa màn hình

```bash
clear
```

**Kỳ vọng:** Màn hình terminal được xóa sạch.

---

## 64. MEMORY REPORT cuối cùng

```bash
meminfo
slabinfo
```

**Kỳ vọng:** Xem trạng thái bộ nhớ sau toàn bộ session test.

---

## 65. EXIT — Thoát shell

```bash
exit
```

**Kỳ vọng:**
- In `Goodbye!`
- Hiển thị Memory Report (DebugAllocator)
- Hiển thị Slab Report (SlabAllocator)
- Trở về PowerShell

---

## Tổng kết tính để test

| # | Tính năng | Số lệnh test |
|---|---|---|
| 1 | echo cơ bản | 7 |
| 2-4 | Redirect `>` / `>>` | 18 |
| 5-9 | pwd / cd / cd - / ~ | 20 |
| 10-14 | export / unset / $VAR / ${VAR} | 18 |
| 15-18 | alias / unalias | 12 |
| 19-24 | && / \|\| / ; | 16 |
| 25-27 | Command substitution $() | 10 |
| 28-29 | Glob * / ? | 6 |
| 30-33 | Pipe \| / redirect < | 12 |
| 34-38 | Builtin redirect + combos | 16 |
| 39-42 | Windows commands (dir/type/find/mkdir) | 10 |
| 43-50 | Kết hợp phức tạp & error handling | 22 |
| 51-53 | Memory commands | 7 |
| 54-60 | Stress test & kịch bản phức tạp | 16 |
| 61-65 | history / help / clear / exit | 5 |
| | **TỔNG** | **~195 lệnh** |

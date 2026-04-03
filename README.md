# ZOGIS 

> **Trạng thái**: Version tiếp theo chưa triển khai  
> **Mục tiêu version tiếp theo**: Nâng dự án lên mức giá trị học thuật — đủ chiều sâu để trở thành một section trong bài báo nghiên cứu

---

## Bối cảnh

Phiên bản hiện tại của ZOGIS đã triển khai **5 custom allocator** (Bump, Arena, Pool, Slab, Debug) và một **mini shell hoàn chỉnh** sử dụng chúng. Tuy nhiên, dự án hiện chỉ dừng ở mức **demo hoạt động** — chưa có đánh giá định lượng nghiêm ngặt để so sánh hiệu năng thực tế giữa các chiến lược cấp phát bộ nhớ.

Để đạt giá trị học thuật, cần bổ sung một **benchmark suite** so sánh trực tiếp các allocator trên cùng một workload shell thật, với phương pháp đo lường có tính tái lập (reproducible) và phân tích kết quả mang tính khoa học.

---

## Mục tiêu phiên bản tương lai

### Viết benchmark so sánh allocator trên workload shell thật

So sánh **4 allocator** trên cùng điều kiện:

| Allocator | Đặc điểm | Kỳ vọng |
|---|---|---|
| **BumpAllocator** | O(1) alloc, không free riêng lẻ | Throughput cao nhất, nhưng tốn bộ nhớ |
| **PoolAllocator** | O(1) alloc/free, fixed-size slot | Tốt cho allocation đồng kích thước |
| **SlabAllocator** | Multi-class pool, route theo size | Cân bằng giữa tốc độ và linh hoạt |
| **GPA** (GeneralPurposeAllocator) | Zig built-in, safety checks | Baseline chính xác, overhead do safety |

### Workload đề xuất

Không dùng microbenchmark tổng hợp (alloc/free loop đơn thuần), mà chạy **chuỗi lệnh shell thực tế** để phản ánh pattern cấp phát trong thực tế:

```
# Workload 1: Lệnh đơn giản lặp lại (đo startup/teardown overhead)
echo hello world                          × 10,000 lần

# Workload 2: Pipeline phức tạp (đo multi-allocation pattern)
echo hello | find "hello"                 × 1,000 lần

# Workload 3: Command substitution (đo nested allocation)
echo $(echo $(echo deep))                 × 1,000 lần

# Workload 4: Biến + expansion (đo string allocation)
export X=value && echo $X $X $X           × 5,000 lần

# Workload 5: Mixed realistic session
Mô phỏng 1 phiên shell thực tế: cd, ls, echo, pipe, redirect, glob...
```

### Các chỉ số cần đo

| Chỉ số | Đơn vị | Ý nghĩa |
|---|---|---|
| **Throughput** | ops/sec | Số lệnh shell hoàn thành mỗi giây |
| **Total allocation count** | lần | Tổng số lần gọi alloc trong toàn bộ workload |
| **Peak memory usage** | bytes | Đỉnh bộ nhớ sử dụng tại bất kỳ thời điểm nào |
| **Total memory allocated** | bytes | Tổng cộng dồn tất cả các lần alloc |
| **Internal fragmentation** | % | Bộ nhớ cấp phát nhưng không được dùng hết |
| **Execution time** | ms | Thời gian hoàn thành toàn bộ workload |
| **Allocation latency (p50, p99)** | ns | Phân phối thời gian mỗi lần alloc |

### Hình thức kết quả mong muốn

- Bảng so sánh tổng hợp (như trên) cho mỗi workload
- Biểu đồ bar chart: throughput theo từng allocator × workload
- Biểu đồ line chart: peak memory theo thời gian trong 1 session
- Phân tích định tính: allocator nào phù hợp workload nào, tại sao

---

## Tại sao chưa triển khai

Để benchmark đạt chuẩn học thuật cần đảm bảo một số điều kiện mà hiện tại chưa sẵn sàng:

1. **Hạ tầng đo lường chính xác**: Cần high-resolution timer (`QueryPerformanceCounter` trên Windows hoặc `rdtsc`), warm-up runs, và statistical analysis (trung vị, phương sai, confidence interval) — chưa xây dựng framework đo lường này.

2. **Isolate biến số**: Benchmark phải chạy trên môi trường kiểm soát (cố định CPU frequency, tắt background process, pin thread) để kết quả có tính tái lập. Cần thiết kế test harness chuyên biệt.

3. **Instrumentation trong allocator**: Các allocator hiện tại chưa có hook đo latency per-allocation và tracking fragmentation chi tiết. Cần refactor để thêm instrumentation layer mà không ảnh hưởng đến hot path khi tắt.

4. **Visualization & reporting**: Cần tooling để xuất kết quả dạng CSV/JSON, và script vẽ biểu đồ (Python matplotlib hoặc gnuplot) để trình bày trong bài báo.

5. **Thời gian và nguồn lực**: Viết benchmark nghiêm túc, chạy đủ số lần, phân tích kết quả, viết narrative — đòi hỏi effort đáng kể vượt quá scope hiện tại.

---

## Giá trị khi hoàn thành

Khi benchmark suite được triển khai đầy đủ, dự án sẽ đạt giá trị tương đương **một section "Evaluation" trong bài báo học thuật** về systems programming:

- **Contribution rõ ràng**: So sánh thực nghiệm các chiến lược allocator trên workload thật (shell), không phải microbenchmark nhân tạo
- **Reproducible**: Mọi người có thể clone repo, chạy benchmark, và verify kết quả
- **Insight có giá trị**: Trả lời câu hỏi "Allocator nào thực sự tốt hơn cho từng loại workload?" bằng dữ liệu cụ thể
- **Platform-specific analysis**: Đánh giá trên Windows — ít được nghiên cứu hơn so với Linux trong cộng đồng systems

---

## Tham khảo hướng tiếp cận

Cần tham khảo thêm một số tài liệu và dự án để có thể triển khai


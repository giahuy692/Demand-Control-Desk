USE [POS];
SET NOCOUNT ON;
SET XACT_ABORT ON;

/* =================================================================================================
   DemandPlanningDailySource.sql

   ─────────────────────────────────────────────────────────────────────────────────────────────
   TRƯỚC KHI CHẠY — CHỈ CÓ HAI BIẾN CẦN XEM (mục 0)
   ─────────────────────────────────────────────────────────────────────────────────────────────
     @SalesDataCutoffDate   Ngày dữ liệu bán chốt của Planning Run sẽ dùng bản xuất này.
                            NULL   = KHÔNG áp cổng ngừng hoạt động 24 tháng (xuất đủ mọi Barcode
                                     bán lẻ từng có giao dịch POS).
                            <ngày> = áp cổng 24 tháng, đúng cửa sổ mà Chặng 1 sẽ dùng.
     @TestModeMaxBarcodes   NULL = FULL EXPORT (mặc định). Chỉ đặt số khi muốn chạy thử nhanh.

   Không có biến nào khác cần chỉnh cho một lần xuất production.
   ─────────────────────────────────────────────────────────────────────────────────────────────

   MỤC TIÊU
   Trả MỘT bảng duy nhất: đúng 31 cột của "DTO nguồn chuẩn" trong
   Docs/knowledge-base/Use_Case_Description_Demand_Planning_Replenishment_Governance.md,
   grain = ProductCode — Barcode — LocationCode — Date.
   Đây là dữ liệu vào của Chặng 1–13 (UC-DP-01 → UC-DP-13).

   PHẠM VI ĐỌC
   - Một cửa hàng: tbl_SYSConfiguration.Store → tbl_LSStore.Code.
   - Tối đa 5 năm, lùi từ ngày nguồn mới nhất không vượt quá ngày chạy.
   - POPULATION BẮT ĐẦU TỪ GIAO DỊCH, KHÔNG TỪ DANH MỤC (đổi 20/08/2026 theo yêu cầu trực tiếp của
     chủ sở hữu nguồn — xem mục 2 và CD-069). Chỉ ProductCode THỰC SỰ từng xuất hiện trong
     tbl_SALPoSDetails mới là ứng viên; tbl_LSProduct chỉ còn vai trò tra Barcode và thuộc tính.
     Trước đây population là TOÀN BỘ tbl_LSProduct, nên rất nhiều mã chưa từng bán một lần nào vẫn
     bị nhân với lịch 5 năm rồi mới bị loại ở downstream.
   - Loại Barcode 'H%' (combo/giỏ quà/giftset — đại diện một NHÓM sản phẩm, không phải SKU bán lẻ
     đơn lẻ; Business Requirements §1.8a, UC-DP-01 bước 4a). 'H%' đã bao trùm 'HL%'; KHÔNG thêm
     rule riêng cho 'HL%' và KHÔNG tự thêm tiền tố nào khác.

   QUY TẮC TÍNH
   - SalesQty = SUM(Qty) CHỈ trên dòng BÁN của SKU + ngày, tức HasRePosDetails = 0
     (RePosDetails IS NULL). Dòng TRẢ HÀNG bị loại hoàn toàn khỏi SalesQty (CD-029, khóa 13/08/2026).
     Đây là "lượng khách thực sự mua", KHÔNG phải Net Sales. Trả hàng không được cộng, trừ, bù trừ,
     net hay kẹp sàn vào SalesQty; nó chỉ đi vào biến động tồn ở mục 10.
   - PromoSalesQty là TẬP CON của SalesQty: cùng bộ dòng bán đó, thêm điều kiện CTKM hợp lệ.
     Bất biến: 0 <= PromoSalesQty <= SalesQty. GUARDRAIL-ALLOW (non-runtime, chú thích lệnh cấm):
     TUYỆT ĐỐI KHÔNG có RegularSalesQty và KHÔNG có công thức SalesQty = Regular + Promo — hợp
     đồng nguồn đã gỡ hẳn trường đó.
   - SalesQty không lọc TransactionType hay Discount; Price có cổng dòng bán thường riêng ở mục 8.
   - HasSalesRecord là cờ bằng chứng POS cấp CỬA HÀNG-NGÀY, tính bằng cách đối chiếu TOÀN BỘ sản
     phẩm trong tbl_SALPoSMaster + tbl_SALPoSDetails — kể cả sản phẩm đã bị loại khỏi population —
     nên nó không phụ thuộc kích thước mẫu thử hay cổng ngừng hoạt động.
   - HasSalesRecord là cờ trạng thái ngày DUY NHẤT (CD-040). Hợp đồng nguồn KHÔNG có trường
     Exposure; không có hệ số cơ hội bán, không có mốc chia buổi.
   - HasSalesRecord = 0: hai lượng bán = NULL. HasSalesRecord = 1: hai lượng bán có số, kể cả 0.
     HasSalesRecord=0 KHÔNG đồng nghĩa thiếu dữ liệu nguồn — dòng calendar vẫn phải có đủ.
   - IsPromo = 1 khi ngày đó có giao dịch mang Discount map được tới Promotion Type 2 hoặc 7 và ngày
     bán nằm trong StartDate..EndDate. Discount mất mapping hoặc ngoài phạm vi vẫn nằm nguyên trong
     Sales và được hiểu là bán thường.
   - Price = đơn giá bán thường của sản phẩm trong ngày. Chỉ dòng bán thật không có marker Discount;
     loại trả hàng và CTKM. Một SKU-day có nhiều unit price thì Price của riêng SKU-day đó = NULL và
     script in cảnh báo; KHÔNG tự bình quân/collapse và KHÔNG dừng full export. Không dùng
     AvgPrice/UnitPrice kho, không dùng StandardCost, Revenue hay NetSales.
   - OpenStock/CloseStock cộng dồn TIẾN từ toàn bộ lịch sử phát sinh kho + POS, đúng cách hệ thống
     nguồn 3PPOS tính tồn hiện tại. Không dùng mốc neo.
   - FirstReceiptDateTime chỉ lấy từ ReceiptDate của phiếu nhập nội bộ hoàn tất; không fallback
     CreateTime/LastModifiedTime; ReceiptDate rơi khác ngày hiệu lực → NULL.
   - HolidayEvent/HolidayGroup/HolidayRelation luôn NULL ở đây — tầng C# enrich tại UC-DP-24.

   RANH GIỚI
   - MỘT LẦN CHẠY = MỘT DATABASE = MỘT CỬA HÀNG (CD-028, khóa 13/08/2026). Script chỉ đọc một
     database nguồn đại diện cho một cửa hàng và chỉ phát hành đúng một LocationCode; nó đã fail-closed
     khi tbl_SYSConfiguration.Store không cho đúng một mã. KHÔNG được sửa thành đọc nhiều cửa hàng
     đồng thời để "tổng quát hóa". Nhiều cửa hàng thì chạy script này độc lập cho từng database, rồi
     hợp nhất ở Integration Layer theo khóa ProductCode — Barcode — LocationCode — Date.
   - Calendar LIÊN TỤC. Grain kết quả = MỌI Barcode CÒN TRONG POPULATION × MỌI ngày của cửa sổ nguồn.
     Ngày cửa hàng không có giao dịch nào KHÔNG biến mất khỏi kết quả, mà xuất hiện với
     HasSalesRecord = 0. Việc giảm dữ liệu đến từ giảm ĐÚNG population (mục 2, 3), tuyệt đối không
     đến từ đổi grain, bỏ ngày 0, hay rút ngắn cửa sổ 5 năm.
   - KHÔNG kết luận stockout. SQL chỉ trả bằng chứng (OpenStock/CloseStock/FirstReceiptDateTime);
     UC-DP-02 mới áp quy tắc.
   - Không ghi đè hay sửa ngược dữ liệu gốc ở bất kỳ bước nào. Không WITH (NOLOCK) — ảnh chụp nguồn
     dự báo không chấp nhận dirty read / mất dòng / nhân dòng để đổi lấy tốc độ.
   - Script KHÔNG tạo index vĩnh viễn trên bảng ERP. Mọi CREATE INDEX trong file này đều nằm trên
     bảng tạm #. Đề xuất index nguồn để ở mục 15, và chỉ là đề xuất.
   - Mọi tổng audit CTKM/tồn kho chỉ dùng nội bộ trong script, không thành cột kết quả.

   KIẾN TRÚC THỰC THI (viết lại 20/08/2026)
   Bản trước quét tbl_SALPoSDetails + tbl_SALPoSMaster NĂM lần (ngày nguồn mới nhất, seed trước cửa
   sổ, kiểm toàn vẹn, nạp cửa sổ, bằng chứng cửa hàng-ngày) và tbl_OPSImEx* BA lần. Bản này gom còn:

       1 lần quét POS ở grain NGÀY   → #PosDaily    (mục 2) — dùng cho population, ngày nguồn mới
                                                      nhất, kiểm toàn vẹn, bằng chứng cửa hàng-ngày,
                                                      seed tồn, và cổng ngừng hoạt động 24 tháng.
       1 lần quét ImEx               → #ImExSource  (mục 2) — dùng cho tồn, nhập hàng, seed.
       1 lần quét POS ở grain DÒNG   → #PosSource   (mục 7) — CHỈ cho CTKM và Price, và CHỈ trên
                                                      population đã chốt + cửa sổ đã chốt.

   Thứ tự bắt buộc: lọc population → cổng 24 tháng → RỒI MỚI nhân với calendar (mục 11.2).
   Không CROSS JOIN toàn bộ danh mục với 5 năm rồi mới phát hiện phần lớn không cần xử lý.

   HIỆU NĂNG & KỲ VỌNG THỜI GIAN CHẠY
   Đây là script XUẤT DỮ LIỆU NỀN chạy một lần, KHÔNG phải query tương tác. Số dòng kết quả bằng
   (số SKU còn population) × (số ngày trong cửa sổ nguồn). Thời gian tính bằng PHÚT là bình thường.
   Ba quy tắc giữ cho nó không chậm hơn mức cần thiết:
   1. Mọi vị từ ngày trên BẢNG NGUỒN viết dạng SARGable nửa mở — không bọc CONVERT/CAST/YEAR lên cột.
      CONVERT(date, ...) chỉ dùng ở phần CHIẾU (SELECT/GROUP BY), nơi nó không cản index.
   2. Mỗi bảng nguồn lớn chỉ quét đúng một lần cho mỗi mục đích; các phép kiểm tra toàn vẹn gộp
      chung vào lần quét đó bằng aggregate có điều kiện.
   3. Bảng tạm chỉ giữ cột thật sự được đọc phía sau, và chỉ được đánh index theo khóa join THẬT.
   ================================================================================================= */


/* =================================================================================================
   0. THAM SỐ

   Hai tham số đầu là thứ duy nhất người chạy cần xem; phần còn lại là chính sách đã khóa.
   ================================================================================================= */

/* CD-069 (20/08/2026) — NGÀY DỮ LIỆU BÁN CHỐT CỦA PLANNING RUN SẼ DÙNG BẢN XUẤT NÀY.

   Business Requirements §1.4.1 / §1.8: SalesDataCutoffDate = PlanningDate − 1 ngày, hoặc
   = LatestConfirmedCompleteDate khi nguồn chưa hoàn tất tới đó. Cả hai vế đều là khái niệm của
   PLANNING RUN, không suy được từ database nguồn — đây chính là khoảng hở hợp đồng giữa Source SQL
   và Chặng 1, nay được đóng bằng một tham số khai báo tường minh.

   NULL   = chưa ai khai báo → script KHÔNG áp cổng ngừng hoạt động 24 tháng, và nói rõ điều đó
            trong metadata. TUYỆT ĐỐI không tự thay bằng GETDATE(), @LatestAvailableSourceDate hay
            MAX(TransactionDate): ba đại lượng đó có ngữ nghĩa khác hẳn (§1.4.1b).
   <ngày> = áp cổng 24 tháng trên đúng cửa sổ [cutoff − 24 tháng + 1 ngày, cutoff] mà Chặng 1 dùng. */
DECLARE @SalesDataCutoffDate date = NULL;

/* CHẾ ĐỘ THỬ NGHIỆM — công tắc KỸ THUẬT của riêng script, KHÔNG phải quy tắc nghiệp vụ và không
   được đưa vào UC/Business Requirements.
   Mặc định NULL = FULL EXPORT; đặt NULL để chạy đầy đủ chính là trạng thái mặc định đã sẵn.
   Chỉ đặt một số dương khi cần chạy thử nhanh trên tối đa N Barcode phân biệt.
   Đường chạy production KHÔNG có TOP, không random/CHECKSUM sample, không MaximumBarcode — việc lấy
   mẫu chỉ tồn tại bên trong nhánh IF @TestModeMaxBarcodes IS NOT NULL ở mục 5.5. */
DECLARE @TestModeMaxBarcodes int = NULL;

/* CD-032 (13/08/2026) — ngày chủ sở hữu nguồn XÁC NHẬN dữ liệu đã đầy đủ tới đó. Không suy ra được
   từ database, phải do người phát hành nguồn khai báo. NULL = chưa xác nhận; hệ nhận không được tự
   thay bằng @LatestAvailableSourceDate. */
DECLARE @LatestConfirmedCompleteDate date = NULL;

/* CD-017 (11/08/2026), Business Requirements §1.8b — khoảng đánh giá ngừng hoạt động.
   Tham số chính sách CÓ PHIÊN BẢN: đổi giá trị phải duyệt lại và đánh giá lại tác động. */
DECLARE @InactivityWindowMonths int = 24;

DECLARE @LookbackYears int = 5;

/* 0 = chỉ chứng từ hoàn tất làm thay đổi tồn vật lý.
   Chỉ chuyển thành 1 nếu có chính sách riêng đã được phê duyệt. */
DECLARE @IncludeInProgressDocuments bit = 0;

DECLARE @RunDate date = CONVERT(date, SYSDATETIME());

/* TIẾN ĐỘ — dùng RAISERROR ... WITH NOWAIT, KHÔNG dùng PRINT.

   Cả file này là MỘT batch, mà PRINT chỉ được đẩy ra cửa sổ Messages khi batch KẾT THÚC. Với một
   bản xuất chạy hàng chục phút thì PRINT nghĩa là người chạy ngồi nhìn màn hình trắng, không biết
   script đang ở mục nào và cũng không biết nó còn sống hay đã treo — đúng tình huống 20/08/2026.

   Dạng RAISERROR(N'%s', 0, 1, @Msg) WITH NOWAIT: severity 0 nên KHÔNG phải lỗi, không làm dừng
   script và không ảnh hưởng kết quả; @Msg truyền như THAM SỐ nên ký tự '%' trong nội dung không bị
   hiểu nhầm thành format specifier. Mỗi khối bọc BEGIN...END để dùng được cả khi nó là thân một
   lệnh của IF/ELSE. */
DECLARE @Msg nvarchar(2000);
/* datetime2(3) chu KHONG phai datetime2(0): (0) lam tron den giay gan nhat nen @T0 co the di
   TRUOC thoi diem thuc te nua giay, va moc tien do dau tien in ra '-1s'. */
DECLARE @T0 datetime2(3) = SYSDATETIME();
DECLARE @RowCount bigint;

/* CD-040 (12/08/2026) — script KHÔNG cần #StoreOperatingEvidence. Lịch vận hành độc lập chưa bao
   giờ tồn tại ở nguồn này. Trạng thái ngày lấy từ HasSalesRecord, tính bằng đối chiếu chéo TOÀN BỘ
   POS ở mục 11.1. */

IF @TestModeMaxBarcodes IS NOT NULL AND @TestModeMaxBarcodes <= 0
BEGIN
    RAISERROR(N'@TestModeMaxBarcodes phải lớn hơn 0 hoặc bằng NULL để chạy đầy đủ.', 16, 1);
    RETURN;
END;

IF @InactivityWindowMonths <= 0
BEGIN
    RAISERROR(N'@InactivityWindowMonths phải lớn hơn 0 (Business Requirements §1.8b khóa ở 24).', 16, 1);
    RETURN;
END;

IF @SalesDataCutoffDate IS NOT NULL AND @SalesDataCutoffDate > @RunDate
BEGIN
    RAISERROR(N'@SalesDataCutoffDate nằm ở tương lai so với ngày chạy; không có dữ liệu để đánh giá cổng ngừng hoạt động.', 16, 1);
    RETURN;
END;


/* =================================================================================================
   0.1. CỬA HÀNG CỦA DATABASE NGUỒN — MỘT LẦN CHẠY = MỘT DATABASE = MỘT CỬA HÀNG (CD-028)
   ================================================================================================= */

IF OBJECT_ID(N'dbo.tbl_SYSConfiguration', N'U') IS NULL
   OR COL_LENGTH(N'dbo.tbl_SYSConfiguration', N'Store') IS NULL
BEGIN
    RAISERROR(N'Thiếu tbl_SYSConfiguration.Store; không thể xác định cửa hàng của database nguồn.', 16, 1);
    RETURN;
END;

IF OBJECT_ID(N'dbo.tbl_LSStore', N'U') IS NULL
   OR COL_LENGTH(N'dbo.tbl_LSStore', N'Code') IS NULL
   OR COL_LENGTH(N'dbo.tbl_LSStore', N'Store') IS NULL
BEGIN
    RAISERROR(N'Thiếu tbl_LSStore.Code hoặc tbl_LSStore.Store; không thể tra tên cửa hàng.', 16, 1);
    RETURN;
END;

IF (SELECT COUNT(DISTINCT Config.Store) FROM dbo.tbl_SYSConfiguration AS Config WHERE Config.Store IS NOT NULL) <> 1
BEGIN
    RAISERROR(N'tbl_SYSConfiguration.Store không cho đúng một mã cửa hàng — không tự chọn, cần đối soát cấu hình.', 16, 1);
    RETURN;
END;

DECLARE @StoreCode int;
DECLARE @StoreName nvarchar(500);

SELECT TOP (1) @StoreCode = Config.Store
FROM dbo.tbl_SYSConfiguration AS Config
WHERE Config.Store IS NOT NULL;

SELECT @StoreName = Store.Store
FROM dbo.tbl_LSStore AS Store
WHERE Store.Code = @StoreCode;

IF @StoreName IS NULL
BEGIN
    RAISERROR(N'Mã cửa hàng từ tbl_SYSConfiguration.Store không khớp bản ghi nào trong tbl_LSStore.Code.', 16, 1);
    RETURN;
END;

/* Nguồn DUY NHẤT cho LocationCode/LocationName, dựng bằng JOIN thật trên bảng (không gán từ biến
   @StoreName) đúng như DTO nguồn chuẩn mô tả. @StoreCode/@StoreName ở trên chỉ để RAISERROR sớm khi
   cấu hình cửa hàng sai; kiểm tra đó cũng bảo đảm JOIN này không nhân dòng.
   Cả hai cột cùng lấy tbl_LSStore.Store — đúng nguyên văn hợp đồng nguồn đã khóa. */
IF OBJECT_ID('tempdb..#StoreIdentity') IS NOT NULL DROP TABLE #StoreIdentity;

CREATE TABLE #StoreIdentity
(
    LocationCode nvarchar(500) NOT NULL,
    LocationName nvarchar(500) NOT NULL
);

INSERT INTO #StoreIdentity (LocationCode, LocationName)
SELECT TOP (1) Store.Store, Store.Store
FROM dbo.tbl_SYSConfiguration AS Config
INNER JOIN dbo.tbl_LSStore AS Store
    ON Store.Code = Config.Store
WHERE Config.Store IS NOT NULL;


/* Dọn temp để query có thể chạy lại trong cùng session. */
IF OBJECT_ID('tempdb..#BrandName') IS NOT NULL DROP TABLE #BrandName;
IF OBJECT_ID('tempdb..#ProductGroupMap') IS NOT NULL DROP TABLE #ProductGroupMap;
IF OBJECT_ID('tempdb..#GroupHierarchy5') IS NOT NULL DROP TABLE #GroupHierarchy5;
IF OBJECT_ID('tempdb..#PosDaily') IS NOT NULL DROP TABLE #PosDaily;
IF OBJECT_ID('tempdb..#PosActivityDay') IS NOT NULL DROP TABLE #PosActivityDay;
IF OBJECT_ID('tempdb..#ImExSource') IS NOT NULL DROP TABLE #ImExSource;
IF OBJECT_ID('tempdb..#RetailCandidate') IS NOT NULL DROP TABLE #RetailCandidate;
IF OBJECT_ID('tempdb..#InactivityEvidence') IS NOT NULL DROP TABLE #InactivityEvidence;
IF OBJECT_ID('tempdb..#TargetProducts') IS NOT NULL DROP TABLE #TargetProducts;
IF OBJECT_ID('tempdb..#StockSeedMovement') IS NOT NULL DROP TABLE #StockSeedMovement;
IF OBJECT_ID('tempdb..#PosSource') IS NOT NULL DROP TABLE #PosSource;
IF OBJECT_ID('tempdb..#DailySales') IS NOT NULL DROP TABLE #DailySales;
IF OBJECT_ID('tempdb..#DailyPrice') IS NOT NULL DROP TABLE #DailyPrice;
IF OBJECT_ID('tempdb..#PriceConflict') IS NOT NULL DROP TABLE #PriceConflict;
IF OBJECT_ID('tempdb..#RegularPriceLine') IS NOT NULL DROP TABLE #RegularPriceLine;
IF OBJECT_ID('tempdb..#DiscountResolution') IS NOT NULL DROP TABLE #DiscountResolution;
IF OBJECT_ID('tempdb..#DailyPromo') IS NOT NULL DROP TABLE #DailyPromo;
IF OBJECT_ID('tempdb..#DailyMovement') IS NOT NULL DROP TABLE #DailyMovement;
IF OBJECT_ID('tempdb..#StoreActivity') IS NOT NULL DROP TABLE #StoreActivity;
IF OBJECT_ID('tempdb..#StockDaily') IS NOT NULL DROP TABLE #StockDaily;
IF OBJECT_ID('tempdb..#FirstReceipt') IS NOT NULL DROP TABLE #FirstReceipt;
IF OBJECT_ID('tempdb..#FinalResult') IS NOT NULL DROP TABLE #FinalResult;


/* =================================================================================================
   1. DANH MỤC — CÂY NHÓM 5 CẤP VÀ TÊN THƯƠNG HIỆU

   Toàn bộ mục này chỉ đọc bảng DANH MỤC, không đụng bảng giao dịch. Nó chạy trước vì mục 3 cần tra
   Barcode ngay khi biết ProductCode nào thực sự có giao dịch.
   ================================================================================================= */

IF OBJECT_ID(N'dbo.tbl_LSProduct', N'U') IS NULL
   OR COL_LENGTH(N'dbo.tbl_LSProduct', N'Code') IS NULL
   OR COL_LENGTH(N'dbo.tbl_LSProduct', N'GroupID') IS NULL
   OR COL_LENGTH(N'dbo.tbl_LSProduct', N'Barcode') IS NULL
BEGIN
    RAISERROR(N'Thiếu tbl_LSProduct.Code / GroupID / Barcode.', 16, 1);
    RETURN;
END;

IF OBJECT_ID(N'dbo.tbl_LSGroup', N'U') IS NULL
   OR COL_LENGTH(N'dbo.tbl_LSGroup', N'Code') IS NULL
   OR COL_LENGTH(N'dbo.tbl_LSGroup', N'GroupID') IS NULL
   OR COL_LENGTH(N'dbo.tbl_LSGroup', N'GroupName') IS NULL
   OR COL_LENGTH(N'dbo.tbl_LSGroup', N'ParentID') IS NULL
BEGIN
    RAISERROR(N'Thiếu schema tbl_LSGroup cần thiết; không thể xác định cây nhóm.', 16, 1);
    RETURN;
END;

IF OBJECT_ID(N'dbo.tbl_SALPoSDetails', N'U') IS NULL
   OR COL_LENGTH(N'dbo.tbl_SALPoSDetails', N'Product') IS NULL
   OR COL_LENGTH(N'dbo.tbl_SALPoSDetails', N'PoSMaster') IS NULL
   OR COL_LENGTH(N'dbo.tbl_SALPoSDetails', N'Qty') IS NULL
   OR COL_LENGTH(N'dbo.tbl_SALPoSDetails', N'Amount') IS NULL
   OR COL_LENGTH(N'dbo.tbl_SALPoSDetails', N'RePosDetails') IS NULL
   OR COL_LENGTH(N'dbo.tbl_SALPoSDetails', N'Discount') IS NULL
BEGIN
    RAISERROR(N'Thiếu cột bắt buộc của tbl_SALPoSDetails (Product/PoSMaster/Qty/Amount/RePosDetails/Discount).', 16, 1);
    RETURN;
END;

IF OBJECT_ID(N'dbo.tbl_SALPoSMaster', N'U') IS NULL
   OR COL_LENGTH(N'dbo.tbl_SALPoSMaster', N'Code') IS NULL
   OR COL_LENGTH(N'dbo.tbl_SALPoSMaster', N'TransactionDate') IS NULL
BEGIN
    RAISERROR(N'Thiếu tbl_SALPoSMaster.Code hoặc tbl_SALPoSMaster.TransactionDate.', 16, 1);
    RETURN;
END;

/* 1.5. TÊN THƯƠNG HIỆU — DÒ TÊN CỘT LÚC CHẠY, KHÔNG ĐOÁN

   FK `tbl_LSProduct.Brand → tbl_LSBrand.Code` đã có tài liệu xác nhận, nhưng tên cột chứa TÊN
   thương hiệu thì chưa. Các bảng danh mục trong DB này không theo một quy ước nào: tbl_LSGroup dùng
   `GroupName`, tbl_LSStore lại dùng `Store`. Đoán bừa chính là cách đã sai với "TransactionType = 2".

   Vì SQL tĩnh không thể tham chiếu một cột chưa chắc tồn tại (lỗi ngay lúc biên dịch), khối này dò
   bằng COL_LENGTH rồi nạp #BrandName bằng một câu động DUY NHẤT. Phạm vi động chỉ gói trong bảng
   danh mục vài trăm dòng — query chính vẫn tĩnh hoàn toàn.

   Không tìm thấy cột nào → BrandName để trống toàn bộ và IN cảnh báo, KHÔNG dừng script: BrandName
   chỉ phục vụ hiển thị, không nên chặn cả lần xuất dữ liệu vì nó. */

CREATE TABLE #BrandName
(
    BrandCode nvarchar(100) NOT NULL PRIMARY KEY,
    BrandName nvarchar(500) NULL
);

IF OBJECT_ID(N'dbo.tbl_LSBrand', N'U') IS NOT NULL
   AND COL_LENGTH(N'dbo.tbl_LSBrand', N'Code') IS NOT NULL
BEGIN
    DECLARE @BrandNameColumn sysname =
        COALESCE
        (
            CASE WHEN COL_LENGTH(N'dbo.tbl_LSBrand', N'BrandName') IS NOT NULL THEN N'BrandName' END,
            CASE WHEN COL_LENGTH(N'dbo.tbl_LSBrand', N'Brand')     IS NOT NULL THEN N'Brand'     END,
            CASE WHEN COL_LENGTH(N'dbo.tbl_LSBrand', N'VName')     IS NOT NULL THEN N'VName'     END,
            CASE WHEN COL_LENGTH(N'dbo.tbl_LSBrand', N'Name')      IS NOT NULL THEN N'Name'      END
        );

    IF @BrandNameColumn IS NULL
        BEGIN
            SET @Msg = N'CẢNH BÁO: không tìm thấy cột tên trong tbl_LSBrand (đã thử BrandName/Brand/VName/Name). BrandName sẽ để trống — chạy mục phụ lục cuối file để xem tên cột thật rồi bổ sung vào danh sách trên.';
            RAISERROR(N'%s', 0, 1, @Msg) WITH NOWAIT;
        END;
    ELSE
    BEGIN
        /* GROUP BY chứ không SELECT thẳng: chưa xác nhận tbl_LSBrand.Code là khóa duy nhất, mà
           #BrandName lại có PRIMARY KEY trên cột đó. Trùng mã sẽ làm vỡ cả script vì một bảng danh
           mục — không đáng. Trùng thì lấy một tên bất kỳ và vẫn chạy tiếp. */
        DECLARE @BrandSql nvarchar(max) =
            N'INSERT INTO #BrandName (BrandCode, BrandName)
              SELECT CONVERT(nvarchar(100), B.Code), MAX(CONVERT(nvarchar(500), B.' + QUOTENAME(@BrandNameColumn) + N'))
              FROM dbo.tbl_LSBrand AS B
              WHERE B.Code IS NOT NULL
              GROUP BY CONVERT(nvarchar(100), B.Code);';
        EXEC sys.sp_executesql @BrandSql;

        BEGIN
            SET @Msg = N'BrandName lấy từ tbl_LSBrand.' + @BrandNameColumn;
            RAISERROR(N'%s', 0, 1, @Msg) WITH NOWAIT;
        END;
    END;
END
ELSE
    BEGIN
        SET @Msg = N'CẢNH BÁO: không có tbl_LSBrand hoặc thiếu cột Code. BrandName sẽ để trống.';
        RAISERROR(N'%s', 0, 1, @Msg) WITH NOWAIT;
    END;


CREATE TABLE #ProductGroupMap
(
    ProductCode int NOT NULL PRIMARY KEY,
    AssignedGroupCode nvarchar(100) NULL
);

INSERT INTO #ProductGroupMap (ProductCode, AssignedGroupCode)
SELECT
    CONVERT(int, Product.Code),
    CONVERT(nvarchar(100), Product.GroupID)
FROM dbo.tbl_LSProduct AS Product
WHERE Product.Code IS NOT NULL;

CREATE TABLE #GroupHierarchy5
(
    AssignedGroupCode nvarchar(100) NOT NULL PRIMARY KEY,
    GroupID nvarchar(100) NULL,
    GroupName nvarchar(500) NULL,
    GroupID1 nvarchar(100) NULL,
    GroupName1 nvarchar(500) NULL,
    GroupID2 nvarchar(100) NULL,
    GroupName2 nvarchar(500) NULL,
    GroupID3 nvarchar(100) NULL,
    GroupName3 nvarchar(500) NULL,
    GroupID4 nvarchar(100) NULL,
    GroupName4 nvarchar(500) NULL
);

;WITH GroupAncestors AS
(
    SELECT
        CONVERT(nvarchar(100), GroupRow.Code) AS AssignedGroupCode,
        GroupRow.Code AS AncestorCode,
        GroupRow.ParentID,
        CONVERT(nvarchar(100), GroupRow.GroupID) AS BusinessGroupID,
        CONVERT(nvarchar(500), GroupRow.GroupName) AS BusinessGroupName,
        CONVERT(int, 0) AS DepthFromAssigned,
        CONVERT(nvarchar(max), N'/' + CONVERT(nvarchar(100), GroupRow.Code) + N'/') AS TraversedCodes
    FROM dbo.tbl_LSGroup AS GroupRow
    WHERE GroupRow.Code IS NOT NULL

    UNION ALL

    SELECT
        Ancestor.AssignedGroupCode,
        ParentGroup.Code,
        ParentGroup.ParentID,
        CONVERT(nvarchar(100), ParentGroup.GroupID),
        CONVERT(nvarchar(500), ParentGroup.GroupName),
        Ancestor.DepthFromAssigned + 1,
        CONVERT
        (
            nvarchar(max),
            Ancestor.TraversedCodes + CONVERT(nvarchar(100), ParentGroup.Code) + N'/'
        )
    FROM GroupAncestors AS Ancestor
    INNER JOIN dbo.tbl_LSGroup AS ParentGroup
        ON ParentGroup.Code = Ancestor.ParentID
    WHERE Ancestor.DepthFromAssigned < 4
      AND CHARINDEX
          (
              N'/' + CONVERT(nvarchar(100), ParentGroup.Code) + N'/',
              Ancestor.TraversedCodes
          ) = 0
),
NumberedPath AS
(
    SELECT
        AssignedGroupCode,
        BusinessGroupID,
        BusinessGroupName,
        ROW_NUMBER() OVER
        (
            PARTITION BY AssignedGroupCode
            ORDER BY DepthFromAssigned DESC
        ) AS PathLevel
    FROM GroupAncestors
)
INSERT INTO #GroupHierarchy5
(
    AssignedGroupCode,
    GroupID, GroupName,
    GroupID1, GroupName1,
    GroupID2, GroupName2,
    GroupID3, GroupName3,
    GroupID4, GroupName4
)
SELECT
    AssignedGroupCode,
    MAX(CASE WHEN PathLevel = 1 THEN BusinessGroupID END),
    MAX(CASE WHEN PathLevel = 1 THEN BusinessGroupName END),
    MAX(CASE WHEN PathLevel = 2 THEN BusinessGroupID END),
    MAX(CASE WHEN PathLevel = 2 THEN BusinessGroupName END),
    MAX(CASE WHEN PathLevel = 3 THEN BusinessGroupID END),
    MAX(CASE WHEN PathLevel = 3 THEN BusinessGroupName END),
    MAX(CASE WHEN PathLevel = 4 THEN BusinessGroupID END),
    MAX(CASE WHEN PathLevel = 4 THEN BusinessGroupName END),
    MAX(CASE WHEN PathLevel = 5 THEN BusinessGroupID END),
    MAX(CASE WHEN PathLevel = 5 THEN BusinessGroupName END)
FROM NumberedPath
GROUP BY AssignedGroupCode
OPTION (MAXRECURSION 100);


/* =================================================================================================
   2. MỘT LẦN QUÉT POS Ở GRAIN NGÀY — #PosDaily

   Đây là lần quét tbl_SALPoSDetails + tbl_SALPoSMaster DUY NHẤT ở grain ngày, và nó phục vụ SÁU
   mục đích khác nhau. Trước đây sáu mục đích đó là sáu lần quét riêng.

     (a) POPULATION      — DISTINCT ProductCode thực sự có trong tbl_SALPoSDetails (mục 3).
     (b) NGÀY NGUỒN      — MAX(BusinessDate) → @LatestAvailableSourceDate (mục 4).
     (c) TOÀN VẸN        — dòng không join được master / thiếu TransactionDate / Qty NULL.
     (d) BẰNG CHỨNG NGÀY — DISTINCT BusinessDate cấp CỬA HÀNG cho HasSalesRecord (mục 11.1).
     (e) SEED TỒN        — tổng biến động POS trước cửa sổ (mục 6).
     (f) CỔNG 24 THÁNG   — bằng chứng bán dương và biến động tồn trong khoảng đánh giá (mục 5).

   KHÔNG lọc theo sản phẩm ở đây. (d) bắt buộc phải nhìn TOÀN BỘ sản phẩm — kể cả Barcode 'H%' và
   sản phẩm không có trong danh mục — vì "cửa hàng có mở hay không" là kết luận cấp cửa hàng, không
   phải cấp SKU (CD-042). Lọc sớm ở đây sẽ khai báo sai ngày mở thành ngày nghỉ.

   LEFT JOIN (không phải INNER) là bắt buộc: dòng orphan chính là dòng KHÔNG join được master. Dùng
   INNER JOIN thì chúng biến mất khỏi chính phép kiểm tra đi tìm chúng. Dòng orphan hoặc thiếu ngày
   rơi vào nhóm BusinessDate IS NULL và được đối chiếu ở mục 3.2.

   KHÔNG có vị từ ngày ở đây: seed tồn cần TOÀN BỘ lịch sử phát sinh, không chỉ 5 năm.
   ================================================================================================= */

CREATE TABLE #PosDaily
(
    ProductCode int NOT NULL,
    BusinessDate date NULL,                 -- NULL = dòng orphan hoặc thiếu TransactionDate
    SaleQtySum decimal(38, 6) NULL,         -- SUM(Qty) của dòng BÁN  (RePosDetails IS NULL)
    ReturnQtySum decimal(38, 6) NULL,       -- SUM(Qty) của dòng TRẢ  (RePosDetails IS NOT NULL)
    LineCount bigint NOT NULL,
    HasNullQty bit NOT NULL                 -- 1 = có ít nhất một dòng Qty NULL trong nhóm
);

INSERT INTO #PosDaily (ProductCode, BusinessDate, SaleQtySum, ReturnQtySum, LineCount, HasNullQty)
SELECT
    Detail.Product,
    CONVERT(date, Master.TransactionDate),  -- CONVERT ở phần chiếu: không cản index
    SUM(CASE WHEN Detail.RePosDetails IS NULL     THEN CONVERT(decimal(38, 6), Detail.Qty) ELSE 0 END),
    SUM(CASE WHEN Detail.RePosDetails IS NOT NULL THEN CONVERT(decimal(38, 6), Detail.Qty) ELSE 0 END),
    COUNT_BIG(*),
    /* Qty NULL bị SUM bỏ qua, nên nó sẽ âm thầm thành 0 nếu không gắn cờ. Cờ này là thứ giữ cho
       "không biết" khác hẳn "bằng 0": trong cửa sổ xuất thì fail-closed (mục 4), trước cửa sổ thì
       làm seed tồn trở thành NULL (mục 6). */
    CONVERT(bit, MAX(CASE WHEN Detail.Qty IS NULL THEN 1 ELSE 0 END))
FROM dbo.tbl_SALPoSDetails AS Detail
LEFT JOIN dbo.tbl_SALPoSMaster AS Master
    ON Master.Code = Detail.PoSMaster
WHERE Detail.Product IS NOT NULL
GROUP BY Detail.Product, CONVERT(date, Master.TransactionDate)
OPTION (RECOMPILE);

CREATE CLUSTERED INDEX IX_PosDaily_Product_Date
    ON #PosDaily (ProductCode, BusinessDate);

SELECT @RowCount = COUNT_BIG(*) FROM #PosDaily;
BEGIN
    SET @Msg = N'TIEN DO ' + CONVERT(nvarchar(8), DATEDIFF(second, @T0, SYSDATETIME()))
        + N's | mục 2 #PosDaily xong — ' + CONVERT(nvarchar(30), @RowCount) + N' dòng (sản phẩm × ngày, toàn bộ lịch sử)';
    RAISERROR(N'%s', 0, 1, @Msg) WITH NOWAIT;
END;

/* Bằng chứng POS cấp CỬA HÀNG-NGÀY, tách ra NGAY BÂY GIỜ — trước mọi phép lọc sản phẩm. Sau mục 3
   thì #PosDaily đã bị thu hẹp về population, không còn dùng cho mục đích (d) được nữa.
   Không lọc dòng trả: ngày khách đến trả là ngày cửa hàng CÓ mở (CD-042). */
CREATE TABLE #PosActivityDay
(
    BusinessDate date NOT NULL PRIMARY KEY
);

INSERT INTO #PosActivityDay (BusinessDate)
SELECT DISTINCT BusinessDate
FROM #PosDaily
WHERE BusinessDate IS NOT NULL;


/* =================================================================================================
   2.5. MỘT LẦN QUÉT IMEX — #ImExSource

   Cũng phủ TOÀN BỘ lịch sử (không chỉ cửa sổ 5 năm), vì seed tồn cộng dồn tiến cần mọi phát sinh
   trước cửa sổ. Ba mục đích: seed (mục 6), biến động tồn theo ngày (mục 10), phiếu nhập đầu tiên
   trong ngày (mục 13), cộng thêm bằng chứng nhập hàng cho cổng 24 tháng (mục 5).

   Cùng thủ pháp LEFT JOIN như mục 2: chứng từ không join được master, hoặc thiếu EffDate, rơi vào
   BusinessDate IS NULL để mục 3.2 bắt được.

   DocumentType/DocumentStatus KHÔNG lưu vào bảng tạm: chúng chỉ dùng để quyết định dấu của
   InventoryNetQty và cờ IsInternalReceipt ngay trong lệnh INSERT dưới đây.
   ================================================================================================= */

CREATE TABLE #ImExSource
(
    DocumentCode int NULL,
    ProductCode int NOT NULL,
    BusinessDate date NULL,                 -- NULL = orphan hoặc thiếu EffDate
    InventoryNetQty decimal(38, 6) NULL,    -- đã mang dấu: + nhập, − xuất
    IsInternalReceipt bit NOT NULL,         -- 1 = phiếu nhập nội bộ hoàn tất (DocumentType 1, Status 3)
    RawReceiptDate datetime2(0) NULL,
    ReceiptCandidateDateTime datetime2(0) NULL
);

INSERT INTO #ImExSource
(
    DocumentCode, ProductCode, BusinessDate,
    InventoryNetQty, IsInternalReceipt, RawReceiptDate, ReceiptCandidateDateTime
)
SELECT
    Master.Code,
    Detail.Product,
    CONVERT(date, Master.EffDate),
    CONVERT
    (
        decimal(38, 6),
        CASE
            WHEN Master.DocumentType IN (1, 2, 3, 4, 21, 31, 41, 50)
             AND Master.DocumentStatus = 3
                THEN Detail.QtyReceived
            WHEN @IncludeInProgressDocuments = 1
             AND Master.DocumentType IN (1, 2, 3, 4, 21, 31, 41, 50)
             AND Master.DocumentStatus = 2
                THEN Detail.Quantity
            WHEN Master.DocumentType IN (5, 6, 7, 8, 9, 10, 20, 30, 40, 52)
             AND Master.DocumentStatus = 6
                THEN -Detail.QtyReceived
            WHEN @IncludeInProgressDocuments = 1
             AND Master.DocumentType IN (5, 6, 7, 8, 9, 20, 30, 40, 52)
             AND Master.DocumentStatus = 5
                THEN -Detail.QtyReceived
            ELSE 0
        END
    ),
    CONVERT(bit, CASE WHEN Master.DocumentType = 1 AND Master.DocumentStatus = 3 THEN 1 ELSE 0 END),
    CONVERT(datetime2(0), Master.ReceiptDate),
    /* CD-015 — phiếu chỉ ghi ngày được đọc là 00:00:00, đó là MỐC THẬT. Điều kiện
       `CONVERT(time(0), ReceiptDate) <> '00:00:00'` đã bị bỏ ở đây: giữ nó lại thì candidate ra NULL
       ngay từ đầu và mọi xử lý phía sau không còn gì để đọc. Chỉ hai trường hợp thật sự không dùng
       được: ReceiptDate NULL, hoặc ReceiptDate rơi vào ngày khác ngày hiệu lực. */
    CASE
        WHEN Master.DocumentType = 1
         AND Master.DocumentStatus = 3
         AND Master.ReceiptDate IS NOT NULL
         AND CONVERT(date, Master.ReceiptDate) = CONVERT(date, Master.EffDate)
            THEN CONVERT(datetime2(0), Master.ReceiptDate)
    END
FROM dbo.tbl_OPSImExDetails AS Detail
LEFT JOIN dbo.tbl_OPSImExMaster AS Master
    ON Master.Code = Detail.DocumentNo
WHERE Detail.Product IS NOT NULL
  AND
  (
      Master.Code IS NULL              -- orphan: giữ lại để mục 3.2 bắt được
      OR Master.EffDate IS NULL        -- thiếu ngày hiệu lực: cùng nhóm orphan
      OR (Master.DocumentType IN (1, 2, 3, 4, 21, 31, 41, 50) AND Master.DocumentStatus IN (2, 3))
      OR (Master.DocumentType IN (5, 6, 7, 8, 9, 10, 20, 30, 40, 52) AND Master.DocumentStatus IN (5, 6))
  )
OPTION (RECOMPILE);

CREATE CLUSTERED INDEX IX_ImExSource_Product_Date_Document
    ON #ImExSource (ProductCode, BusinessDate, DocumentCode);

SELECT @RowCount = COUNT_BIG(*) FROM #ImExSource;
BEGIN
    SET @Msg = N'TIEN DO ' + CONVERT(nvarchar(8), DATEDIFF(second, @T0, SYSDATETIME()))
        + N's | mục 2.5 #ImExSource xong — ' + CONVERT(nvarchar(30), @RowCount) + N' dòng';
    RAISERROR(N'%s', 0, 1, @Msg) WITH NOWAIT;
END;


/* =================================================================================================
   3. POPULATION BẮT ĐẦU TỪ GIAO DỊCH, KHÔNG TỪ DANH MỤC

   ĐỔI 20/08/2026 theo yêu cầu trực tiếp của chủ sở hữu nguồn (CD-069).

     TRƯỚC:  population = TOÀN BỘ tbl_LSProduct có Barcode hợp lệ.
     NAY:    population = DISTINCT tbl_SALPoSDetails.Product, sau đó JOIN tbl_LSProduct.Code để lấy
             Barcode và thuộc tính.

   Sản phẩm chỉ tồn tại trong danh mục mà CHƯA TỪNG có một dòng POS nào thì không phải ứng viên: nó
   không có lịch sử bán để học, và nhân nó với 5 năm lịch chỉ tạo ra hàng triệu dòng 0 → 0 mà Chặng 1
   sẽ loại ngay. Đây là thay đổi RANH GIỚI so với Business Requirements §1.8a (vốn nói population là
   Barcode bán lẻ hợp lệ, không nói gì về việc từng có giao dịch) — xem CD-069 để biết mâu thuẫn và
   cách diễn giải đã triển khai.

   #PosDaily ở mục 2 đã có sẵn DISTINCT ProductCode nên bước này KHÔNG quét lại bảng nguồn.

   Ba số audit của Business Requirements §1.8a (trước tiền tố / bị loại / còn lại) vẫn được đếm đủ,
   nhưng nay đếm trên đúng tập ứng viên POS chứ không trên toàn danh mục — số của hai bản không so
   trực tiếp được với nhau, và metadata ở mục 14 ghi rõ cả hai đơn vị (ProductCode và Barcode).
   ================================================================================================= */

DECLARE @ProductsInSalPosDetails int;
DECLARE @ProductsNotInProductMaster int;
DECLARE @ProductsWithMissingBarcode int;
DECLARE @SourceBarcodeBeforePrefix int;
DECLARE @HPrefixExcluded int;
DECLARE @HPrefixExcludedProductCount int;
DECLARE @RetailCandidateProductCount int;
DECLARE @RetailBarcodeBeforeTest int;
DECLARE @FinalExportProductCount int;
DECLARE @ExportBarcodeCount int;
DECLARE @BarcodeSharedByMultipleProductCode int;

CREATE TABLE #RetailCandidate
(
    ProductCode int NOT NULL PRIMARY KEY,
    Barcode nvarchar(100) NOT NULL
);

/* Một bảng trung gian nhỏ (một dòng cho mỗi ProductCode có giao dịch) mang đủ mọi cờ cần cho cả các
   số audit lẫn tập ứng viên, để chỉ phải đọc tbl_LSProduct đúng một lần.
   `Product` là bí danh của tbl_LSProduct — giữ nguyên tên này, guardrail hợp đồng nguồn soi đúng
   chuỗi `Product.Barcode NOT LIKE N'H%'`. */
IF OBJECT_ID('tempdb..#PosProductAudit') IS NOT NULL DROP TABLE #PosProductAudit;

CREATE TABLE #PosProductAudit
(
    ProductCode int NOT NULL PRIMARY KEY,
    Barcode nvarchar(100) NULL,
    MissingFromMaster bit NOT NULL,
    MissingBarcode bit NOT NULL,
    HasHPrefix bit NOT NULL
);

INSERT INTO #PosProductAudit (ProductCode, Barcode, MissingFromMaster, MissingBarcode, HasHPrefix)
SELECT
    Pos.ProductCode,
    CONVERT(nvarchar(100), Product.Barcode),
    CONVERT(bit, CASE WHEN Product.Code IS NULL THEN 1 ELSE 0 END),
    CONVERT(bit, CASE
        WHEN Product.Barcode IS NULL
          OR LTRIM(RTRIM(CONVERT(nvarchar(100), Product.Barcode))) = N''
        THEN 1 ELSE 0 END),
    CONVERT(bit, CASE
        WHEN Product.Barcode IS NOT NULL AND Product.Barcode NOT LIKE N'H%' THEN 0
        WHEN Product.Barcode IS NULL THEN 0
        ELSE 1 END)
FROM (SELECT DISTINCT ProductCode FROM #PosDaily) AS Pos
LEFT JOIN dbo.tbl_LSProduct AS Product
    ON Product.Code = Pos.ProductCode;

INSERT INTO #RetailCandidate (ProductCode, Barcode)
SELECT ProductCode, Barcode
FROM #PosProductAudit
WHERE MissingFromMaster = 0
  AND MissingBarcode = 0
  AND HasHPrefix = 0;

/* Bốn số audit population + ba số của Business Requirements §1.8a, đếm trên ĐÚNG tập ứng viên POS
   (không phải toàn danh mục). Một lần đọc bảng nhỏ, không quét lại bảng nguồn. */
SELECT
    @ProductsInSalPosDetails    = COUNT(*),
    @ProductsNotInProductMaster = SUM(CASE WHEN MissingFromMaster = 1 THEN 1 ELSE 0 END),
    @ProductsWithMissingBarcode = SUM(CASE WHEN MissingFromMaster = 0 AND MissingBarcode = 1 THEN 1 ELSE 0 END),
    @SourceBarcodeBeforePrefix  = COUNT(DISTINCT CASE WHEN MissingBarcode = 0 THEN Barcode END),
    @HPrefixExcluded            = COUNT(DISTINCT CASE WHEN HasHPrefix = 1 THEN Barcode END),
    @HPrefixExcludedProductCount = SUM(CASE WHEN HasHPrefix = 1 THEN 1 ELSE 0 END)
FROM #PosProductAudit;

SELECT @RetailCandidateProductCount = COUNT(*) FROM #RetailCandidate;

IF @RetailCandidateProductCount = 0
BEGIN
    RAISERROR(N'Không còn ProductCode nào sau khi lấy population từ tbl_SALPoSDetails và loại Barcode rỗng/combo ''H%''.', 16, 1);
    RETURN;
END;

BEGIN
    SET @Msg = N'Population: ' + CONVERT(nvarchar(20), @ProductsInSalPosDetails)
        + N' ProductCode có trong tbl_SALPoSDetails → '
        + CONVERT(nvarchar(20), @RetailCandidateProductCount) + N' ứng viên bán lẻ sau rule tiền tố.';
    RAISERROR(N'%s', 0, 1, @Msg) WITH NOWAIT;
END;

/* -------------------------------------------------------------------------------------------------
   3.1b. ĐO ĐÚNG CÁI GIÁ CỦA RULE POPULATION MỚI — KHÔNG ĐỂ NÓ VÔ HÌNH

   Rule "chỉ sản phẩm từng có trong tbl_SALPoSDetails" MÂU THUẪN với Business Requirements §1.8b ở
   đúng một chỗ, và chỗ đó có thật:

       §1.8b nói một Barcode CHỈ bị loại khi VẮNG CẢ BỐN bằng chứng, trong đó có
       "có ngày OpenStock/CloseStock > 0" và "có FirstReceiptDateTime". Một SKU vừa nhập về kho,
       còn tồn dương, nhưng CHƯA BÁN ĐƯỢC CÁI NÀO thì §1.8b bắt buộc GIỮ — trong khi rule
       population mới loại nó ngay từ đầu vì nó chưa có dòng POS nào.

   Đây chính là loại SKU mà nghiệp vụ nhập hàng quan tâm nhất (hàng mới về, chưa phát sinh bán).
   Script KHÔNG tự ý nới rule để "chữa" mâu thuẫn này — yêu cầu của chủ sở hữu nguồn là rõ ràng, và
   bất biến số 7 ở mục 14.1 cũng khóa đúng theo yêu cầu đó. Nhưng nó BẮT BUỘC phải đếm và phát hành
   con số bị mất, để quyết định giữ hay nới rule được ra trên số thật chứ không trên cảm giác.

   Con số dưới đây = số ProductCode có Barcode bán lẻ hợp lệ, CÓ phát sinh kho, nhưng KHÔNG có dòng
   POS nào — tức đúng tập bị rule mới loại mà §1.8b sẽ giữ. Xem CD-069.
   ------------------------------------------------------------------------------------------------- */

DECLARE @PosOnlyRuleDroppedProductCount int;

SELECT @PosOnlyRuleDroppedProductCount = COUNT(*)
FROM
(
    SELECT DISTINCT ImEx.ProductCode
    FROM #ImExSource AS ImEx
    WHERE NOT EXISTS
    (
        SELECT 1 FROM #PosProductAudit AS Audit WHERE Audit.ProductCode = ImEx.ProductCode
    )
) AS ImExOnly
INNER JOIN dbo.tbl_LSProduct AS Product
    ON Product.Code = ImExOnly.ProductCode
WHERE Product.Barcode IS NOT NULL
  AND LTRIM(RTRIM(CONVERT(nvarchar(100), Product.Barcode))) <> N''
  AND Product.Barcode NOT LIKE N'H%';

IF ISNULL(@PosOnlyRuleDroppedProductCount, 0) > 0
    BEGIN
        SET @Msg = N'CẢNH BÁO POS_ONLY_POPULATION_DROPPED_STOCKED_SKU: '
            + CONVERT(nvarchar(20), @PosOnlyRuleDroppedProductCount)
            + N' ProductCode có Barcode bán lẻ hợp lệ và CÓ phát sinh kho nhưng chưa từng có dòng POS, '
            + N'nên bị rule population mới loại. Business Requirements §1.8b sẽ GIỮ chúng nếu còn tồn dương '
            + N'hoặc có nhập hàng trong khoảng đánh giá. Xem CD-069 trước khi coi con số này là chấp nhận được.';
        RAISERROR(N'%s', 0, 1, @Msg) WITH NOWAIT;
    END;


/* -------------------------------------------------------------------------------------------------
   3.2. TOÀN VẸN NGUỒN — DÒNG KHÔNG JOIN ĐƯỢC MASTER HOẶC THIẾU NGÀY

   Mục 2 và 2.5 đã dồn các dòng này vào nhóm BusinessDate IS NULL, nên phép kiểm tra ở đây KHÔNG
   quét lại bảng nguồn.

   Chỉ xét trên tập ỨNG VIÊN: một dòng orphan thuộc sản phẩm không nằm trong population thì không
   ảnh hưởng kết quả, và dừng cả lần xuất vì nó là quá chặt. Nhưng orphan thuộc ứng viên thì phải
   dừng — nó có thể chính là dòng bán bị mất khỏi kết quả, đúng kiểu lỗi đang truy.
   ------------------------------------------------------------------------------------------------- */

DECLARE @OrphanPosProducts int;
DECLARE @OrphanImExProducts int;

SELECT @OrphanPosProducts = COUNT(*)
FROM #PosDaily AS Pos
INNER JOIN #RetailCandidate AS Candidate
    ON Candidate.ProductCode = Pos.ProductCode
WHERE Pos.BusinessDate IS NULL;

IF ISNULL(@OrphanPosProducts, 0) > 0
BEGIN
    RAISERROR(N'Có dòng POS của tập ứng viên không join được tbl_SALPoSMaster hoặc TransactionDate NULL. Chạy DemandPlanningSourceAudit.sql mục 1 để xem chi tiết.', 16, 1);
    RETURN;
END;

SELECT @OrphanImExProducts = COUNT(*)
FROM #ImExSource AS ImEx
INNER JOIN #RetailCandidate AS Candidate
    ON Candidate.ProductCode = ImEx.ProductCode
WHERE ImEx.BusinessDate IS NULL;

IF ISNULL(@OrphanImExProducts, 0) > 0
BEGIN
    RAISERROR(N'Có chứng từ IMEX của tập ứng viên không join được tbl_OPSImExMaster hoặc thiếu EffDate.', 16, 1);
    RETURN;
END;

/* Sau khi đã kiểm, các nhóm BusinessDate IS NULL không còn giá trị gì và chỉ làm nhiễu mọi phép
   tính phía sau. Xóa hẳn để không phải viết `BusinessDate IS NOT NULL` ở mỗi câu sau đó. */
DELETE FROM #PosDaily WHERE BusinessDate IS NULL;
DELETE FROM #ImExSource WHERE BusinessDate IS NULL;


/* =================================================================================================
   4. KHÓA CỬA SỔ TỐI ĐA 5 NĂM

   Cửa sổ inclusive [DataStartDate, LatestAvailableSourceDate].
   DataStartDate = một ngày sau mốc đúng 5 năm trước LatestAvailableSourceDate, để không vượt quá
   5 năm inclusive.

   HAI MỐC NGÀY CỦA ẢNH CHỤP NGUỒN (CD-032, khóa 13/08/2026) — xem Business Requirements §1.4.1b:
   - @LatestAvailableSourceDate   = ngày lớn nhất THỰC TẾ tồn tại trong nguồn.
   - @LatestConfirmedCompleteDate = ngày cuối cùng chủ sở hữu nguồn XÁC NHẬN dữ liệu đã đầy đủ và
     được phép dùng để ra quyết định. Đây là KHAI BÁO của con người, không suy ra được từ database,
     nên là tham số đầu vào ở mục 0. Để NULL nghĩa là "chưa ai xác nhận" — hệ nhận phải xử lý như
     chưa xác nhận, KHÔNG được tự lấy @LatestAvailableSourceDate thay vào.
   Không có cờ boolean "đã hoàn tất": trạng thái cảnh báo là đại lượng suy ra ở tầng ứng dụng
   (LatestConfirmedCompleteDate < PlanningDate - 1).

   SỬA LỖI 20/08/2026 — @LatestAvailableSourceDate nay tính trên TOÀN BỘ nguồn, không qua
   #TargetProducts. Bản trước INNER JOIN #TargetProducts, mà #TargetProducts lúc đó đã bị chế độ thử
   cắt còn 1.000 Barcode: đổi cỡ mẫu thử là đổi luôn ngày cuối cửa sổ, tức đổi TOÀN BỘ khoảng ngày
   của mọi dòng kết quả. Một công tắc kỹ thuật không được phép dịch chuyển phạm vi nghiệp vụ.
   ================================================================================================= */

DECLARE @LatestAvailableSourceDate date;
DECLARE @DataStartDate date;

SELECT @LatestAvailableSourceDate =
(
    SELECT MAX(SourceDate)
    FROM
    (
        SELECT MAX(BusinessDate) AS SourceDate
        FROM #PosDaily
        WHERE BusinessDate <= @RunDate

        UNION ALL

        SELECT MAX(BusinessDate)
        FROM #ImExSource
        WHERE BusinessDate <= @RunDate
    ) AS LatestSourceDate
);

IF @LatestAvailableSourceDate IS NULL
BEGIN
    RAISERROR(N'Không xác định được ngày nguồn mới nhất.', 16, 1);
    RETURN;
END;

SET @DataStartDate = DATEADD(day, 1, DATEADD(year, -@LookbackYears, @LatestAvailableSourceDate));

/* Hai biên datetime dùng lại ở mọi vị từ ngày phía sau — khai báo một lần để không lặp DATEADD và
   để mọi mục dùng chung đúng một định nghĩa cửa sổ. */
DECLARE @WindowStart datetime = CONVERT(datetime, @DataStartDate);
DECLARE @WindowEndExclusive datetime = DATEADD(day, 1, CONVERT(datetime, @LatestAvailableSourceDate));

/* Qty NULL TRONG cửa sổ xuất là lỗi nguồn phải dừng: nó sẽ âm thầm thành 0 ở SalesQty. Trước cửa sổ
   thì KHÔNG dừng — nó chỉ làm seed tồn thành NULL (mục 6), đúng như thiết kế "không biết ≠ bằng 0". */
IF EXISTS
(
    SELECT 1
    FROM #PosDaily AS Pos
    INNER JOIN #RetailCandidate AS Candidate
        ON Candidate.ProductCode = Pos.ProductCode
    WHERE Pos.HasNullQty = 1
      AND Pos.BusinessDate >= @DataStartDate
      AND Pos.BusinessDate <= @LatestAvailableSourceDate
)
BEGIN
    RAISERROR(N'Có dòng POS trong cửa sổ 5 năm có Qty NULL. Không được tự đổi thành 0.', 16, 1);
    RETURN;
END;


/* =================================================================================================
   5. CỔNG NGỪNG HOẠT ĐỘNG 24 THÁNG — ĐẨY XUỐNG SQL, GIỮ NGUYÊN NGỮ NGHĨA

   Business Requirements §1.8b (CD-017, khóa 11/08/2026). Trong 24 tháng liên tục ngay trước
   `SalesDataCutoffDate`, một cặp Barcode — LocationCode chỉ bị loại khi thỏa ĐỒNG THỜI CẢ BỐN:

       1. Không có ngày nào SalesQty > 0
       2. Không có ngày nào OpenStock > 0
       3. Không có ngày nào CloseStock > 0
       4. Không có FirstReceiptDateTime nào

   và chuỗi tồn phải ĐÁNG TIN. Thiếu bất kỳ điều kiện nào thì GIỮ. Đây KHÔNG phải rule rút gọn
   "LastSaleDate < cutoff − 24 tháng", và cũng KHÔNG được rút gọn thành "24 tháng không bán".

   ─── VÌ SAO ĐẨY XUỐNG SQL LÀ AN TOÀN ───────────────────────────────────────────────────────────
   §1.8b nói rõ đây là điều kiện xử lý của CHẶNG 1, và "quy tắc này không xóa lịch sử khỏi nguồn".
   Chặng 1 vẫn chạy nguyên vẹn trên bản xuất này (HistoryCalendarService tính lại đủ bốn bằng chứng
   cho từng ProductCode — Barcode — LocationCode). Vì vậy điều kiện đủ để hành vi pipeline KHÔNG đổi
   là: tập bị SQL loại phải là TẬP CON của tập Chặng 1 sẽ loại. Khi đó Chặng 1 chỉ đơn giản không
   còn gì để loại thêm ở phần SQL đã cắt, và phạm vi phiên lập kế hoạch giống hệt bản cũ.

   Ba chỗ script cố ý BẢO THỦ HƠN Chặng 1 để bảo đảm quan hệ tập con đó:
     - Chuỗi tồn nghi ngờ (seed không biết / có biến động Qty NULL / mức tồn âm) → GIỮ, không loại.
       Chặng 1 chỉ coi là "không đáng tin" khi ngày đó còn có HasSalesRecord=1; script không dùng
       thêm điều kiện đó nên nó giữ nhiều hơn, không bao giờ ít hơn.
     - Cổng chỉ chạy khi @SalesDataCutoffDate được KHAI BÁO. NULL → không loại ai.
     - Cửa sổ đánh giá phải nằm trọn trong cửa sổ xuất; không thì dừng hẳn thay vì đánh giá trên
       khoảng thiếu dữ liệu.

   ─── VÌ SAO KHÔNG CẦN DỰNG CALENDAR ĐỂ BIẾT TỒN ────────────────────────────────────────────────
   Tồn là tổng cộng dồn, nên trong cửa sổ đánh giá, TẬP GIÁ TRỊ của mọi OpenStock và CloseStock đúng
   bằng:  {mức tồn tại đầu cửa sổ}  ∪  {mức tồn cuối MỖI NGÀY CÓ BIẾN ĐỘNG}.
   Ngày không biến động chỉ lặp lại mức của ngày trước, không tạo giá trị mới. Vì vậy chỉ cần cộng
   dồn trên các NGÀY CÓ BIẾN ĐỘNG — một tập rất nhỏ — là biết chính xác có ngày nào tồn dương hay
   không, mà không phải nhân sản phẩm với 730 ngày lịch. Đây chính là chỗ tiết kiệm lớn nhất, và nó
   KHÔNG đánh đổi độ chính xác: kết quả trùng khít với cách dựng đủ calendar rồi mới xét.

   ─── GRAIN ─────────────────────────────────────────────────────────────────────────────────────
   Script đánh giá theo ProductCode, đúng bằng grain Chặng 1 đang dùng
   (GroupBy ProductCode + Barcode + LocationCode, mà một lần chạy = một LocationCode và ProductCode
   xác định Barcode). §1.8b viết grain là Barcode — LocationCode; hai cách chỉ khác nhau khi một
   Barcode dùng chung nhiều ProductCode. Số đó được ĐẾM và phát hành trong metadata
   (BarcodeSharedByMultipleProductCode) thay vì bị chọn ngầm một bên.
   ================================================================================================= */

DECLARE @InactivityWindowStart date = NULL;
DECLARE @InactiveNoPositiveSales int = NULL;
DECLARE @InactiveNoPositiveOpenStock int = NULL;
DECLARE @InactiveNoPositiveCloseStock int = NULL;
DECLARE @InactiveNoReceipt int = NULL;
DECLARE @InactiveUntrustedStockKept int = NULL;
DECLARE @LongTermInactiveProductCount int = NULL;
DECLARE @LongTermInactiveBarcodeCount int = NULL;

CREATE TABLE #InactivityEvidence
(
    ProductCode int NOT NULL PRIMARY KEY,
    HasPositiveSales bit NOT NULL,
    HasReceipt bit NOT NULL,
    StockAtWindowStart decimal(38, 6) NOT NULL,
    MaxOpenStockLevel decimal(38, 6) NOT NULL,
    MaxCloseStockLevel decimal(38, 6) NOT NULL,
    MinStockLevel decimal(38, 6) NOT NULL,
    HasUntrustedStock bit NOT NULL,
    IsLongTermInactive bit NOT NULL
);

IF @SalesDataCutoffDate IS NULL
BEGIN
    BEGIN
        SET @Msg = N'CẢNH BÁO CUTOFF_NOT_DECLARED: @SalesDataCutoffDate = NULL nên KHÔNG áp cổng ngừng hoạt động '
            + CONVERT(nvarchar(10), @InactivityWindowMonths)
            + N' tháng. Bản xuất giữ mọi Barcode bán lẻ từng có giao dịch POS. Đây là hành vi đúng theo CD-032/CD-069: '
            + N'ngày dữ liệu bán chốt là khai báo của Planning Run, script không được tự suy từ GETDATE() hay ngày nguồn lớn nhất.';
        RAISERROR(N'%s', 0, 1, @Msg) WITH NOWAIT;
    END;
END
ELSE
BEGIN
    SET @InactivityWindowStart =
        DATEADD(day, 1, DATEADD(month, -@InactivityWindowMonths, @SalesDataCutoffDate));

    /* Cùng công thức với HistoryCalendarService (Chặng 1): cutoff.AddMonths(-24).AddDays(1). */

    IF @SalesDataCutoffDate > @LatestAvailableSourceDate
    BEGIN
        RAISERROR(N'@SalesDataCutoffDate lớn hơn ngày nguồn mới nhất — cửa sổ đánh giá ngừng hoạt động sẽ rơi vào khoảng không có dữ liệu.', 16, 1);
        RETURN;
    END;

    IF @InactivityWindowStart < @DataStartDate
    BEGIN
        RAISERROR(N'Cửa sổ đánh giá ngừng hoạt động bắt đầu trước cửa sổ xuất 5 năm; không đủ dữ liệu để kết luận, dừng thay vì loại nhầm.', 16, 1);
        RETURN;
    END;

    ;WITH MovementAll AS
    (
        SELECT
            ImEx.ProductCode,
            ImEx.BusinessDate,
            ImEx.InventoryNetQty AS NetQty,
            CONVERT(int, CASE WHEN ImEx.InventoryNetQty IS NULL THEN 1 ELSE 0 END) AS IsUnknown
        FROM #ImExSource AS ImEx
        WHERE ImEx.BusinessDate <= @SalesDataCutoffDate

        UNION ALL

        /* Dấu của POS: dòng bán làm tồn GIẢM, dòng trả làm tồn TĂNG. */
        SELECT
            Pos.ProductCode,
            Pos.BusinessDate,
            Pos.ReturnQtySum - Pos.SaleQtySum,
            CONVERT(int, Pos.HasNullQty)
        FROM #PosDaily AS Pos
        WHERE Pos.BusinessDate <= @SalesDataCutoffDate
    ),
    AnchorLevel AS
    (
        -- Mức tồn cuối ngày ngay TRƯỚC cửa sổ đánh giá; đây cũng là OpenStock của ngày đầu cửa sổ.
        SELECT
            ProductCode,
            SUM(NetQty) AS StockAtWindowStart,
            MAX(IsUnknown) AS UnknownBeforeWindow
        FROM MovementAll
        WHERE BusinessDate < @InactivityWindowStart
        GROUP BY ProductCode
    ),
    WindowDay AS
    (
        SELECT
            ProductCode,
            BusinessDate,
            SUM(NetQty) AS NetQty,
            MAX(IsUnknown) AS IsUnknown
        FROM MovementAll
        WHERE BusinessDate >= @InactivityWindowStart
        GROUP BY ProductCode, BusinessDate
    ),
    WindowRunning AS
    (
        SELECT
            WindowDay.ProductCode,
            WindowDay.BusinessDate,
            COALESCE(AnchorLevel.StockAtWindowStart, 0)
                + SUM(WindowDay.NetQty) OVER
                  (
                      PARTITION BY WindowDay.ProductCode
                      ORDER BY WindowDay.BusinessDate
                      ROWS UNBOUNDED PRECEDING
                  ) AS CloseLevel,
            WindowDay.IsUnknown
        FROM WindowDay
        LEFT JOIN AnchorLevel
            ON AnchorLevel.ProductCode = WindowDay.ProductCode
    ),
    WindowRollup AS
    (
        SELECT
            ProductCode,
            MIN(BusinessDate) AS FirstMovementDate,
            MAX(CloseLevel) AS MaxCloseOnMovementDay,
            MIN(CloseLevel) AS MinCloseOnMovementDay,
            -- Close của ngày d trở thành Open của ngày d+1, nên chỉ ngày < cutoff mới góp vào Open.
            MAX(CASE WHEN BusinessDate < @SalesDataCutoffDate THEN CloseLevel END) AS MaxCloseBeforeLastDay,
            MAX(IsUnknown) AS HasUnknownInWindow
        FROM WindowRunning
        GROUP BY ProductCode
    ),
    Evidence AS
    (
        SELECT
            Candidate.ProductCode,
            CONVERT(bit, CASE WHEN EXISTS
            (
                SELECT 1
                FROM #PosDaily AS Pos
                WHERE Pos.ProductCode = Candidate.ProductCode
                  AND Pos.BusinessDate >= @InactivityWindowStart
                  AND Pos.BusinessDate <= @SalesDataCutoffDate
                  AND Pos.SaleQtySum > 0
            ) THEN 1 ELSE 0 END) AS HasPositiveSales,

            /* Bằng chứng nhập hàng phải khớp ĐÚNG cách mục 13 phát hành FirstReceiptDateTime:
               phiếu nhập nội bộ hoàn tất, và trong cùng ngày đó không có phiếu nào thiếu ReceiptDate
               hoặc có ReceiptDate rơi khác ngày hiệu lực. Lấy rộng hơn thì giữ nhiều hơn (vẫn an
               toàn), nhưng lấy đúng thì số InactiveNoReceipt mới có nghĩa để đối soát. */
            CONVERT(bit, CASE WHEN EXISTS
            (
                SELECT 1
                FROM #ImExSource AS Receipt
                WHERE Receipt.ProductCode = Candidate.ProductCode
                  AND Receipt.IsInternalReceipt = 1
                  AND Receipt.BusinessDate >= @InactivityWindowStart
                  AND Receipt.BusinessDate <= @SalesDataCutoffDate
                GROUP BY Receipt.BusinessDate
                HAVING SUM(CASE WHEN Receipt.RawReceiptDate IS NULL THEN 1 ELSE 0 END) = 0
                   AND SUM(CASE WHEN Receipt.RawReceiptDate IS NOT NULL
                                 AND CONVERT(date, Receipt.RawReceiptDate) <> Receipt.BusinessDate
                                THEN 1 ELSE 0 END) = 0
                   AND MIN(Receipt.ReceiptCandidateDateTime) IS NOT NULL
            ) THEN 1 ELSE 0 END) AS HasReceipt,

            COALESCE(AnchorLevel.StockAtWindowStart, 0) AS StockAtWindowStart,
            COALESCE(AnchorLevel.UnknownBeforeWindow, 0) AS UnknownBeforeWindow,
            WindowRollup.FirstMovementDate,
            WindowRollup.MaxCloseOnMovementDay,
            WindowRollup.MinCloseOnMovementDay,
            WindowRollup.MaxCloseBeforeLastDay,
            COALESCE(WindowRollup.HasUnknownInWindow, 0) AS HasUnknownInWindow
        FROM #RetailCandidate AS Candidate
        LEFT JOIN AnchorLevel
            ON AnchorLevel.ProductCode = Candidate.ProductCode
        LEFT JOIN WindowRollup
            ON WindowRollup.ProductCode = Candidate.ProductCode
    ),
    StockLevel AS
    (
        SELECT
            ProductCode,
            HasPositiveSales,
            HasReceipt,
            StockAtWindowStart,
            /* CloseStock của cửa sổ = mức đầu cửa sổ (nếu còn ngày nào trước biến động đầu tiên)
               hợp với mức cuối các ngày có biến động. */
            CASE
                WHEN MaxCloseOnMovementDay IS NULL THEN StockAtWindowStart
                WHEN FirstMovementDate > @InactivityWindowStart
                    THEN CASE WHEN StockAtWindowStart > MaxCloseOnMovementDay
                              THEN StockAtWindowStart ELSE MaxCloseOnMovementDay END
                ELSE MaxCloseOnMovementDay
            END AS MaxCloseStockLevel,
            /* OpenStock của ngày đầu cửa sổ LUÔN là mức đầu cửa sổ, nên nó luôn tham gia. */
            CASE
                WHEN MaxCloseBeforeLastDay IS NULL THEN StockAtWindowStart
                WHEN StockAtWindowStart > MaxCloseBeforeLastDay THEN StockAtWindowStart
                ELSE MaxCloseBeforeLastDay
            END AS MaxOpenStockLevel,
            CASE
                WHEN MinCloseOnMovementDay IS NULL THEN StockAtWindowStart
                WHEN StockAtWindowStart < MinCloseOnMovementDay THEN StockAtWindowStart
                ELSE MinCloseOnMovementDay
            END AS MinStockLevel,
            CONVERT(bit, CASE WHEN UnknownBeforeWindow = 1 OR HasUnknownInWindow = 1 THEN 1 ELSE 0 END) AS HasUnknownQty
        FROM Evidence
    )
    INSERT INTO #InactivityEvidence
    (
        ProductCode, HasPositiveSales, HasReceipt, StockAtWindowStart,
        MaxOpenStockLevel, MaxCloseStockLevel, MinStockLevel, HasUntrustedStock, IsLongTermInactive
    )
    SELECT
        ProductCode,
        HasPositiveSales,
        HasReceipt,
        StockAtWindowStart,
        MaxOpenStockLevel,
        MaxCloseStockLevel,
        MinStockLevel,
        CONVERT(bit, CASE WHEN HasUnknownQty = 1 OR MinStockLevel < 0 THEN 1 ELSE 0 END),
        CONVERT(bit, CASE
            WHEN HasPositiveSales = 0
             AND HasReceipt = 0
             AND MaxOpenStockLevel <= 0
             AND MaxCloseStockLevel <= 0
             AND HasUnknownQty = 0
             AND MinStockLevel >= 0
            THEN 1 ELSE 0 END)
    FROM StockLevel
    OPTION (RECOMPILE);

    /* §34 — bốn số này là bốn TẬP KHÁC NHAU và CHỒNG LẤN nhau; chúng KHÔNG cộng lại được thành
       LongTermInactiveExcluded. Số bị loại thật sự là GIAO của cả bốn, cộng thêm điều kiện chuỗi
       tồn đáng tin — đó là @LongTermInactiveProductCount ở dòng cuối. */
    SELECT
        @InactiveNoPositiveSales      = SUM(CASE WHEN HasPositiveSales = 0 THEN 1 ELSE 0 END),
        @InactiveNoPositiveOpenStock  = SUM(CASE WHEN MaxOpenStockLevel <= 0 THEN 1 ELSE 0 END),
        @InactiveNoPositiveCloseStock = SUM(CASE WHEN MaxCloseStockLevel <= 0 THEN 1 ELSE 0 END),
        @InactiveNoReceipt            = SUM(CASE WHEN HasReceipt = 0 THEN 1 ELSE 0 END),
        @InactiveUntrustedStockKept   = SUM(CASE WHEN HasUntrustedStock = 1 THEN 1 ELSE 0 END),
        @LongTermInactiveProductCount = SUM(CASE WHEN IsLongTermInactive = 1 THEN 1 ELSE 0 END)
    FROM #InactivityEvidence;

    SELECT @LongTermInactiveBarcodeCount = COUNT(DISTINCT Candidate.Barcode)
    FROM #RetailCandidate AS Candidate
    INNER JOIN #InactivityEvidence AS Evidence
        ON Evidence.ProductCode = Candidate.ProductCode
    WHERE Evidence.IsLongTermInactive = 1;

    BEGIN
        SET @Msg = N'Cổng ngừng hoạt động ' + CONVERT(nvarchar(10), @InactivityWindowMonths) + N' tháng ['
            + CONVERT(nvarchar(10), @InactivityWindowStart, 23) + N' .. '
            + CONVERT(nvarchar(10), @SalesDataCutoffDate, 23) + N']: loại '
            + CONVERT(nvarchar(20), ISNULL(@LongTermInactiveProductCount, 0)) + N' ProductCode / '
            + CONVERT(nvarchar(20), ISNULL(@LongTermInactiveBarcodeCount, 0)) + N' Barcode; giữ lại '
            + CONVERT(nvarchar(20), ISNULL(@InactiveUntrustedStockKept, 0))
            + N' ProductCode vì chuỗi tồn chưa đáng tin.';
        RAISERROR(N'%s', 0, 1, @Msg) WITH NOWAIT;
    END;
END;


/* -------------------------------------------------------------------------------------------------
   5.1. #TargetProducts — POPULATION CUỐI CÙNG

   ÁNH XẠ TÊN CỘT NHÓM — ĐỌC KỸ TRƯỚC KHI SỬA

   Hai hệ đánh số cùng tồn tại, lệch nhau đúng một bậc. #GroupHierarchy5 (mục 1) đánh số theo
   PathLevel: 1 = nhóm GỐC, tăng dần khi đi XUỐNG tới nhóm riêng của sản phẩm. DTO nguồn chuẩn thì
   đánh GroupID, GroupID2..GroupID5. Ánh xạ:

       PathLevel | #GroupHierarchy5 | DTO       | Ý nghĩa
       ----------|------------------|-----------|----------------------------------------
       1         | GroupID          | GroupID   | nhóm GỐC của cây
       2         | GroupID1         | GroupID2  |
       3         | GroupID2         | GroupID3  |
       4         | GroupID3         | GroupID4  |
       5         | GroupID4         | GroupID5  | cấp sâu nhất tìm được

   Cây nông hơn 5 cấp thì các cấp thiếu để NULL. Việc đổi tên CHỈ xảy ra ở lệnh INSERT ngay dưới.
   Cây nhóm không tìm thấy không được phép làm Barcode biến mất khỏi tập nguồn; khi đó các cặp
   GroupID/GroupName để NULL để bộc lộ khoảng trống master data.

   Vẫn không giữ Material/Color/OriginCode/AvgPrice: không nơi nào đọc. AvgPrice không phải bằng
   chứng giá bán thường trong ngày; giữ lại chỉ tạo nguy cơ dùng nhầm làm Price.
   ------------------------------------------------------------------------------------------------- */

CREATE TABLE #TargetProducts
(
    ProductCode int NOT NULL PRIMARY KEY,
    Barcode nvarchar(100) NULL,
    ProductName nvarchar(500) NULL,
    -- Năm cấp nhóm, đã đổi sang tên DTO (xem bảng ánh xạ trên).
    GroupID nvarchar(100) NULL,
    GroupName nvarchar(500) NULL,
    GroupID2 nvarchar(100) NULL,
    GroupName2 nvarchar(500) NULL,
    GroupID3 nvarchar(100) NULL,
    GroupName3 nvarchar(500) NULL,
    GroupID4 nvarchar(100) NULL,
    GroupName4 nvarchar(500) NULL,
    GroupID5 nvarchar(100) NULL,
    GroupName5 nvarchar(500) NULL,
    BrandCode nvarchar(100) NULL,
    BrandName nvarchar(500) NULL,
    Quantitative nvarchar(200) NULL,
    PackingSize nvarchar(200) NULL
);

INSERT INTO #TargetProducts
(
    ProductCode, Barcode, ProductName,
    GroupID,  GroupName,
    GroupID2, GroupName2,
    GroupID3, GroupName3,
    GroupID4, GroupName4,
    GroupID5, GroupName5,
    BrandCode, BrandName, Quantitative, PackingSize
)
SELECT
    Candidate.ProductCode,
    Candidate.Barcode,
    CONVERT(nvarchar(500), Product.VName),
    -- Đổi tên sang hệ DTO: Path.GroupID(cấp1) → GroupID, Path.GroupID1(cấp2) → GroupID2, ...
    Path.GroupID,   Path.GroupName,
    Path.GroupID1,  Path.GroupName1,
    Path.GroupID2,  Path.GroupName2,
    Path.GroupID3,  Path.GroupName3,
    Path.GroupID4,  Path.GroupName4,
    CONVERT(nvarchar(100), Product.Brand),
    Brand.BrandName,
    CONVERT(nvarchar(200), Product.Quantitative),
    CONVERT(nvarchar(200), Product.PackingSize)
FROM #RetailCandidate AS Candidate
INNER JOIN dbo.tbl_LSProduct AS Product
    ON Product.Code = Candidate.ProductCode
-- Phân nhóm chỉ là metadata đi theo Barcode; sản phẩm chưa được gán nhóm vẫn phải được chọn.
LEFT JOIN #ProductGroupMap AS ProductGroup
    ON ProductGroup.ProductCode = Candidate.ProductCode
LEFT JOIN #GroupHierarchy5 AS Path
    ON Path.AssignedGroupCode = ProductGroup.AssignedGroupCode
LEFT JOIN #BrandName AS Brand
    ON Brand.BrandCode = CONVERT(nvarchar(100), Product.Brand)
WHERE NOT EXISTS
(
    SELECT 1
    FROM #InactivityEvidence AS Evidence
    WHERE Evidence.ProductCode = Candidate.ProductCode
      AND Evidence.IsLongTermInactive = 1
);

SELECT @RetailBarcodeBeforeTest = COUNT(DISTINCT Barcode) FROM #TargetProducts;

IF @RetailBarcodeBeforeTest = 0
BEGIN
    RAISERROR(N'Không còn Barcode nào sau cổng ngừng hoạt động. Kiểm tra lại @SalesDataCutoffDate trước khi kết luận nguồn rỗng.', 16, 1);
    RETURN;
END;


/* -------------------------------------------------------------------------------------------------
   5.5. CHẾ ĐỘ THỬ — CHỈ CHẠY KHI @TestModeMaxBarcodes ĐƯỢC ĐẶT SỐ

   Mặc định @TestModeMaxBarcodes = NULL nên toàn bộ khối này KHÔNG chạy và bản xuất là FULL EXPORT.
   Không có TOP/random/CHECKSUM nào nằm ngoài nhánh IF này.

   GroupID/GroupName không tham gia WHERE/JOIN quyết định mẫu. Nếu một Barcode trùng trên nhiều
   ProductCode, giữ toàn bộ ProductCode của Barcode đó; vì vậy số ProductCode có thể lớn hơn N nhưng
   số Barcode phân biệt vẫn đúng N.
   ------------------------------------------------------------------------------------------------- */

IF @TestModeMaxBarcodes IS NOT NULL
BEGIN
    IF OBJECT_ID('tempdb..#SampleKeep') IS NOT NULL DROP TABLE #SampleKeep;
    CREATE TABLE #SampleKeep (Barcode nvarchar(100) NOT NULL PRIMARY KEY);

    INSERT INTO #SampleKeep (Barcode)
    SELECT TOP (@TestModeMaxBarcodes) Candidate.Barcode
    FROM
    (
        SELECT DISTINCT Barcode
        FROM #TargetProducts
    ) AS Candidate
    -- Mẫu ổn định giữa các lần chạy; không dùng GroupID và không dùng tồn kho.
    ORDER BY CHECKSUM(Candidate.Barcode), Candidate.Barcode;

    DELETE Product
    FROM #TargetProducts AS Product
    WHERE NOT EXISTS (SELECT 1 FROM #SampleKeep AS Keep WHERE Keep.Barcode = Product.Barcode);

    DROP TABLE #SampleKeep;

    IF NOT EXISTS (SELECT 1 FROM #TargetProducts)
    BEGIN
        RAISERROR(N'Chế độ thử: không có Barcode hợp lệ để lấy mẫu.', 16, 1);
        RETURN;
    END;

    -- PRINT không nhận subquery — đếm bằng một câu SELECT riêng rồi chỉ in biến vô hướng.
    DECLARE @SampleCount int;
    SELECT @SampleCount = COUNT(DISTINCT Barcode) FROM #TargetProducts;

    BEGIN
        SET @Msg = N'CHẾ ĐỘ THỬ ĐANG BẬT: chỉ giữ ' + CONVERT(nvarchar(20), @SampleCount)
            + N' Barcode. ĐÂY KHÔNG PHẢI FULL EXPORT — đặt @TestModeMaxBarcodes = NULL để chạy đầy đủ.';
        RAISERROR(N'%s', 0, 1, @Msg) WITH NOWAIT;
    END;
END;

SELECT
    @FinalExportProductCount = COUNT(*),
    @ExportBarcodeCount = COUNT(DISTINCT Barcode)
FROM #TargetProducts;

SELECT @BarcodeSharedByMultipleProductCode = COUNT(*)
FROM
(
    SELECT Barcode
    FROM #TargetProducts
    GROUP BY Barcode
    HAVING COUNT(*) > 1
) AS Shared;

IF @BarcodeSharedByMultipleProductCode > 0
    BEGIN
        SET @Msg = N'CẢNH BÁO BARCODE_SHARED_BY_MULTIPLE_PRODUCTCODE: '
            + CONVERT(nvarchar(20), @BarcodeSharedByMultipleProductCode)
            + N' Barcode dùng chung nhiều ProductCode. Khóa canonical vẫn duy nhất vì có ProductCode, '
            + N'nhưng cổng ngừng hoạt động §1.8b (grain Barcode) và Chặng 1 (grain ProductCode) có thể lệch nhau ở đúng các mã này.';
        RAISERROR(N'%s', 0, 1, @Msg) WITH NOWAIT;
    END;

/* Population đã chốt. #PosDaily và #ImExSource nay chỉ còn phục vụ seed/tồn/nhập của population,
   nên thu chúng về đúng tập đó — mọi phép tính sau rẻ hơn hẳn. Bằng chứng cửa hàng-ngày đã được
   tách sang #PosActivityDay ở mục 2 TRƯỚC bước này, nên nó không bị ảnh hưởng. */
DELETE Pos
FROM #PosDaily AS Pos
WHERE NOT EXISTS (SELECT 1 FROM #TargetProducts AS Target WHERE Target.ProductCode = Pos.ProductCode);

DELETE ImEx
FROM #ImExSource AS ImEx
WHERE NOT EXISTS (SELECT 1 FROM #TargetProducts AS Target WHERE Target.ProductCode = ImEx.ProductCode);


/* =================================================================================================
   6. SEED TỒN ĐẦU CỬA SỔ

   Tồn được cộng dồn TIẾN, không dùng mốc neo — đúng cách hệ thống nguồn 3PPOS tính tồn hiện tại
   (Docs/References/StockDateCurrent.sql): SUM toàn bộ chứng từ hoàn tất, không phân biệt
   DocumentType. Seed = SUM mọi phát sinh kho + POS có ngày < @DataStartDate, không giới hạn cận dưới.

   SKU không có phát sinh nào trước cửa sổ → seed = 0 ĐÃ BIẾT, không phải lỗi (SKU mới, hoặc chưa
   từng có ở cửa hàng này). Khác hẳn "có dòng nhưng số lượng NULL" — mới là trường hợp không biết
   được. Vì vậy HasUnknown tính trên GROUP của chính dữ liệu tìm thấy, không qua LEFT JOIN rồi kiểm
   tra NULL (cách đó không phân biệt được hai trường hợp).

   Không quét lại bảng nguồn: seed lấy thẳng từ #PosDaily và #ImExSource đã materialize ở mục 2.
   ================================================================================================= */

CREATE TABLE #StockSeedMovement
(
    ProductCode int NOT NULL PRIMARY KEY,
    SeedNetMovement decimal(38, 6) NULL,
    IsSeedKnown bit NOT NULL
);

;WITH SeedRaw AS
(
    SELECT
        ProductCode,
        InventoryNetQty AS NetQty,
        CASE WHEN InventoryNetQty IS NULL THEN 1 ELSE 0 END AS IsUnknown
    FROM #ImExSource
    WHERE BusinessDate < @DataStartDate

    UNION ALL

    SELECT
        ProductCode,
        ReturnQtySum - SaleQtySum,
        CONVERT(int, HasNullQty)
    FROM #PosDaily
    WHERE BusinessDate < @DataStartDate
),
Seed AS
(
    SELECT
        ProductCode,
        SUM(NetQty) AS NetMovement,
        MAX(IsUnknown) AS HasUnknown
    FROM SeedRaw
    GROUP BY ProductCode
)
INSERT INTO #StockSeedMovement (ProductCode, SeedNetMovement, IsSeedKnown)
SELECT
    Target.ProductCode,
    CASE WHEN COALESCE(Seed.HasUnknown, 0) = 1 THEN NULL ELSE COALESCE(Seed.NetMovement, 0) END,
    CONVERT(bit, CASE WHEN COALESCE(Seed.HasUnknown, 0) = 1 THEN 0 ELSE 1 END)
FROM #TargetProducts AS Target
LEFT JOIN Seed
    ON Seed.ProductCode = Target.ProductCode;


/* =================================================================================================
   7. NẠP POS Ở GRAIN DÒNG — CHỈ CHO CTKM VÀ PRICE

   Đây là lần quét POS thứ hai và là lần cuối. Nó chỉ tồn tại vì hai thứ KHÔNG suy được từ grain
   ngày: mã Discount của từng dòng (mục 9) và cặp Amount/Qty của từng dòng để đối soát đơn giá
   (mục 8). Khác hẳn bản trước, nó chạy SAU khi population đã chốt và cửa sổ đã chốt, nên tập đọc
   nhỏ hơn nhiều.

   Bảng tạm này vẫn là bảng lớn nhất script, nên chỉ giữ đúng 5 cột thật sự được đọc phía sau.
   ================================================================================================= */

CREATE TABLE #PosSource
(
    ProductCode int NOT NULL,
    BusinessDate date NOT NULL,
    Qty decimal(38, 6) NOT NULL,
    Amount decimal(38, 6) NULL,
    DiscountCode int NULL,               -- nguồn của mapping CTKM ở mục 9
    HasRePosDetails bit NOT NULL         -- 1 = dòng trả hàng, dùng ở mục 10 để tính biến động tồn
);

INSERT INTO #PosSource
(
    ProductCode, BusinessDate, Qty, Amount, DiscountCode, HasRePosDetails
)
SELECT
    Detail.Product,
    CONVERT(date, Master.TransactionDate),   -- CONVERT ở phần chiếu: không cản index
    CONVERT(decimal(38, 6), Detail.Qty),
    CONVERT(decimal(38, 6), Detail.Amount),
    Detail.Discount,
    CONVERT(bit, CASE WHEN Detail.RePosDetails IS NULL THEN 0 ELSE 1 END)
FROM dbo.tbl_SALPoSDetails AS Detail
INNER JOIN dbo.tbl_SALPoSMaster AS Master
    ON Master.Code = Detail.PoSMaster
INNER JOIN #TargetProducts AS Product
    ON Product.ProductCode = Detail.Product
WHERE Master.TransactionDate >= @WindowStart          -- SARGable, seek được
  AND Master.TransactionDate <  @WindowEndExclusive
OPTION (RECOMPILE);

CREATE CLUSTERED INDEX IX_PosSource_Product_Date
    ON #PosSource (ProductCode, BusinessDate);

SELECT @RowCount = COUNT_BIG(*) FROM #PosSource;
BEGIN
    SET @Msg = N'TIEN DO ' + CONVERT(nvarchar(8), DATEDIFF(second, @T0, SYSDATETIME()))
        + N's | mục 7 #PosSource xong — ' + CONVERT(nvarchar(30), @RowCount) + N' dòng bán/trả trong cửa sổ';
    RAISERROR(N'%s', 0, 1, @Msg) WITH NOWAIT;
END;

/* ĐỐI CHIẾU HAI LẦN QUÉT POS — bắt buộc, vì hai lần quét khác nhau đọc cùng một sự thật.
   #PosDaily (mục 2, grain ngày, LEFT JOIN master) và #PosSource (mục 7, grain dòng, INNER JOIN
   master) phải cho CÙNG tổng Qty bán và CÙNG tổng Qty trả trên cùng population + cùng cửa sổ.
   Lệch nhau nghĩa là một trong hai phép join/lọc đang đánh rơi dòng — đúng loại lỗi làm một ngày có
   giao dịch thật hiện ra SalesQty = 0. Fail-closed. */
DECLARE @DailyGrainSaleQty decimal(38, 6);
DECLARE @DailyGrainReturnQty decimal(38, 6);
DECLARE @LineGrainSaleQty decimal(38, 6);
DECLARE @LineGrainReturnQty decimal(38, 6);

SELECT
    @DailyGrainSaleQty = SUM(SaleQtySum),
    @DailyGrainReturnQty = SUM(ReturnQtySum)
FROM #PosDaily
WHERE BusinessDate >= @DataStartDate
  AND BusinessDate <= @LatestAvailableSourceDate;

SELECT
    @LineGrainSaleQty = SUM(CASE WHEN HasRePosDetails = 0 THEN Qty ELSE 0 END),
    @LineGrainReturnQty = SUM(CASE WHEN HasRePosDetails = 1 THEN Qty ELSE 0 END)
FROM #PosSource;

IF ABS(ISNULL(@DailyGrainSaleQty, 0) - ISNULL(@LineGrainSaleQty, 0)) > 0.000001
   OR ABS(ISNULL(@DailyGrainReturnQty, 0) - ISNULL(@LineGrainReturnQty, 0)) > 0.000001
BEGIN
    RAISERROR(N'Hai lần quét POS không khớp tổng Qty bán/trả trên cùng population và cùng cửa sổ — có dòng bị đánh rơi ở một trong hai phép join.', 16, 1);
    RETURN;
END;


/* =================================================================================================
   8. SALES VÀ PRICE THEO NGÀY

   Sales = lượng khách THỰC SỰ MUA: chỉ cộng dòng BÁN (HasRePosDetails = 0). Dòng TRẢ HÀNG mang Qty
   DƯƠNG (xem mục 7) nên nếu không lọc thì ngày khách trả 5 cái sẽ đọc thành "bán 5 cái" và nhu cầu
   bị thổi lên đúng 2× lượng trả — đó chính là lỗi CD-029 đã khóa lại ngày 13/08/2026.

   Trả hàng KHÔNG được bù trừ vào đây (không -Qty, không kẹp sàn 0): nó chỉ thuộc biến động tồn ở
   mục 10. Sales ở đây không bị thay bởi PromoSales hay tồn kho.
   ================================================================================================= */

CREATE TABLE #DailySales
(
    ProductCode int NOT NULL,
    BusinessDate date NOT NULL,
    Sales decimal(38, 6) NOT NULL,
    PRIMARY KEY (ProductCode, BusinessDate)
);

INSERT INTO #DailySales (ProductCode, BusinessDate, Sales)
SELECT
    ProductCode,
    BusinessDate,
    SUM(Qty)
FROM #PosSource
WHERE HasRePosDetails = 0          -- CD-029: chỉ dòng bán, loại hẳn dòng trả hàng
GROUP BY ProductCode, BusinessDate;

/* PRICE — đơn giá bán THƯỜNG của sản phẩm trong ngày.

   Candidate chỉ đến từ dòng bán thật, Qty dương, Amount có giá trị và KHÔNG mang marker Discount.
   Cách chọn này cố ý bảo thủ: một Discount không map được không đủ bằng chứng để gọi là CTKM hợp lệ,
   nhưng cũng không đủ bằng chứng để gọi là bán thường. Dòng trả và mọi dòng có Discount đều không
   được cấp bằng chứng Price.

   Một dòng candidate suy unit price bằng Amount / Qty của CHÍNH dòng. Nếu một SKU-day có nhiều
   unit price khác nhau ở precision canonical 6 chữ số thì KHÔNG được chọn weighted average, AVG,
   latest, first, median, min, max hoặc mode. Thay vì dừng TOÀN BỘ full export, script fail-closed ở
   đúng field Price của SKU-day xung đột: Price = NULL. Sales/Promo/Stock và các SKU-day khác vẫn được
   xuất nguyên vẹn. Số SKU-day xung đột được PRINT và phát hành trong metadata để đối soát nguồn.

   Sửa CTKM ở mục 9 KHÔNG được đụng tới khối này: Price không bao giờ lấy AvgPrice, UnitPrice kho,
   StandardCost, Revenue hay NetSales. */
CREATE TABLE #RegularPriceLine
(
    ProductCode int NOT NULL,
    BusinessDate date NOT NULL,
    Qty decimal(38, 6) NOT NULL,
    Amount decimal(38, 6) NOT NULL,
    UnitPrice decimal(38, 6) NOT NULL
);

INSERT INTO #RegularPriceLine (ProductCode, BusinessDate, Qty, Amount, UnitPrice)
SELECT
    Pos.ProductCode,
    Pos.BusinessDate,
    Pos.Qty,
    Pos.Amount,
    CONVERT(decimal(38, 6), Pos.Amount / NULLIF(Pos.Qty, 0))
FROM #PosSource AS Pos
WHERE Pos.HasRePosDetails = 0
  AND Pos.DiscountCode IS NULL
  AND Pos.Qty > 0
  AND Pos.Amount IS NOT NULL;

CREATE NONCLUSTERED INDEX IX_RegularPriceLine_Product_Date
    ON #RegularPriceLine (ProductCode, BusinessDate, UnitPrice);

CREATE TABLE #PriceConflict
(
    ProductCode int NOT NULL,
    BusinessDate date NOT NULL,
    DistinctUnitPriceCount int NOT NULL,
    PRIMARY KEY (ProductCode, BusinessDate)
);

INSERT INTO #PriceConflict (ProductCode, BusinessDate, DistinctUnitPriceCount)
SELECT
    ProductCode,
    BusinessDate,
    COUNT(DISTINCT UnitPrice)
FROM #RegularPriceLine
GROUP BY ProductCode, BusinessDate
HAVING COUNT(DISTINCT UnitPrice) > 1;

DECLARE @PriceConflictSkuDayCount bigint = (SELECT COUNT_BIG(*) FROM #PriceConflict);

IF @PriceConflictSkuDayCount > 0
BEGIN
    BEGIN
        SET @Msg = N'CẢNH BÁO PRICE_SOURCE_AGGREGATION_BLOCKED: ' +
              CONVERT(nvarchar(30), @PriceConflictSkuDayCount) +
              N' SKU-day có nhiều đơn giá bán thường. Full export vẫn tiếp tục; Price của riêng các SKU-day này được để NULL. Không có phép AVG/MIN/MAX/median/mode nào được dùng để chọn giá.';
        RAISERROR(N'%s', 0, 1, @Msg) WITH NOWAIT;
    END;
END;

CREATE TABLE #DailyPrice
(
    ProductCode int NOT NULL,
    BusinessDate date NOT NULL,
    Price decimal(38, 6) NULL,
    PRIMARY KEY (ProductCode, BusinessDate)
);

/* Chỉ những SKU-day có đúng một unit price mới được phát hành Price. MAX ở đây KHÔNG phải phép
   collapse nhiều giá: sau khi loại #PriceConflict, mỗi ProductCode + BusinessDate chỉ còn đúng một
   UnitPrice phân biệt; MAX chỉ đưa giá trị duy nhất đó về grain ngày. */
INSERT INTO #DailyPrice (ProductCode, BusinessDate, Price)
SELECT
    PriceLine.ProductCode,
    PriceLine.BusinessDate,
    MAX(PriceLine.UnitPrice)
FROM #RegularPriceLine AS PriceLine
WHERE NOT EXISTS
(
    SELECT 1
    FROM #PriceConflict AS Conflict
    WHERE Conflict.ProductCode = PriceLine.ProductCode
      AND Conflict.BusinessDate = PriceLine.BusinessDate
)
GROUP BY PriceLine.ProductCode, PriceLine.BusinessDate;

/* AUDIT TÙY CHỌN — xem chi tiết các dòng giá xung đột bằng mục 3 của
   DemandPlanningSourceAudit.sql; không thêm result set phụ vào hợp đồng xuất chính để tránh phá
   importer. */


/* =================================================================================================
   9. CTKM — NGUỒN CỦA IsPromo VÀ PromoSalesQty

   Chỉ trường Discount được đọc. Chuỗi mapping đã có tài liệu xác nhận:
       tbl_SALPoSDetails.Discount → tbl_POLBundle.Code → tbl_POLBundle.Promotion → tbl_POLPromotion.Code

   Các cột DiscountCard / DiscountCouponInv / DiscountGroupProduct KHÔNG tham gia. Chúng chưa có bằng
   chứng runtime nào cho thấy mang mã CTKM, và ghép thêm chúng bằng OR chỉ để một ngày cụ thể trở
   thành CTKM là đúng kiểu sai đã cấm ở Quy tắc số 0 mục 4. Muốn đổi mapping thì phải chạy mục 2 của
   DemandPlanningSourceAudit.sql trên ERP thật, có bằng chứng, rồi mới sửa ở đây.

   BẪY KIỂU DỮ LIỆU — kiểm tra ngay, không giả định:
   #PosSource.DiscountCode khai int. Nếu tbl_SALPoSDetails.Discount thực chất là SỐ TIỀN giảm giá
   (decimal) chứ không phải khóa ngoại, phép ép kiểu ngầm sẽ làm tròn nó thành một số nguyên rồi vô
   tình khớp với một Bundle.Code nào đó. Cổng dưới đây bắt đúng tình huống ấy.
   ================================================================================================= */

IF EXISTS
(
    SELECT 1
    FROM sys.columns AS DiscountColumn
    INNER JOIN sys.types AS ColumnType
        ON ColumnType.user_type_id = DiscountColumn.user_type_id
    WHERE DiscountColumn.object_id = OBJECT_ID(N'dbo.tbl_SALPoSDetails')
      AND DiscountColumn.name = N'Discount'
      AND ColumnType.name NOT IN (N'int', N'bigint', N'smallint', N'tinyint')
)
BEGIN
    RAISERROR(N'tbl_SALPoSDetails.Discount không phải kiểu số nguyên — không được coi nó là khóa ngoại tới tbl_POLBundle.Code khi chưa có bằng chứng ERP. Chạy DemandPlanningSourceAudit.sql mục 2 trước.', 16, 1);
    RETURN;
END;

IF EXISTS
(
    SELECT Bundle.Code
    FROM dbo.tbl_POLBundle AS Bundle
    INNER JOIN
    (
        SELECT DISTINCT DiscountCode
        FROM #PosSource
        WHERE DiscountCode IS NOT NULL
    ) AS UsedDiscount
        ON UsedDiscount.DiscountCode = Bundle.Code
    GROUP BY Bundle.Code
    HAVING COUNT(DISTINCT Bundle.Promotion) > 1
)
BEGIN
    RAISERROR(N'Một mã tbl_POLBundle.Code mapping tới nhiều CTKM; dừng để tránh nhân đôi Qty.', 16, 1);
    RETURN;
END;

/* PromotionNo/PromotionName (số hiệu và tên CTKM) đã bỏ: DTO nguồn chuẩn chỉ cần cờ IsPromo, không
   cần định danh hay tên CTKM. */
CREATE TABLE #DiscountResolution
(
    DiscountCode int NOT NULL PRIMARY KEY,
    BundleFound bit NOT NULL,
    PromotionFound bit NOT NULL,
    PromotionCode int NULL,
    PromotionStartDate date NULL,
    PromotionEndDate date NULL,
    PromotionType int NULL
);

;WITH UsedDiscount AS
(
    SELECT DISTINCT DiscountCode
    FROM #PosSource
    WHERE DiscountCode IS NOT NULL
),
BundleOne AS
(
    SELECT
        Bundle.Code AS DiscountCode,
        MAX(Bundle.Promotion) AS PromotionCode
    FROM dbo.tbl_POLBundle AS Bundle
    INNER JOIN UsedDiscount
        ON UsedDiscount.DiscountCode = Bundle.Code
    GROUP BY Bundle.Code
)
INSERT INTO #DiscountResolution
(
    DiscountCode, BundleFound, PromotionFound,
    PromotionCode, PromotionStartDate, PromotionEndDate, PromotionType
)
SELECT
    UsedDiscount.DiscountCode,
    CONVERT(bit, CASE WHEN BundleOne.DiscountCode IS NULL THEN 0 ELSE 1 END),
    CONVERT(bit, CASE WHEN Promotion.Code IS NULL THEN 0 ELSE 1 END),
    Promotion.Code,
    CONVERT(date, Promotion.StartDate),
    CONVERT(date, Promotion.EndDate),
    Promotion.[Type]
FROM UsedDiscount
LEFT JOIN BundleOne
    ON BundleOne.DiscountCode = UsedDiscount.DiscountCode
LEFT JOIN dbo.tbl_POLPromotion AS Promotion
    ON Promotion.Code = BundleOne.PromotionCode;

/* Bốn nhóm lý do một dòng mang Discount KHÔNG trở thành CTKM. In ra để không bao giờ phải đoán vì
   sao một ngày có giảm giá lại cho IsPromo = 0 — đúng câu hỏi của ca kiểm chứng 15/09/2024. */
DECLARE @DiscountMappingMissing int;
DECLARE @DiscountPromotionMissing int;
DECLARE @DiscountTypeNotEligible int;

SELECT
    @DiscountMappingMissing    = SUM(CASE WHEN BundleFound = 0 THEN 1 ELSE 0 END),
    @DiscountPromotionMissing  = SUM(CASE WHEN BundleFound = 1 AND PromotionFound = 0 THEN 1 ELSE 0 END),
    @DiscountTypeNotEligible   = SUM(CASE WHEN PromotionFound = 1 AND PromotionType NOT IN (2, 7) THEN 1 ELSE 0 END)
FROM #DiscountResolution;

BEGIN
    SET @Msg = N'Mapping CTKM: mất Bundle = ' + CONVERT(nvarchar(20), ISNULL(@DiscountMappingMissing, 0))
        + N'; Bundle có nhưng không có Promotion = ' + CONVERT(nvarchar(20), ISNULL(@DiscountPromotionMissing, 0))
        + N'; Promotion ngoài Type {2,7} = ' + CONVERT(nvarchar(20), ISNULL(@DiscountTypeNotEligible, 0))
        + N'. Các dòng này vẫn nằm nguyên trong SalesQty và được hiểu là bán thường.';
    RAISERROR(N'%s', 0, 1, @Msg) WITH NOWAIT;
END;

/* Một bảng duy nhất cho cả hai thứ DTO cần từ CTKM: cờ IsPromo và lượng bán CTKM.

   Điều kiện "CTKM hợp lệ" — dùng đúng một lần, ở WHERE dưới đây:
       Discount map được tới Promotion  (PromotionFound = 1)
       AND Promotion.Type thuộc {2, 7}
       AND ngày bán nằm trong StartDate..EndDate của chính CTKM đó

   Từ bảng này suy ra hai cột DTO:
       IsPromo       = có dòng ở đây hay không (mục 14)
       PromoSalesQty = PromoSales; không có dòng nghĩa là 0, không phải thiếu dữ liệu

   CD-029 (13/08/2026): bảng này lọc HasRePosDetails = 0 y như #DailySales, nên PromoSales luôn là
   TẬP CON của Sales trên cùng cặp SKU–ngày, tức 0 <= PromoSalesQty <= SalesQty. Dòng Discount bị
   loại (mất mapping / ngoài loại 2,7 / ngoài hạn) chỉ đơn giản không vào bảng này; KHÔNG có phép
   trừ Sales − PromoSales nào ở mục 14, vì hợp đồng nguồn đã gỡ hẳn trường bán-không-CTKM. */
CREATE TABLE #DailyPromo
(
    ProductCode int NOT NULL,
    BusinessDate date NOT NULL,
    PromoSales decimal(38, 6) NOT NULL,
    PRIMARY KEY (ProductCode, BusinessDate)
);

INSERT INTO #DailyPromo (ProductCode, BusinessDate, PromoSales)
SELECT
    Pos.ProductCode,
    Pos.BusinessDate,
    SUM(Pos.Qty)
FROM #PosSource AS Pos
INNER JOIN #DiscountResolution AS Resolution
    ON Resolution.DiscountCode = Pos.DiscountCode
WHERE Pos.HasRePosDetails = 0      -- CD-029: cùng tập dòng bán với #DailySales
  AND Resolution.PromotionFound = 1
  AND Resolution.PromotionType IN (2, 7)
  AND Resolution.PromotionStartDate IS NOT NULL
  AND Resolution.PromotionEndDate IS NOT NULL
  AND Pos.BusinessDate BETWEEN Resolution.PromotionStartDate AND Resolution.PromotionEndDate
GROUP BY Pos.ProductCode, Pos.BusinessDate;


/* =================================================================================================
   10. BIẾN ĐỘNG TỒN THEO NGÀY

   Dữ liệu POS không bị thay đổi. Phần dưới chỉ tạo movement dẫn xuất:
   - RePosDetails IS NULL     => hàng đi ra: -Qty
   - RePosDetails IS NOT NULL => hàng trả về: +Qty
   ================================================================================================= */

CREATE TABLE #DailyMovement
(
    ProductCode int NOT NULL,
    BusinessDate date NOT NULL,
    HasInventoryMovement bit NOT NULL,
    InventoryNetMovement decimal(38, 6) NULL,
    PosOutQty decimal(38, 6) NOT NULL,
    ReturnQty decimal(38, 6) NOT NULL,
    DailyNetMovement decimal(38, 6) NULL,
    HasUnknownMovement bit NOT NULL,
    PRIMARY KEY (ProductCode, BusinessDate)
);

INSERT INTO #DailyMovement
(
    ProductCode, BusinessDate, HasInventoryMovement,
    InventoryNetMovement, PosOutQty, ReturnQty, DailyNetMovement, HasUnknownMovement
)
SELECT
    Source.ProductCode,
    Source.BusinessDate,
    CONVERT(bit, MAX(Source.HasInventoryMovement)),
    CASE WHEN MAX(Source.IsUnknownImExQty) = 1 THEN NULL ELSE SUM(Source.ImExNetQty) END,
    SUM(Source.PosOutQty),
    SUM(Source.ReturnQty),
    CASE
        WHEN MAX(Source.IsUnknownImExQty) = 1 THEN NULL
        ELSE SUM(Source.ImExNetQty - Source.PosOutQty + Source.ReturnQty)
    END,
    CONVERT(bit, MAX(Source.IsUnknownImExQty))
FROM
(
    SELECT
        ProductCode,
        BusinessDate,
        1 AS HasInventoryMovement,
        InventoryNetQty AS ImExNetQty,
        CONVERT(decimal(38, 6), 0) AS PosOutQty,
        CONVERT(decimal(38, 6), 0) AS ReturnQty,
        CASE WHEN InventoryNetQty IS NULL THEN 1 ELSE 0 END AS IsUnknownImExQty
    FROM #ImExSource
    WHERE BusinessDate >= @DataStartDate
      AND BusinessDate <= @LatestAvailableSourceDate

    UNION ALL

    SELECT
        ProductCode,
        BusinessDate,
        0,
        CONVERT(decimal(38, 6), 0),
        CASE WHEN HasRePosDetails = 0 THEN Qty ELSE 0 END,
        CASE WHEN HasRePosDetails = 1 THEN Qty ELSE 0 END,
        0
    FROM #PosSource
) AS Source
GROUP BY Source.ProductCode, Source.BusinessDate;


/* =================================================================================================
   11. BẰNG CHỨNG NGÀY VÀ KHÓA GRAIN KẾT QUẢ

   11.1. HasSalesRecord — cấp CỬA HÀNG-NGÀY

   Đối chiếu tbl_SALPoSMaster + tbl_SALPoSDetails trên TOÀN BỘ sản phẩm, không lọc theo population.
   #PosActivityDay ở mục 2 đã giữ sẵn tập ngày đó TRƯỚC mọi phép lọc sản phẩm, nên kết luận cấp cửa
   hàng không bị thay đổi bởi rule tiền tố, cổng ngừng hoạt động hay chế độ thử.

   CALENDAR LIÊN TỤC. Bảng này chứa MỌI ngày trong cửa sổ nguồn, không chỉ ngày có POS. Ngày toàn cửa
   hàng không có giao dịch nào KHÔNG biến mất khỏi calendar, vì downstream phải phân biệt được
   "cửa hàng nghỉ" với "thiếu dòng nguồn" — hai thứ xử lý khác hẳn.

   HasSalesRecord=1 khi có ít nhất một chi tiết POS trong ngày, kể cả khi tổng Qty bù trừ về 0; nếu
   không có bằng chứng POS thì 0. HasSalesRecord là cờ trạng thái ngày duy nhất (CD-040); timestamp
   và mật độ POS không tham gia.
   ================================================================================================= */

CREATE TABLE #StoreActivity
(
    BusinessDate date NOT NULL PRIMARY KEY,
    HasSalesRecord bit NOT NULL
);

/* Dãy ngày liên tục phủ trọn cửa sổ nguồn. Dựng bằng phép nhân bảng hệ thống thay vì recursive CTE:
   recursive CTE sinh từng ngày một dòng-một-lần, còn cách này là một phép nối tập nhỏ, chạy được
   trên mọi instance mà không cần bảng tiện ích nào. */
;WITH Digit AS
(
    SELECT 0 AS D UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
    UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9
),
DayOffset AS
(
    SELECT (D4.D * 1000 + D3.D * 100 + D2.D * 10 + D1.D) AS Offset
    FROM Digit AS D1 CROSS JOIN Digit AS D2 CROSS JOIN Digit AS D3 CROSS JOIN Digit AS D4
),
CalendarDate AS
(
    SELECT DATEADD(day, Offset, @DataStartDate) AS BusinessDate
    FROM DayOffset
    WHERE Offset <= DATEDIFF(day, @DataStartDate, @LatestAvailableSourceDate)
),
PosEvidenceDay AS
(
    SELECT BusinessDate
    FROM #PosActivityDay
    WHERE BusinessDate >= @DataStartDate
      AND BusinessDate <= @LatestAvailableSourceDate
)
INSERT INTO #StoreActivity (BusinessDate, HasSalesRecord)
SELECT
    CalendarDate.BusinessDate,
    CONVERT(bit, CASE WHEN PosEvidenceDay.BusinessDate IS NULL THEN 0 ELSE 1 END)
FROM CalendarDate
LEFT JOIN PosEvidenceDay
    ON PosEvidenceDay.BusinessDate = CalendarDate.BusinessDate;

IF (SELECT COUNT(*) FROM #StoreActivity)
   <> DATEDIFF(day, @DataStartDate, @LatestAvailableSourceDate) + 1
BEGIN
    RAISERROR(N'#StoreActivity không phủ đủ mọi ngày trong cửa sổ xuất.', 16, 1);
    RETURN;
END;


/* -------------------------------------------------------------------------------------------------
   11.2. GRAIN KẾT QUẢ — CROSS JOIN CHỈ SAU KHI POPULATION ĐÃ CHỐT

   Đây là chỗ số dòng bùng nổ, nên nó phải là bước CUỐI của chuỗi lọc, không phải bước đầu:
       POS population → rule tiền tố → cổng ngừng hoạt động 24 tháng → RỒI MỚI × calendar.

   Hai nhánh UNION cũ (#DailySales và #ImExSource) đã bỏ: cả hai đều đã bị giới hạn trong
   #TargetProducts và trong cửa sổ, mà #StoreActivity phủ MỌI ngày của cửa sổ, nên chúng là tập con
   thật sự của phép CROSS JOIN dưới đây. Giữ lại chỉ tốn thêm hai phép sort/union trên vài chục triệu
   dòng mà không thêm được một khóa nào. Bất biến số 2 ở mục 14 vẫn kiểm lại rằng không dòng
   #DailySales nào bị rơi khỏi kết quả.

   SQL cố ý trả calendar RỘNG HƠN khung ba năm của Chặng 1 để phản ánh đúng hoạt động cửa hàng; việc
   cắt về [SalesEvidenceStartDate, SalesDataCutoffDate] là trách nhiệm của Chặng 1 — xem Business
   Requirements §1.4.

   HasSalesRecord=1 → hai lượng bán luôn có số, kể cả 0.
   HasSalesRecord=0 → hai lượng bán luôn NULL.
   ------------------------------------------------------------------------------------------------- */

/* ƯỚC LƯỢNG TRƯỚC KHI NHÂN — đây là chỗ số dòng bùng nổ, và cho tới 20/08/2026 nó nổ trong im
   lặng. Người chạy phải biết mình sắp tạo ra bao nhiêu dòng TRƯỚC khi ngồi chờ, chứ không phải sau
   khi đã chờ một tiếng. */
DECLARE @TargetProductCount bigint = (SELECT COUNT_BIG(*) FROM #TargetProducts);
DECLARE @CalendarDayCount bigint = (SELECT COUNT_BIG(*) FROM #StoreActivity);
DECLARE @ProjectedRows bigint = @TargetProductCount * @CalendarDayCount;

BEGIN
    SET @Msg = N'TIEN DO ' + CONVERT(nvarchar(8), DATEDIFF(second, @T0, SYSDATETIME()))
        + N's | mục 11.2 SẮP nhân population × calendar: '
        + CONVERT(nvarchar(30), @TargetProductCount) + N' sản phẩm × '
        + CONVERT(nvarchar(30), @CalendarDayCount) + N' ngày = '
        + CONVERT(nvarchar(30), @ProjectedRows) + N' dòng kết quả.';
    RAISERROR(N'%s', 0, 1, @Msg) WITH NOWAIT;
END;

IF @SalesDataCutoffDate IS NULL
BEGIN
    SET @Msg = N'    ^ Cổng ngừng hoạt động ' + CONVERT(nvarchar(10), @InactivityWindowMonths)
        + N' tháng ĐANG TẮT (@SalesDataCutoffDate = NULL) nên population CHƯA được giảm chút nào.'
        + N' Nếu con số trên quá lớn: hủy, khai báo @SalesDataCutoffDate, rồi chạy lại.';
    RAISERROR(N'%s', 0, 1, @Msg) WITH NOWAIT;
END;

/* KHÔNG materialize phép nhân này thành một bảng tạm riêng (trước 20/08/2026 là #DailySourceKey).
   Nó chỉ là #TargetProducts CROSS JOIN #StoreActivity, mà #StockDaily ngay dưới đã có ĐÚNG grain đó
   rồi. Giữ một bảng trung gian cỡ bằng toàn bộ kết quả nghĩa là ghi thêm vài chục triệu dòng xuống
   tempdb rồi đọc lại chúng hai lần, đổi lấy đúng một cái tên đọc cho xuôi. Từ đây:
       #StockDaily  dựng thẳng từ CROSS JOIN;
       #FinalResult dựng từ #StockDaily (cùng grain) nên cũng bớt luôn một LEFT JOIN cỡ kết quả. */

/* =================================================================================================
   12. OPENSTOCK / CLOSESTOCK TRÊN NGÀY SOURCE

   Tự tính lại tồn từ raw movement, KHÔNG đọc tbl_LSProduct.Quantity. Cộng dồn TIẾN từ seed (mục 6)
   bằng windowed SUM:
     CloseStock_d = Seed + SUM(DailyNetMovement) OVER (PARTITION BY ProductCode ORDER BY BusinessDate
                    ROWS UNBOUNDED PRECEDING)          -- cộng dồn BAO GỒM ngày d
     OpenStock_d  = CloseStock_d − DailyNetMovement_d  -- = cộng dồn TRƯỚC ngày d

   Nguồn của phép cộng dồn là #TargetProducts CROSS JOIN #StoreActivity, sinh theo đúng thứ tự
   (ProductCode, BusinessDate) của hai bảng tạm đã đánh index, nên cửa sổ chạy được mà không phải
   sort lại vài chục triệu dòng.

   "Thiếu số lượng" là cờ MỘT CHIỀU: đã dính thì không reset, kể cả khi ngày sau có số rõ. Quy về
   windowed MAX theo đúng thứ tự ngày; dính cờ → OpenStock/CloseStock = NULL.

   SQL không tự sửa tồn âm hay thiếu nguồn. Kiểm tra liên tục (OpenStock_d = CloseStock_{d−1}) đúng
   theo toán học với công thức trên, nhưng vẫn RAISERROR để bắt lỗi sớm thay vì âm thầm trả sai.
   ================================================================================================= */

CREATE TABLE #StockDaily
(
    ProductCode int NOT NULL,
    BusinessDate date NOT NULL,
    OpenStock decimal(38, 6) NULL,
    CloseStock decimal(38, 6) NULL,
    DailyNetMovement decimal(38, 6) NULL,
    StockCalculationStatus nvarchar(150) NOT NULL,
    PRIMARY KEY (ProductCode, BusinessDate)
);

;WITH StockInput AS
(
    SELECT
        Target.ProductCode,
        Activity.BusinessDate,
        COALESCE(Seed.SeedNetMovement, 0) AS SeedNetMovement,
        Seed.IsSeedKnown,
        COALESCE(Movement.DailyNetMovement, 0) AS DailyNetMovement,
        CONVERT(int, COALESCE(Movement.HasUnknownMovement, 0)) AS HasUnknownMovement
    FROM #TargetProducts AS Target
    CROSS JOIN #StoreActivity AS Activity
    INNER JOIN #StockSeedMovement AS Seed
        ON Seed.ProductCode = Target.ProductCode
    LEFT JOIN #DailyMovement AS Movement
        ON Movement.ProductCode = Target.ProductCode
       AND Movement.BusinessDate = Activity.BusinessDate
),
StockRunning AS
(
    SELECT
        ProductCode,
        BusinessDate,
        DailyNetMovement,
        SeedNetMovement +
            SUM(DailyNetMovement) OVER
            (
                PARTITION BY ProductCode
                ORDER BY BusinessDate
                ROWS UNBOUNDED PRECEDING
            ) AS CloseStockIfClean,
        MAX(CASE WHEN IsSeedKnown = 0 THEN 1 ELSE HasUnknownMovement END) OVER
        (
            PARTITION BY ProductCode
            ORDER BY BusinessDate
            ROWS UNBOUNDED PRECEDING
        ) AS TaintSoFar
    FROM StockInput
)
INSERT INTO #StockDaily (ProductCode, BusinessDate, OpenStock, CloseStock, DailyNetMovement, StockCalculationStatus)
SELECT
    ProductCode,
    BusinessDate,
    CASE WHEN TaintSoFar = 1 THEN NULL ELSE CloseStockIfClean - DailyNetMovement END,
    CASE WHEN TaintSoFar = 1 THEN NULL ELSE CloseStockIfClean END,
    DailyNetMovement,
    CASE
        WHEN TaintSoFar = 1 THEN N'Thiếu số lượng ở một hoặc nhiều biến động kho'
        WHEN CloseStockIfClean - DailyNetMovement < 0 OR CloseStockIfClean < 0
            THEN N'Tồn âm hoặc sai phạm vi kho; không tự sửa'
        -- Cột nội bộ: chỉ quyết định OpenStock/CloseStock là số hay NULL, không ra kết quả.
        ELSE N'Đã cộng dồn tiến hợp lệ từ toàn bộ lịch sử phát sinh của SKU'
    END
FROM StockRunning
OPTION (RECOMPILE);

BEGIN
    SET @Msg = N'TIEN DO ' + CONVERT(nvarchar(8), DATEDIFF(second, @T0, SYSDATETIME()))
        + N's | mục 12 #StockDaily xong (cộng dồn tồn)';
    RAISERROR(N'%s', 0, 1, @Msg) WITH NOWAIT;
END;

/* Lưới an toàn: OpenStock ngày hiện tại phải bằng CloseStock ngày nguồn gần nhất phía trước, cùng
   SKU — đúng theo công thức trên nhưng vẫn kiểm lại, không tự tin suông. */
IF EXISTS
(
    SELECT 1
    FROM
    (
        SELECT
            ProductCode,
            OpenStock,
            LAG(CloseStock) OVER (PARTITION BY ProductCode ORDER BY BusinessDate) AS PreviousCloseStock
        FROM #StockDaily
    ) AS Continuity
    WHERE OpenStock IS NOT NULL
      AND PreviousCloseStock IS NOT NULL
      AND ABS(OpenStock - PreviousCloseStock) > 0.000001
)
BEGIN
    RAISERROR(N'Chuỗi tồn không liên tục giữa hai ngày nguồn liên tiếp.', 16, 1);
    RETURN;
END;


/* =================================================================================================
   13. PHIẾU NHẬP NỘI BỘ HOÀN TẤT ĐẦU TIÊN TRONG NGÀY

   Không tạo StockoutStatus. Chỉ trả giờ nhập lấy từ ReceiptDate của phiếu nhập nội bộ hoàn tất.
   Đây cũng chính là logic mà mục 5 dùng lại để tính bằng chứng nhập hàng của cổng 24 tháng — hai nơi
   phải cho cùng kết luận trên cùng một ngày.
   ================================================================================================= */

CREATE TABLE #FirstReceipt
(
    ProductCode int NOT NULL,
    BusinessDate date NOT NULL,
    HasInternalReceipt bit NOT NULL,
    FirstReceiptDate date NULL,
    FirstReceiptDateTime datetime2(0) NULL,
    ReceiptHour int NULL,
    ReceiptTimeStatus nvarchar(150) NOT NULL,
    PRIMARY KEY (ProductCode, BusinessDate)
);

;WITH ReceiptByDocument AS
(
    SELECT
        ProductCode,
        BusinessDate,
        DocumentCode,
        MIN(CONVERT(date, RawReceiptDate)) AS ReceiptDateOnly,
        MIN(ReceiptCandidateDateTime) AS ReceiptDateTime,
        MAX(CASE WHEN RawReceiptDate IS NULL THEN 1 ELSE 0 END) AS HasNullReceiptDate,
        MAX(CASE WHEN RawReceiptDate IS NOT NULL AND CONVERT(time(0), RawReceiptDate) = '00:00:00' THEN 1 ELSE 0 END) AS HasDateOnlyReceipt,
        MAX(CASE WHEN RawReceiptDate IS NOT NULL AND CONVERT(date, RawReceiptDate) <> BusinessDate THEN 1 ELSE 0 END) AS HasDateMismatch
    FROM #ImExSource
    WHERE IsInternalReceipt = 1
      AND BusinessDate >= @DataStartDate
      AND BusinessDate <= @LatestAvailableSourceDate
    GROUP BY ProductCode, BusinessDate, DocumentCode
)
INSERT INTO #FirstReceipt
(
    ProductCode, BusinessDate, HasInternalReceipt,
    FirstReceiptDate, FirstReceiptDateTime, ReceiptHour, ReceiptTimeStatus
)
SELECT
    ProductCode,
    BusinessDate,
    CONVERT(bit, 1),
    MIN(ReceiptDateOnly),
    /* Phiếu nhập chỉ ghi ngày = nhập lúc 00:00:00 — đó là MỘT MỐC THẬT, không phải thiếu dữ liệu
       (quyết định nghiệp vụ 11/08/2026, CD-015). Trước đây nhánh HasDateOnlyReceipt bị ép NULL và
       gắn nhãn "không có giờ nhập thực tế", làm mất luôn bằng chứng đã có hàng từ đầu ngày.
       Chỉ còn hai trường hợp thật sự không dùng được: KHÔNG có ReceiptDate, hoặc ReceiptDate rơi vào
       ngày khác ngày hiệu lực. */
    CASE
        WHEN SUM(HasNullReceiptDate + HasDateMismatch) > 0 THEN NULL
        ELSE MIN(ReceiptDateTime)
    END,
    CASE
        WHEN SUM(HasNullReceiptDate + HasDateMismatch) > 0 THEN NULL
        ELSE DATEPART(hour, MIN(ReceiptDateTime))
    END,
    CASE
        WHEN SUM(HasDateMismatch) > 0
            THEN N'ReceiptDate khác ngày hiệu lực EffDate'
        WHEN SUM(HasNullReceiptDate) > 0
            THEN N'Thiếu ReceiptDate'
        WHEN SUM(HasDateOnlyReceipt) > 0
            THEN N'Phiếu chỉ ghi ngày — nhận lúc 00:00:00'
        ELSE N'Có giờ nhập từ ReceiptDate'
    END
FROM ReceiptByDocument
GROUP BY ProductCode, BusinessDate;


/* =================================================================================================
   14. DỰNG DTO NGUỒN CHUẨN — ĐÚNG 31 CỘT

   Thứ tự cột dưới đây bám đúng thứ tự bảng "DTO nguồn chuẩn". Các bảng tạm phía trên
   (#DailySales, #DailyPromo, #DailyMovement, #StockDaily...) chỉ là nguyên liệu nội bộ;
   không cột audit nào của chúng lọt ra kết quả.

   HasSalesRecord ở grain CỬA HÀNG-NGÀY và được lặp nhất quán xuống mọi Barcode.
   #DailySales chỉ cung cấp lượng bán riêng SKU.

   SalesQty lấy THẲNG từ #DailySales.Sales (CD-029). Không có phép trừ Sales − PromoSales, vì
   PromoSalesQty là tập con của SalesQty chứ không phải một lượng song song.

   KHÔNG kết luận stockout ở đây — UC-DP-02 làm việc đó từ OpenStock/CloseStock/FirstReceiptDateTime.
   ================================================================================================= */

CREATE TABLE #FinalResult
(
    ProductCode int NOT NULL,
    Productname nvarchar(500) NULL,
    Barcode nvarchar(100) NULL,
    LocationCode nvarchar(500) NOT NULL,
    LocationName nvarchar(500) NOT NULL,
    [Date] date NOT NULL,
    HasSalesRecord bit NOT NULL,
    SalesQty decimal(38, 6) NULL,
    PromoSalesQty decimal(38, 6) NULL,
    IsPromo bit NOT NULL,
    OpenStock decimal(38, 6) NULL,
    CloseStock decimal(38, 6) NULL,
    FirstReceiptDateTime datetime2(0) NULL,
    Price decimal(38, 6) NULL,
    -- Năm cấp nhóm + tên, đồng vị trí từng cặp. Cấp không tồn tại (cây nông) để NULL.
    GroupID nvarchar(100) NULL,
    GroupName nvarchar(500) NULL,
    GroupID2 nvarchar(100) NULL,
    GroupName2 nvarchar(500) NULL,
    GroupID3 nvarchar(100) NULL,
    GroupName3 nvarchar(500) NULL,
    GroupID4 nvarchar(100) NULL,
    GroupName4 nvarchar(500) NULL,
    GroupID5 nvarchar(100) NULL,
    GroupName5 nvarchar(500) NULL,
    BrandCode nvarchar(100) NULL,
    BrandName nvarchar(500) NULL,
    Quantitative nvarchar(200) NULL,
    PackingSize nvarchar(200) NULL,
    -- Ba cột Holiday luôn NULL ở tầng SQL; C# enrich thành JSON array tại UC-DP-24.
    HolidayEvent nvarchar(max) NULL,
    HolidayGroup nvarchar(max) NULL,
    HolidayRelation nvarchar(max) NULL,

    PRIMARY KEY (ProductCode, [Date])
);

INSERT INTO #FinalResult
SELECT
    Stock.ProductCode,
    Product.ProductName,
    Product.Barcode,
    StoreIdentity.LocationCode,
    StoreIdentity.LocationName,
    Stock.BusinessDate,
    Activity.HasSalesRecord,
    CASE WHEN Activity.HasSalesRecord = 0 THEN NULL
         ELSE COALESCE(Sales.Sales, 0) END,
    CASE WHEN Activity.HasSalesRecord = 0 THEN NULL
         ELSE COALESCE(Promo.PromoSales, 0) END,
    CONVERT(bit, CASE WHEN Activity.HasSalesRecord = 1 AND Promo.ProductCode IS NOT NULL THEN 1 ELSE 0 END),
    Stock.OpenStock,
    Stock.CloseStock,
    Receipt.FirstReceiptDateTime,
    Price.Price,
    Product.GroupID,   Product.GroupName,
    Product.GroupID2,  Product.GroupName2,
    Product.GroupID3,  Product.GroupName3,
    Product.GroupID4,  Product.GroupName4,
    Product.GroupID5,  Product.GroupName5,
    Product.BrandCode,
    Product.BrandName,
    Product.Quantitative,
    Product.PackingSize,
    CONVERT(nvarchar(max), NULL),
    CONVERT(nvarchar(max), NULL),
    CONVERT(nvarchar(max), NULL)
FROM #StockDaily AS Stock
CROSS JOIN #StoreIdentity AS StoreIdentity
INNER JOIN #TargetProducts AS Product
    ON Product.ProductCode = Stock.ProductCode
INNER JOIN #StoreActivity AS Activity
    ON Activity.BusinessDate = Stock.BusinessDate
LEFT JOIN #DailySales AS Sales
    ON Sales.ProductCode = Stock.ProductCode
   AND Sales.BusinessDate = Stock.BusinessDate
LEFT JOIN #DailyPrice AS Price
    ON Price.ProductCode = Stock.ProductCode
   AND Price.BusinessDate = Stock.BusinessDate
LEFT JOIN #DailyPromo AS Promo
    ON Promo.ProductCode = Stock.ProductCode
   AND Promo.BusinessDate = Stock.BusinessDate
LEFT JOIN #FirstReceipt AS Receipt
    ON Receipt.ProductCode = Stock.ProductCode
   AND Receipt.BusinessDate = Stock.BusinessDate
OPTION (RECOMPILE);

BEGIN
    SET @Msg = N'TIEN DO ' + CONVERT(nvarchar(8), DATEDIFF(second, @T0, SYSDATETIME()))
        + N's | mục 14 #FinalResult xong — bắt đầu kiểm bất biến';
    RAISERROR(N'%s', 0, 1, @Msg) WITH NOWAIT;
END;


/* =================================================================================================
   14.1. KIỂM TRA BẤT BIẾN TRÊN TOÀN POPULATION TRƯỚC KHI TRẢ

   Các kiểm tra dưới đây tương ứng bất biến đã khóa trong tài liệu. Sai bất kỳ cái nào là lỗi tính
   toán của chính script, không phải dữ liệu nguồn xấu — nên dừng hẳn thay vì trả kết quả sai.
   Tất cả chạy trên TOÀN BỘ population, không lấy mẫu.
   ================================================================================================= */

-- 1. HasSalesRecord quyết định null/number của hai lượng bán (CD-040).
IF EXISTS
(
    SELECT 1
    FROM #FinalResult
    WHERE (HasSalesRecord = 0 AND (SalesQty IS NOT NULL OR PromoSalesQty IS NOT NULL))
       OR (HasSalesRecord = 1 AND (SalesQty IS NULL OR PromoSalesQty IS NULL))
)
BEGIN
    RAISERROR(N'HasSalesRecord không khớp null/number của hai lượng bán.', 16, 1);
    RETURN;
END;

-- 2. Trên ngày HasSalesRecord=1, SalesQty phải bằng ĐÚNG tổng dòng bán của mục 8 — không cộng,
--    không trừ PromoSalesQty. Đồng thời không dòng #DailySales nào được rơi khỏi kết quả.
IF EXISTS
(
    SELECT 1
    FROM #DailySales AS Source
    LEFT JOIN #FinalResult AS Final
        ON Final.ProductCode = Source.ProductCode
       AND Final.[Date] = Source.BusinessDate
    WHERE Final.ProductCode IS NULL
       OR (Final.HasSalesRecord = 1
           AND ABS(Final.SalesQty - Source.Sales) > 0.000001)
)
BEGIN
    RAISERROR(N'Ngày HasSalesRecord=1 không khớp tổng Sales gốc, hoặc có ngày bán bị rơi khỏi kết quả.', 16, 1);
    RETURN;
END;

-- 2b. Bất biến Gross Customer Purchase (CD-029): PromoSalesQty là TẬP CON của SalesQty.
IF EXISTS
(
    SELECT 1
    FROM #FinalResult
    WHERE HasSalesRecord = 1
      AND (PromoSalesQty < 0 OR SalesQty < 0 OR PromoSalesQty > SalesQty)
)
BEGIN
    RAISERROR(N'Vi phạm bất biến 0 <= PromoSalesQty <= SalesQty.', 16, 1);
    RETURN;
END;

-- 3. IsPromo=1 bắt buộc ngày nơi bán có ghi nhận bán.
IF EXISTS (SELECT 1 FROM #FinalResult WHERE IsPromo = 1 AND HasSalesRecord = 0)
BEGIN
    RAISERROR(N'IsPromo = 1 nhưng HasSalesRecord = 0.', 16, 1);
    RETURN;
END;

-- 4. Mỗi grain đúng một dòng, không thừa không thiếu.
IF (SELECT COUNT_BIG(*) FROM #FinalResult) <> @ProjectedRows
BEGIN
    RAISERROR(N'Output không bằng đúng số ProductCode + Date có source thật.', 16, 1);
    RETURN;
END;

-- 5. Khóa canonical ProductCode — Barcode — LocationCode — Date không được trùng.
IF EXISTS
(
    SELECT 1
    FROM #FinalResult
    GROUP BY ProductCode, Barcode, LocationCode, [Date]
    HAVING COUNT_BIG(*) > 1
)
BEGIN
    RAISERROR(N'Có khóa canonical ProductCode — Barcode — LocationCode — Date bị trùng.', 16, 1);
    RETURN;
END;

-- 6. Rule tiền tố phải sạch trong chính kết quả, không chỉ ở bước lọc.
IF EXISTS (SELECT 1 FROM #FinalResult WHERE Barcode IS NULL OR Barcode LIKE N'H%')
BEGIN
    RAISERROR(N'Kết quả còn Barcode rỗng hoặc Barcode combo ''H%''.', 16, 1);
    RETURN;
END;

-- 7. Mọi ProductCode phát hành phải THỰC SỰ có trong tbl_SALPoSDetails (population mới, CD-069).
IF EXISTS
(
    SELECT 1
    FROM #TargetProducts AS Target
    WHERE NOT EXISTS
    (
        SELECT 1 FROM #PosProductAudit AS Audit WHERE Audit.ProductCode = Target.ProductCode
    )
)
BEGIN
    RAISERROR(N'Có ProductCode phát hành mà không tồn tại trong tbl_SALPoSDetails.', 16, 1);
    RETURN;
END;

-- 8. Tổng Qty bán THÔ (grain dòng, mục 7) phải bằng tổng SalesQty phát hành, trên cùng population và
--    cùng cửa sổ. Đây là phép đối chiếu cuối cùng giữa giao dịch thật và con số xuất ra.
DECLARE @RawSaleQtyTotal decimal(38, 6);
DECLARE @FinalSalesQtyTotal decimal(38, 6);

SELECT @RawSaleQtyTotal = SUM(CASE WHEN HasRePosDetails = 0 THEN Qty ELSE 0 END) FROM #PosSource;
SELECT @FinalSalesQtyTotal = SUM(SalesQty) FROM #FinalResult;

IF ABS(ISNULL(@RawSaleQtyTotal, 0) - ISNULL(@FinalSalesQtyTotal, 0)) > 0.000001
BEGIN
    RAISERROR(N'Tổng SalesQty phát hành không bằng tổng Qty dòng bán thô của cùng population/cửa sổ.', 16, 1);
    RETURN;
END;

-- 9. Tổng PromoSalesQty phát hành phải bằng tổng của #DailyPromo trên ngày cửa hàng hoạt động.
DECLARE @PromoSourceTotal decimal(38, 6);
DECLARE @FinalPromoTotal decimal(38, 6);

SELECT @PromoSourceTotal = SUM(Promo.PromoSales)
FROM #DailyPromo AS Promo
INNER JOIN #StoreActivity AS Activity
    ON Activity.BusinessDate = Promo.BusinessDate
WHERE Activity.HasSalesRecord = 1;

SELECT @FinalPromoTotal = SUM(PromoSalesQty) FROM #FinalResult;

IF ABS(ISNULL(@PromoSourceTotal, 0) - ISNULL(@FinalPromoTotal, 0)) > 0.000001
BEGIN
    RAISERROR(N'Tổng PromoSalesQty phát hành không bằng tổng lượng bán CTKM đã tính ở mục 9.', 16, 1);
    RETURN;
END;


/*
   RESULT SET 1 — DailySourceRecord, đúng 31 cột theo đúng thứ tự của DTO nguồn chuẩn.
   Không cột phụ, không metadata run, không cột audit. Ba cột Holiday trả NULL để giữ đúng hình dạng
   hợp đồng; UC-DP-24 (C#) mới điền JSON array.

   ORDER BY ProductCode, Date — KHÔNG phải Barcode, Date. #FinalResult đã clustered đúng theo cặp
   này, nên bản xuất chảy thẳng ra không cần sort lại vài chục triệu dòng (sort đó là chỗ dễ tràn
   tempdb nhất của cả script). Nhóm dòng theo SKU vẫn y nguyên vì một ProductCode chỉ có một Barcode;
   bộ đọc CSV không phụ thuộc thứ tự dòng, chỉ phụ thuộc thứ tự CỘT.

   RESULT SET 2 (ngay bên dưới) — metadata ảnh chụp nguồn và audit population. Tách hẳn khỏi result
   set 1 để không phá hình dạng 31 cột của hợp đồng.
*/
SELECT
    Final.ProductCode,
    Final.Productname AS ProductName,
    Final.Barcode,
    Final.LocationCode,
    Final.LocationName,
    Final.[Date],
    Final.HasSalesRecord,
    Final.SalesQty,
    Final.PromoSalesQty,
    Final.IsPromo,
    Final.OpenStock,
    Final.CloseStock,
    Final.FirstReceiptDateTime,
    Final.Price,
    Final.GroupID,   Final.GroupName,
    Final.GroupID2,  Final.GroupName2,
    Final.GroupID3,  Final.GroupName3,
    Final.GroupID4,  Final.GroupName4,
    Final.GroupID5,  Final.GroupName5,
    Final.BrandCode,
    Final.BrandName,
    Final.Quantitative,
    Final.PackingSize,
    Final.HolidayEvent,
    Final.HolidayGroup,
    Final.HolidayRelation
FROM #FinalResult AS Final
ORDER BY
    Final.ProductCode,
    Final.[Date];


/* =================================================================================================
   14.2. RESULT SET 2 — METADATA ẢNH CHỤP NGUỒN + AUDIT POPULATION

   Hai mốc ngày theo CD-032, không có cờ boolean nào. Bên nhận suy trạng thái cảnh báo bằng
   LatestConfirmedCompleteDate < PlanningDate - 1; PlanningDate không thuộc phạm vi script này.
   LatestConfirmedCompleteDate NULL = chưa ai xác nhận — KHÔNG được tự thay bằng
   LatestAvailableSourceDate.

   ĐƠN VỊ ĐẾM ĐƯỢC GHI THẲNG VÀO TÊN CỘT. `...ProductCount` đếm ProductCode, `...BarcodeCount` đếm
   Barcode phân biệt. Hai đại lượng này KHÁC NHAU khi một Barcode dùng chung nhiều ProductCode —
   xem BarcodeSharedByMultipleProductCode.

   BỐN SỐ `Inactive*` KHÔNG PHẢI BỐN TẬP RỜI NHAU và KHÔNG CỘNG LẠI ĐƯỢC. Mỗi số là "bao nhiêu ứng
   viên VẮNG bằng chứng loại đó". Số thật sự bị loại là GIAO của cả bốn, cộng điều kiện chuỗi tồn
   đáng tin: LongTermInactiveExcludedProductCount.
   ================================================================================================= */

SELECT
    @LatestAvailableSourceDate    AS LatestAvailableSourceDate,
    @LatestConfirmedCompleteDate  AS LatestConfirmedCompleteDate,
    @SalesDataCutoffDate          AS SalesDataCutoffDate,
    @DataStartDate                AS DataStartDate,
    @LatestAvailableSourceDate    AS DataEndDate,
    @InactivityWindowMonths       AS InactivityWindowMonths,
    @InactivityWindowStart        AS InactivityWindowStartDate,

    @ProductsInSalPosDetails      AS ProductsInSALPoSDetails,
    @ProductsNotInProductMaster   AS ProductsNotInProductMaster,
    @ProductsWithMissingBarcode   AS ProductsWithMissingBarcode,
    @SourceBarcodeBeforePrefix    AS SourceBarcodeBeforePrefixRule,
    @HPrefixExcluded              AS HPrefixExcludedBarcodeCount,
    @HPrefixExcludedProductCount  AS HPrefixExcludedProductCount,
    @RetailCandidateProductCount  AS RetailCandidateProductBeforeInactivity,
    @PosOnlyRuleDroppedProductCount AS PosOnlyRuleDroppedStockedProductCount,

    @InactiveNoPositiveSales      AS InactiveNoPositiveSales,
    @InactiveNoPositiveOpenStock  AS InactiveNoPositiveOpenStock,
    @InactiveNoPositiveCloseStock AS InactiveNoPositiveCloseStock,
    @InactiveNoReceipt            AS InactiveNoReceipt,
    @InactiveUntrustedStockKept   AS InactiveUntrustedStockKept,
    @LongTermInactiveProductCount AS LongTermInactiveExcludedProductCount,
    @LongTermInactiveBarcodeCount AS LongTermInactiveExcludedBarcodeCount,

    @RetailBarcodeBeforeTest      AS RetailBarcodeBeforeTestMode,
    @FinalExportProductCount      AS FinalExportProductCount,
    @ExportBarcodeCount           AS ExportedBarcodeCount,
    @BarcodeSharedByMultipleProductCode AS BarcodeSharedByMultipleProductCode,
    @PriceConflictSkuDayCount     AS PriceConflictSkuDayCount,
    @TestModeMaxBarcodes          AS TestModeMaxBarcodes;


/* =================================================================================================
   15. PHỤ LỤC — ĐỀ XUẤT INDEX NGUỒN VÀ KHẢO SÁT SCHEMA

   Toàn bộ mục này nằm trong comment, KHÔNG chạy khi thực thi file.

   15.1. ĐỀ XUẤT INDEX TRÊN DATABASE NGUỒN — CHƯA ĐƯỢC DUYỆT, KHÔNG TỰ TẠO

   Script không tạo index vĩnh viễn trên bảng ERP production. Ba index dưới đây là ĐỀ XUẤT: chúng chỉ
   nên được tạo sau khi DBA xem actual execution plan của chính lần chạy này và đồng ý. Nếu plan cho
   thấy Clustered Index Scan trên tbl_SALPoSDetails là chi phí lớn nhất thì (a) là cái đáng cân nhắc
   trước.

     (a) tbl_SALPoSDetails (Product) INCLUDE (PoSMaster, Qty, Amount, Discount, RePosDetails)
         — phục vụ mục 7 (nạp theo tập ProductCode đã chốt).
     (b) tbl_SALPoSMaster (TransactionDate) INCLUDE (Code)
         — phục vụ vị từ ngày nửa mở ở mục 7.
     (c) tbl_OPSImExMaster (EffDate) INCLUDE (Code, DocumentType, DocumentStatus, ReceiptDate)
         — phục vụ mục 2.5.

   Mục 2 cố ý KHÔNG có vị từ ngày (seed tồn cần toàn bộ lịch sử), nên nó vốn là một lần quét toàn
   bảng và không index nào tránh được điều đó — chỉ có thể làm nó xảy ra ĐÚNG MỘT LẦN, và đó chính
   là điều bản viết lại này làm.

   Cách đo trước khi kết luận:
       SET STATISTICS IO ON;
       SET STATISTICS TIME ON;
   rồi chạy file này với @TestModeMaxBarcodes = 200 để lấy hình dạng plan, sau đó mới chạy full.

   15.2. KHẢO SÁT SCHEMA CHO UC-DP-23 (NGOÀI PHẠM VI DTO NGUỒN CHUẨN)

   UC-DP-23 (nguồn hàng tương lai) cần hai nhóm bảng mà tài liệu CHƯA xác nhận tên cột thật:

   (a) Đơn mua đang mở — biết bảng tồn tại qua FK `tbl_OPSImExMaster.PO` → `tbl_OPSPOMaster.Code`
       và `tbl_OPSImExDetails.POStore` → `tbl_OPSPOStore.Code`.
   (b) Tồn giữ chỗ/đang xử lý, chỉ cần nếu mở rộng khỏi một cửa hàng pilot — ứng viên
       `tbl_LSProductPeriodStock`, `tbl_WWSSODetails`, `tbl_OPSIOPO*` (`Status IN (41,42,43,44)`,
       ý nghĩa từng Status chưa xác nhận).

   Chạy các khối dưới trong SSMS trên DB [POS], có kết quả thật rồi mới viết SELECT sản xuất.
   KHÔNG tự đoán tên cột — đó chính là cách đã sai với "TransactionType = 2" trước đây.

SELECT COLUMN_NAME, DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'tbl_OPSPOMaster'
ORDER BY ORDINAL_POSITION;

SELECT COLUMN_NAME, DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'tbl_OPSPOStore'
ORDER BY ORDINAL_POSITION;

SELECT TOP 50 * FROM dbo.tbl_OPSPOMaster;
SELECT TOP 50 * FROM dbo.tbl_OPSPOStore;

-- Nhóm (b) — kho KGV / đơn sỉ-online, chỉ cần nếu mở rộng khỏi 1 cửa hàng pilot:
SELECT COLUMN_NAME, DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME IN
(
    'tbl_LSProductPeriodStock', 'tbl_WWSSODetails',
    'tbl_OPSIOPO', 'tbl_OPSIOPODetails', 'tbl_OPSIOPOExpired'
)
ORDER BY TABLE_NAME, ORDINAL_POSITION;

SELECT TOP 50 * FROM dbo.tbl_LSProductPeriodStock;
SELECT DISTINCT [Status] FROM dbo.tbl_OPSIOPO;  -- ý nghĩa từng Status (41-44...) chưa xác nhận
   ================================================================================================= */


/* Dọn temp. */
DROP TABLE #FinalResult;
DROP TABLE #FirstReceipt;
DROP TABLE #StockDaily;
DROP TABLE #StoreActivity;
DROP TABLE #DailyMovement;
DROP TABLE #DailyPromo;
DROP TABLE #DiscountResolution;
DROP TABLE #DailyPrice;
DROP TABLE #PriceConflict;
DROP TABLE #RegularPriceLine;
DROP TABLE #DailySales;
DROP TABLE #PosSource;
DROP TABLE #StockSeedMovement;
DROP TABLE #TargetProducts;
DROP TABLE #InactivityEvidence;
DROP TABLE #RetailCandidate;
DROP TABLE #PosProductAudit;
DROP TABLE #ImExSource;
DROP TABLE #PosActivityDay;
DROP TABLE #PosDaily;
DROP TABLE #StoreIdentity;
DROP TABLE #BrandName;
DROP TABLE #GroupHierarchy5;
DROP TABLE #ProductGroupMap;

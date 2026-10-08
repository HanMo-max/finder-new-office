#import <AppKit/AppKit.h>
#import <FinderSync/FinderSync.h>
#import <Foundation/Foundation.h>

static NSString *uniqueName(NSString *directory, NSString *base, NSString *extension) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *candidate = [NSString stringWithFormat:@"%@.%@", base, extension];
    if (![fm fileExistsAtPath:[directory stringByAppendingPathComponent:candidate]]) {
        return candidate;
    }
    for (NSUInteger i = 2; i < 1000; i++) {
        candidate = [NSString stringWithFormat:@"%@ %lu.%@", base, (unsigned long)i, extension];
        if (![fm fileExistsAtPath:[directory stringByAppendingPathComponent:candidate]]) {
            return candidate;
        }
    }
    return [NSString stringWithFormat:@"%@ %u.%@", base, arc4random(), extension];
}

@interface NewDocSync : FIFinderSync
@end

@implementation NewDocSync

- (instancetype)init {
    self = [super init];
    if (self) {
        // Every folder, so the menu shows in any Finder window. The desktop
        // wallpaper's own right-click menu is drawn by the system and cannot
        // host a third-party item; Finder windows of the Desktop can.
        [FIFinderSyncController defaultController].directoryURLs =
            [NSSet setWithObject:[NSURL fileURLWithPath:@"/"]];
    }
    return self;
}

- (NSMenu *)menuForMenuKind:(FIMenuKind)menuKind {
    if (menuKind != FIMenuKindContextualMenuForContainer &&
        menuKind != FIMenuKindContextualMenuForSidebar) {
        return nil;
    }
    NSURL *target = [FIFinderSyncController defaultController].targetedURL;
    if (target == nil) {
        return nil;
    }

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    NSMenuItem *root = [[NSMenuItem alloc] initWithTitle:@"新建" action:nil keyEquivalent:@""];
    NSMenu *sub = [[NSMenu alloc] initWithTitle:@"新建"];

    NSMenuItem *word = [[NSMenuItem alloc] initWithTitle:@"新建 Word 文档"
                                                  action:@selector(createWord:)
                                           keyEquivalent:@""];
    word.target = self;
    word.representedObject = @"docx";

    NSMenuItem *excel = [[NSMenuItem alloc] initWithTitle:@"新建 Excel 表格"
                                                   action:@selector(createExcel:)
                                            keyEquivalent:@""];
    excel.target = self;
    excel.representedObject = @"xlsx";

    NSMenuItem *ppt = [[NSMenuItem alloc] initWithTitle:@"新建 PPT 文档"
                                                 action:@selector(createPPT:)
                                          keyEquivalent:@""];
    ppt.target = self;
    ppt.representedObject = @"pptx";

    [sub addItem:word];
    [sub addItem:excel];
    [sub addItem:ppt];
    root.submenu = sub;
    [menu addItem:root];
    return menu;
}

- (void)createWord:(id)sender { [self createKind:@"docx" base:@"新建 Word 文档"]; }
- (void)createExcel:(id)sender { [self createKind:@"xlsx" base:@"新建 Excel 表格"]; }
- (void)createPPT:(id)sender { [self createKind:@"pptx" base:@"新建 PPT 演示文稿"]; }

- (void)createKind:(NSString *)kind base:(NSString *)base {
    // The file lands in the folder that was right-clicked. Nothing else opens.
    NSURL *target = [FIFinderSyncController defaultController].targetedURL;
    if (target == nil || !target.isFileURL) {
        [self notifyFailure:[NSError errorWithDomain:@"FinderNewOffice" code:1
                                           userInfo:@{NSLocalizedDescriptionKey: @"无法确定当前文件夹，请重新打开右键菜单。"}]];
        return;
    }
    NSString *directory = target.path;
    NSString *name = uniqueName(directory, base, kind);
    NSString *full = [directory stringByAppendingPathComponent:name];

    NSError *error = nil;
    BOOL ok = NO;
    if ([kind isEqualToString:@"docx"]) {
        ok = [self writeDocx:full error:&error];
    } else if ([kind isEqualToString:@"xlsx"]) {
        ok = [self writeXlsx:full error:&error];
    } else {
        ok = [self writePptx:full error:&error];
    }
    if (!ok) {
        [self notifyFailure:error];
    }
}

- (void)notifyFailure:(NSError *)error {
    NSUserNotification *note = [[NSUserNotification alloc] init];
    note.title = @"新建文件失败";
    note.informativeText = error.localizedDescription ?: @"未知错误";
    [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:note];
}

#pragma mark - minimal stored-method ZIP (no external process, no AppleDouble)

static void put16(uint8_t *p, uint16_t v) { p[0] = v & 0xff; p[1] = v >> 8; }
static void put32(uint8_t *p, uint32_t v) {
    p[0] = v & 0xff; p[1] = (v >> 8) & 0xff; p[2] = (v >> 16) & 0xff; p[3] = v >> 24;
}

static uint32_t crc32Of(NSData *data) {
    static uint32_t table[256];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++) c = (c & 1) ? (0xedb88320u ^ (c >> 1)) : (c >> 1);
            table[i] = c;
        }
    });
    uint32_t crc = 0xffffffffu;
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) crc = table[(crc ^ bytes[i]) & 0xff] ^ (crc >> 8);
    return crc ^ 0xffffffffu;
}

static NSData *xmlData(NSString *xml) {
    return [xml dataUsingEncoding:NSUTF8StringEncoding];
}

- (BOOL)zipEntries:(NSDictionary<NSString *, NSData *> *)entries
              toURL:(NSURL *)url
              error:(NSError **)error {
    // Keep the package manifest first for consistent output.
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if (entries[@"[Content_Types].xml"]) [names addObject:@"[Content_Types].xml"];
    for (NSString *name in [[entries allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        if (![name isEqualToString:@"[Content_Types].xml"]) [names addObject:name];
    }

    NSMutableData *out = [NSMutableData data];
    NSMutableData *central = [NSMutableData data];
    for (NSString *name in names) {
        NSData *payload = entries[name];
        NSData *nameBytes = [name dataUsingEncoding:NSUTF8StringEncoding];
        uint32_t crc = crc32Of(payload);
        uint32_t offset = (uint32_t)out.length;

        uint8_t local[30] = {0x50, 0x4b, 0x03, 0x04};
        put16(local + 8, 0);                 // method: stored
        put32(local + 14, crc);
        put32(local + 18, (uint32_t)payload.length);
        put32(local + 22, (uint32_t)payload.length);
        put16(local + 26, (uint16_t)nameBytes.length);
        [out appendBytes:local length:30];
        [out appendData:nameBytes];
        [out appendData:payload];

        uint8_t cen[46] = {0x50, 0x4b, 0x01, 0x02};
        put16(cen + 4, 20);                  // version made by
        put32(cen + 16, crc);
        put32(cen + 20, (uint32_t)payload.length);
        put32(cen + 24, (uint32_t)payload.length);
        put16(cen + 28, (uint16_t)nameBytes.length);
        put32(cen + 42, offset);
        [central appendBytes:cen length:46];
        [central appendData:nameBytes];
    }

    uint32_t centralOffset = (uint32_t)out.length;
    [out appendData:central];
    uint8_t end[22] = {0x50, 0x4b, 0x05, 0x06};
    put16(end + 8, (uint16_t)names.count);
    put16(end + 10, (uint16_t)names.count);
    put32(end + 12, (uint32_t)central.length);
    put32(end + 16, centralOffset);
    [out appendBytes:end length:22];

    return [out writeToURL:url options:NSDataWritingWithoutOverwriting error:error];
}

- (BOOL)writeDocx:(NSString *)path error:(NSError **)error {
    NSDictionary *entries = @{
        @"[Content_Types].xml": xmlData(
            @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            @"<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            @"<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
            @"<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            @"<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"
            @"</Types>"),
        @"_rels/.rels": xmlData(
            @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            @"<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            @"<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/>"
            @"</Relationships>"),
        @"word/document.xml": xmlData(
            @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            @"<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
            @"<w:body><w:p/></w:body></w:document>"),
    };
    return [self zipEntries:entries toURL:[NSURL fileURLWithPath:path] error:error];
}

- (BOOL)writeXlsx:(NSString *)path error:(NSError **)error {
    NSDictionary *entries = @{
        @"[Content_Types].xml": xmlData(
            @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            @"<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            @"<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
            @"<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            @"<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
            @"<Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
            @"</Types>"),
        @"_rels/.rels": xmlData(
            @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            @"<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            @"<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>"
            @"</Relationships>"),
        @"xl/workbook.xml": xmlData(
            @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            @"<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" "
            @"xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
            @"<sheets><sheet name=\"Sheet1\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>"),
        @"xl/_rels/workbook.xml.rels": xmlData(
            @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            @"<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            @"<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/>"
            @"</Relationships>"),
        @"xl/worksheets/sheet1.xml": xmlData(
            @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            @"<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData/></worksheet>"),
    };
    return [self zipEntries:entries toURL:[NSURL fileURLWithPath:path] error:error];
}

- (BOOL)writePptx:(NSString *)path error:(NSError **)error {
    NSDictionary *entries = @{
        @"[Content_Types].xml": xmlData(
            @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            @"<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            @"<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
            @"<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            @"<Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/>"
            @"<Override PartName=\"/ppt/slides/slide1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
            @"<Override PartName=\"/ppt/slideLayouts/slideLayout1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml\"/>"
            @"<Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml\"/>"
            @"<Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>"
            @"</Types>"),
        @"_rels/.rels": xmlData(
            @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            @"<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            @"<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"ppt/presentation.xml\"/>"
            @"</Relationships>"),
        @"ppt/presentation.xml": xmlData(
            @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            @"<p:presentation xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" "
            @"xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" "
            @"xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\">"
            @"<p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst>"
            @"<p:sldIdLst><p:sldId id=\"256\" r:id=\"rId2\"/></p:sldIdLst>"
            @"<p:sldSz cx=\"12192000\" cy=\"6858000\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/>"
            @"</p:presentation>"),
        @"ppt/_rels/presentation.xml.rels": xmlData(
            @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            @"<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            @"<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster\" Target=\"slideMasters/slideMaster1.xml\"/>"
            @"<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide1.xml\"/>"
            @"</Relationships>"),
        @"ppt/slides/slide1.xml": xmlData(
            @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            @"<p:sld xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" "
            @"xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" "
            @"xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\">"
            @"<p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld>"
            @"<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"),
        @"ppt/slides/_rels/slide1.xml.rels": xmlData(
            @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            @"<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            @"<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/>"
            @"</Relationships>"),
        @"ppt/slideLayouts/slideLayout1.xml": xmlData(
            @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            @"<p:sldLayout xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" "
            @"xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" "
            @"xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\" type=\"blank\">"
            @"<p:cSld name=\"Blank\"><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld>"
            @"<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"),
        @"ppt/slideLayouts/_rels/slideLayout1.xml.rels": xmlData(
            @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            @"<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            @"<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster\" Target=\"../slideMasters/slideMaster1.xml\"/>"
            @"</Relationships>"),
        @"ppt/slideMasters/slideMaster1.xml": xmlData(
            @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            @"<p:sldMaster xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" "
            @"xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" "
            @"xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\">"
            @"<p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld>"
            @"<p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/>"
            @"<p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst>"
            @"<p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>"),
        @"ppt/slideMasters/_rels/slideMaster1.xml.rels": xmlData(
            @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            @"<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            @"<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/>"
            @"<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme\" Target=\"../theme/theme1.xml\"/>"
            @"</Relationships>"),
        @"ppt/theme/theme1.xml": xmlData(
            @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            @"<a:theme xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" name=\"Office\">"
            @"<a:themeElements><a:clrScheme name=\"Office\">"
            @"<a:dk1><a:sysClr val=\"windowText\" lastClr=\"000000\"/></a:dk1>"
            @"<a:lt1><a:sysClr val=\"window\" lastClr=\"FFFFFF\"/></a:lt1>"
            @"<a:dk2><a:srgbClr val=\"44546A\"/></a:dk2><a:lt2><a:srgbClr val=\"E7E6E6\"/></a:lt2>"
            @"<a:accent1><a:srgbClr val=\"4472C4\"/></a:accent1><a:accent2><a:srgbClr val=\"ED7D31\"/></a:accent2>"
            @"<a:accent3><a:srgbClr val=\"A9D08E\"/></a:accent3><a:accent4><a:srgbClr val=\"FFC000\"/></a:accent4>"
            @"<a:accent5><a:srgbClr val=\"5B9BD5\"/></a:accent5><a:accent6><a:srgbClr val=\"70AD47\"/></a:accent6>"
            @"<a:hlink><a:srgbClr val=\"0563C1\"/></a:hlink><a:folHlink><a:srgbClr val=\"954F72\"/></a:folHlink>"
            @"</a:clrScheme>"
            @"<a:fontScheme name=\"Office\"><a:majorFont><a:latin typeface=\"Calibri Light\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:majorFont>"
            @"<a:minorFont><a:latin typeface=\"Calibri\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:minorFont></a:fontScheme>"
            @"<a:fmtScheme name=\"Office\"><a:fillStyleLst><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:fillStyleLst>"
            @"<a:lnStyleLst><a:ln w=\"6350\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln></a:lnStyleLst>"
            @"<a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>"
            @"<a:bgFillStyleLst><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme>"
            @"</a:themeElements></a:theme>"),
    };
    return [self zipEntries:entries toURL:[NSURL fileURLWithPath:path] error:error];
}

@end
